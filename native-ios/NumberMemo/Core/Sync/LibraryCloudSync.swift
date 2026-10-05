import Foundation
import SwiftUI
import CryptoKit

/// Each device writes its own coordinated document. Independent additions merge;
/// timestamped removals persist, so an offline device cannot resurrect deleted items.
@MainActor @Observable
final class LibraryCloudSync {
    static let enabledKey = "icloud.librarySyncEnabled"
    private(set) var status = L10n.text("Waiting for iCloud")
    private(set) var syncing = false
    private(set) var lastSynced: Date?
    var enabled: Bool {
        didSet {
            defaults.set(enabled, forKey: Self.enabledKey)
            if !enabled { query.stop(); queryStarted = false; status = L10n.text("Sync Off") }
        }
    }
    private let defaults: UserDefaults
    private let query = NSMetadataQuery()
    @ObservationIgnored nonisolated(unsafe) private var observers: [NSObjectProtocol] = []
    private var queryStarted = false
    private var cloudRoot: URL?
    private var account: String?
    private var ledger = LibrarySyncLedger()
    private var ledgerURL: URL?
    private var device: String
    private var needsUpload = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        let installation = defaults.string(forKey: "icloud.installation") ?? UUID().uuidString
        defaults.set(installation, forKey: "icloud.installation")
        device = Self.digest(Data((installation + (UIDevice.current.identifierForVendor?.uuidString ?? "")).utf8))
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        query.predicate = NSPredicate(format: "%K LIKE %@", NSMetadataItemFSNameKey, "library-*.json")
        for name in [NSNotification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: query, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.requestDownloads() }
            })
        }
    }
    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }

    func synchronize(env: AppEnvironment) async {
        guard enabled, !syncing else { return }
        #if DEBUG
        guard !ContentUITestSupport.enabled && !ContentUITestSupport.unitTestsEnabled else { status = L10n.text("Sync Off"); return }
        #endif
        syncing = true
        defer { syncing = false }
        do {
            guard let token = FileManager.default.ubiquityIdentityToken else {
                status = L10n.text("Sign in to iCloud and enable iCloud Drive to sync.")
                cloudRoot = nil; account = nil; query.stop(); queryStarted = false
                return
            }
            let tokenData = try NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: false)
            let accountID = Self.digest(tokenData)
            if account != accountID || cloudRoot == nil {
                let root = await Task.detached(priority: .utility) { FileManager.default.url(forUbiquityContainerIdentifier: AppStorage.iCloudContainerId) }.value
                guard let root else { status = L10n.text("iCloud Drive is unavailable. Your data is saved on this device."); return }
                cloudRoot = root.appendingPathComponent("Documents/LibrarySync/v1", isDirectory: true)
                let local = AppStorage.sharedContainerURL.appendingPathComponent("sync-" + accountID + ".json")
                if FileManager.default.fileExists(atPath: local.path) {
                    ledger = try JSONDecoder().decode(LibrarySyncLedger.self, from: Data(contentsOf: local))
                    guard ledger.version == 1 else { throw BooruError.invalidResponse }
                } else { ledger = .init() }
                ledgerURL = local; account = accountID; needsUpload = true
            }
            guard let root = cloudRoot, let local = ledgerURL else { return }
            if !queryStarted { queryStarted = query.start() }
            requestDownloads()
            let incoming = try await Task.detached(priority: .utility) { try CloudLibraryFiles.read(in: root) }.value
            guard enabled, account == accountID, let currentToken = FileManager.default.ubiquityIdentityToken,
                  Self.digest(try NSKeyedArchiver.archivedData(withRootObject: currentToken, requiringSecureCoding: false)) == accountID else { return }
            let adapter = LibrarySyncAdapter(hitomi: env.database, booru: env.booru, hitomiDefaults: defaults, booruDefaults: ReaderPreferences.booruDefaults)
            // Take a fresh snapshot AFTER file I/O so edits made while downloading win.
            let before = ledger.changes
            var next = ledger
            next.capture(try adapter.snapshot(), device: device)
            let captured = next.changes
            for document in incoming { next.merge(document.changes) }
            if next.changes != captured {
                try adapter.apply(next.changes)
                try env.booru.refresh()
                env.reloadSyncedPreferences()
                env.database.syncFoldersToAppGroup()
                env.startCoverQueue()
            }
            next.baseline = try adapter.snapshot()
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(next).write(to: local, options: .atomic)
            AppStorage.excludeFromBackup(local)
            ledger = next
            needsUpload = needsUpload || before != ledger.changes
            if needsUpload {
                let data = try encoder.encode(LibrarySyncDocument(changes: ledger.changes))
                let destination = root.appendingPathComponent("library-" + device + ".json")
                guard enabled else { return }
                try await Task.detached(priority: .utility) { try CloudLibraryFiles.write(data, to: destination) }.value
                needsUpload = false
            }
            guard enabled else { return }
            lastSynced = Date()
            status = L10n.text("iCloud Sync On")
        } catch {
            guard enabled else { return }
            status = L10n.text("Unable to sync now. Your data is saved on this device.")
        }
    }

    private func requestDownloads() {
        guard enabled, let root = cloudRoot else { return }
        query.disableUpdates()
        defer { query.enableUpdates() }
        for item in query.results.compactMap({ $0 as? NSMetadataItem }) {
            guard let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL,
                  url.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL else { continue }
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        }
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

/// Blocking coordination lives off the main thread. Never open SQLite in iCloud.
enum CloudLibraryFiles {
    static func read(in root: URL) throws -> [LibrarySyncDocument] {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let urls = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.ubiquitousItemDownloadingStatusKey, .fileSizeKey])
        var documents: [LibrarySyncDocument] = []
        for url in urls where url.lastPathComponent.hasPrefix("library-") && url.pathExtension == "json" {
            let resource = try url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey, .fileSizeKey])
            if resource.ubiquitousItemDownloadingStatus == .notDownloaded {
                try FileManager.default.startDownloadingUbiquitousItem(at: url)
                continue
            }
            guard (resource.fileSize ?? 0) <= 128 * 1024 * 1024 else { throw BooruError.invalidResponse }
            var coordinationError: NSError?
            var result: Result<LibrarySyncDocument, Error>?
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
                result = Result {
                    let data = try Data(contentsOf: coordinatedURL)
                    guard data.count <= 128 * 1024 * 1024 else { throw BooruError.invalidResponse }
                    let document = try JSONDecoder().decode(LibrarySyncDocument.self, from: data)
                    guard document.version == 1 else { throw BooruError.invalidResponse }
                    return document
                }
            }
            if let coordinationError { throw coordinationError }
            if let result { documents.append(try result.get()) }
            // Read unresolved versions too; row clocks resolve concurrent file versions.
            for version in NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? [] {
                let data = try Data(contentsOf: version.url)
                guard data.count <= 128 * 1024 * 1024 else { throw BooruError.invalidResponse }
                let document = try JSONDecoder().decode(LibrarySyncDocument.self, from: data)
                guard document.version == 1 else { throw BooruError.invalidResponse }
                documents.append(document)
            }
        }
        return documents
    }
    static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var coordinationError: NSError?
        var result: Result<Void, Error>?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { coordinatedURL in
            result = Result { try data.write(to: coordinatedURL, options: .atomic) }
        }
        if let coordinationError { throw coordinationError }
        try result?.get()
    }
}
