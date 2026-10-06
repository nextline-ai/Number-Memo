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
    private(set) var documentBytes: Int?
    private(set) var cloudBytes: Int?
    private(set) var cloudDocumentCount = 0
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
            let incoming = try await Task.detached(priority: .utility) { try CloudLibraryFiles.readState(in: root) }.value
            guard enabled, account == accountID, let currentToken = FileManager.default.ubiquityIdentityToken,
                  Self.digest(try NSKeyedArchiver.archivedData(withRootObject: currentToken, requiringSecureCoding: false)) == accountID else { return }
            let adapter = LibrarySyncAdapter(hitomi: env.database, booru: env.booru, hitomiDefaults: defaults, booruDefaults: ReaderPreferences.booruDefaults)
            // Take a fresh snapshot AFTER file I/O so edits made while downloading win.
            cloudBytes = incoming.storedBytes
            cloudDocumentCount = incoming.documentCount
            let before = ledger.changes
            var next = ledger
            next.capture(try adapter.snapshot(), device: device)
            let captured = next.changes
            for document in incoming.documents { next.merge(document.changes) }
            next.changes = try LibrarySyncAdapter.mediaFreeChanges(next.changes)
            if next.changes != captured {
                try adapter.apply(next.changes)
                try env.booru.refresh()
                env.reloadSyncedPreferences()
                env.database.syncFoldersToAppGroup()
                env.startCoverQueue()
            }
            next.baseline = try adapter.snapshot()
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(next).write(to: local, options: .atomic)
            AppStorage.excludeFromBackup(local)
            ledger = next
            needsUpload = needsUpload || before != ledger.changes
            let data = try encoder.encode(LibrarySyncDocument(changes: ledger.changes))
            documentBytes = data.count
            if needsUpload {
                let destination = root.appendingPathComponent("library-" + device + ".json")
                guard enabled else { return }
                try await Task.detached(priority: .utility) { try CloudLibraryFiles.write(data, to: destination, ubiquitous: true) }.value
                needsUpload = false
            }
            guard enabled, let currentToken = FileManager.default.ubiquityIdentityToken,
                  Self.digest(try NSKeyedArchiver.archivedData(withRootObject: currentToken, requiringSecureCoding: false)) == accountID else { return }
            let destination = root.appendingPathComponent("library-" + device + ".json")
            let uploaded = try await Task.detached(priority: .utility) {
                let values = try destination.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemIsUploadedKey])
                return values.isUbiquitousItem == true && values.ubiquitousItemIsUploaded == true
            }.value
            guard enabled else { return }
            if incoming.unreadableFiles > 0 {
                status = L10n.text("Some iCloud files could not be read. Other changes were merged. Try syncing again.")
            } else if incoming.pendingDownloads || query.isGathering || !uploaded {
                status = L10n.text("Waiting for iCloud to transfer changes. Your data is saved on this device.")
            } else {
                lastSynced = Date()
                status = L10n.text("iCloud Sync On")
            }
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
    struct ReadState: Sendable {
        var documents: [LibrarySyncDocument] = []
        var pendingDownloads = false
        var unreadableFiles = 0
        var storedBytes = 0
        var documentCount = 0
    }
    static func read(in root: URL) throws -> [LibrarySyncDocument] {
        let result = try readState(in: root)
        guard result.unreadableFiles == 0 else { throw CocoaError(.fileReadCorruptFile) }
        return result.documents
    }
    static func readState(in root: URL) throws -> ReadState {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let urls = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.ubiquitousItemDownloadingStatusKey, .fileSizeKey])
        var state = ReadState()
        for url in urls where url.lastPathComponent.hasPrefix("library-") && url.pathExtension == "json" {
            do {
                let resource = try url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey, .fileSizeKey])
                state.storedBytes += resource.fileSize ?? 0
                state.documentCount += 1
                if let downloadStatus = resource.ubiquitousItemDownloadingStatus, downloadStatus != .current {
                    try FileManager.default.startDownloadingUbiquitousItem(at: url)
                    state.pendingDownloads = true
                    if downloadStatus == .notDownloaded { continue }
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
                guard let result else { throw CocoaError(.fileReadUnknown) }
                state.documents.append(try result.get())
                // Read unresolved versions too; row clocks resolve concurrent file versions.
                for version in NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? [] {
                    let size = try version.url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= 128 * 1024 * 1024 else { throw BooruError.invalidResponse }
                    let data = try Data(contentsOf: version.url)
                    guard data.count <= 128 * 1024 * 1024 else { throw BooruError.invalidResponse }
                    let document = try JSONDecoder().decode(LibrarySyncDocument.self, from: data)
                    guard document.version == 1 else { throw BooruError.invalidResponse }
                    state.documents.append(document)
                }
            } catch {
                // One interrupted/unsupported peer file must not block every healthy device.
                // Keep the original file intact and surface partial failure in settings.
                state.unreadableFiles += 1
            }
        }
        return state
    }
    static func write(_ data: Data, to url: URL, ubiquitous: Bool = false) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if ubiquitous && !FileManager.default.fileExists(atPath: url.path) {
            // Register new documents with iCloud explicitly; a successful local write
            // alone does not prove that the document is managed by the cloud daemon.
            let staging = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
            defer { try? FileManager.default.removeItem(at: staging) }
            try data.write(to: staging, options: .atomic)
            try FileManager.default.setUbiquitous(true, itemAt: staging, destinationURL: url)
            return
        }
        var coordinationError: NSError?
        var result: Result<Void, Error>?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { coordinatedURL in
            result = Result { try data.write(to: coordinatedURL, options: .atomic) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CocoaError(.fileWriteUnknown) }
        try result.get()
    }
}
