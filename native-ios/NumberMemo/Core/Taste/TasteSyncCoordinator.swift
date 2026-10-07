import Foundation
import Observation

struct TasteSyncChunk: Codable {
    var version = 1
    var mode: TasteMode
    var epoch: String
    var events: [TasteEvent]
    var reports: [TasteReport] = []
}

/// Independent immutable chunks; existing LibrarySync/v1 documents are never changed.
@MainActor @Observable
final class TasteSyncCoordinator {
    var status = L10n.text("Waiting for iCloud")
    private(set) var syncing = false
    private let query = NSMetadataQuery()
    private var started = false
    private var boundAccount: String?
    private var seen: Set<String> = []

    func synchronize(controller: TasteController, librarySync: LibraryCloudSync) async {
        guard !syncing, librarySync.enabled else { status = L10n.text("Sync Off"); return }
        syncing = true; defer { syncing = false }
        do {
            guard let token = FileManager.default.ubiquityIdentityToken,
                  let container = await librarySync.availableContainer() else { status = L10n.text("Waiting for iCloud"); return }
            let account = tasteDigest(try NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: false))
            let stores = [controller.comics, controller.booru]
            let oldAccount = try controller.comics.metadata(String.self, key: "account")
            if let oldAccount, oldAccount != account {
                // The library remains intact; personal activity never crosses Apple accounts.
                try controller.rebindAccount()
                for store in stores { try store.metadata(account, key: "account") }
                seen.removeAll()
            } else if oldAccount == nil { for store in stores { try store.metadata(account, key: "account") } }
            if boundAccount != account {
                boundAccount = account
                seen = Set(try controller.comics.metadata([String].self, key: "seen-" + account) ?? [])
                if started { query.stop(); started = false }
            }
            if !started {
                query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
                query.predicate = NSPredicate(format: "%K LIKE %@", NSMetadataItemFSNameKey, "taste-*.json")
                started = query.start()
            }
            guard started, !query.isGathering else { status = L10n.text("Downloading analysis history…"); return }
            let root = container.appendingPathComponent("Documents/TasteSync/v1", isDirectory: true)
            var pendingDiscoveredControl = false
            query.disableUpdates()
            for index in 0..<query.resultCount {
                guard let item = query.result(at: index) as? NSMetadataItem,
                      let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL,
                      url.path.hasPrefix(root.path + "/") else { continue }
                let state = (try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?.ubiquitousItemDownloadingStatus
                if let state, state != .current {
                    try? FileManager.default.startDownloadingUbiquitousItem(at: url)
                    if url.lastPathComponent.hasPrefix("taste-control-") { pendingDiscoveredControl = true }
                }
            }
            query.enableUpdates()
            let inventory = try await Task.detached(priority: .utility) { try TasteCloudFiles.inventory(root) }.value
            guard await valid(librarySync, container: container, account: account) else { return }
            // Controls are always read before any data upload, including when collection is paused.
            var winner = controller.control
            var incompleteControl = inventory.pendingControl || pendingDiscoveredControl
            for file in inventory.controls {
                do {
                    let control = try await Task.detached(priority: .utility) { try JSONDecoder().decode(TasteControl.self, from: TasteCloudFiles.read(file)) }.value
                    guard control.validCloudControl else { incompleteControl = true; continue }
                    winner = winner.merged(with: control)
                } catch { incompleteControl = true }
            }
            guard await valid(librarySync, container: container, account: account) else { return }
            winner = controller.control.merged(with: winner)
            if winner != controller.control { controller.apply(winner, remote: true) }
            guard !incompleteControl else { status = L10n.text("Downloading analysis history…"); return }
            let device = try controller.comics.metadata(String.self, key: "device") ?? UUID().uuidString
            let controlData = try JSONEncoder().encode(controller.control)
            let controlURL = root.appendingPathComponent("taste-control-" + device + ".json")
            if try controller.comics.metadata(String.self, key: "control-upload-" + account) != tasteDigest(controlData) {
                try await Task.detached(priority: .utility) { try CloudLibraryFiles.write(controlData, to: controlURL, ubiquitous: true) }.value
                try controller.comics.metadata(tasteDigest(controlData), key: "control-upload-" + account)
            }
            guard await valid(librarySync, container: container, account: account) else { return }
            let epoch = controller.control.epoch
            // A reset revokes every old data chunk, even if an offline device later uploads one.
            for file in inventory.data where file.deletingLastPathComponent().lastPathComponent != epoch {
                guard await valid(librarySync, container: container, account: account) else { return }
                try await Task.detached(priority: .utility) { try TasteCloudFiles.remove(file) }.value
            }
            guard controller.control.cloudEnabled else { status = L10n.text("Analysis sync is off"); return }
            var failures = 0
            var processed = 0
            for file in inventory.data where file.deletingLastPathComponent().lastPathComponent == epoch {
                let key = file.lastPathComponent
                if seen.contains(key) { continue }
                guard processed < 16 else { break }
                do {
                    let chunk = try await Task.detached(priority: .utility) { try JSONDecoder().decode(TasteSyncChunk.self, from: TasteCloudFiles.read(file)) }.value
                    guard chunk.version == 1, chunk.epoch == epoch, chunk.events.count <= 250 else { failures += 1; continue }
                    guard await valid(librarySync, container: container, account: account), controller.control.epoch == epoch else { return }
                    let store = controller.store(chunk.mode)
                    try store.merge(chunk.events)
                    for report in chunk.reports where report.epoch == epoch { try store.saveReport(report, uploaded: true) }
                    seen.insert(key); processed += 1
                } catch { failures += 1 }
            }
            if controller.control.enabled {
                for store in stores {
                    let pending = try store.pending()
                    let firstMonth = pending.first.map { String(ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: $0.at)).prefix(7)) }
                    var events = pending.filter { String(ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: $0.at)).prefix(7)) == firstMonth }
                    let reports = try store.pendingReports()
                    guard !events.isEmpty || !reports.isEmpty else { continue }
                    let generation = controller.control.generation
                    var chunk = TasteSyncChunk(mode: store.mode, epoch: epoch, events: events, reports: reports)
                    var data = try JSONEncoder().encode(chunk)
                    while data.count > 1024 * 1024 && events.count > 1 {
                        events.removeLast(); chunk.events = events; data = try JSONEncoder().encode(chunk)
                    }
                    guard data.count <= 8 * 1024 * 1024 else { throw BooruError.invalidResponse }
                    let month = events.first.map { String(ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: $0.at)).prefix(7)) } ?? "reports"
                    let name = "taste-" + month + "-" + device + "-" + store.mode.rawValue + "-" + tasteDigest(data) + ".json"
                    let url = root.appendingPathComponent(epoch, isDirectory: true).appendingPathComponent(name)
                    guard await valid(librarySync, container: container, account: account), controller.control.enabled, controller.control.cloudEnabled, controller.control.generation == generation else { return }
                    try await Task.detached(priority: .utility) { try CloudLibraryFiles.write(data, to: url, ubiquitous: true) }.value
                    guard controller.control.epoch == epoch, controller.control.generation == generation else { return }
                    try store.acknowledge(events.map(\.id)); try store.acknowledgeReports(reports.map(\.id)); seen.insert(name)
                }
            }
            try controller.comics.metadata(seen.sorted(), key: "seen-" + account)
            let waiting = inventory.pendingData || inventory.data.contains { $0.deletingLastPathComponent().lastPathComponent == epoch && !seen.contains($0.lastPathComponent) }
            status = L10n.text(failures > 0 ? "Some analysis files could not be read." : waiting ? "Downloading analysis history…" : "Analysis synced")
        } catch { status = L10n.text("Unable to sync now. Your data is saved on this device.") }
    }
    private func valid(_ sync: LibraryCloudSync, container: URL, account: String) async -> Bool {
        guard !Task.isCancelled, sync.enabled, await sync.availableContainer() == container,
              let token = FileManager.default.ubiquityIdentityToken,
              let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: false) else { return false }
        return tasteDigest(data) == account
    }
}

enum TasteCloudFiles {
    struct Inventory { var controls: [URL] = []; var data: [URL] = []; var pendingControl = false; var pendingData = false }
    static func inventory(_ root: URL) throws -> Inventory {
        var result = Inventory()
        guard FileManager.default.fileExists(atPath: root.path) else { return result }
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .ubiquitousItemDownloadingStatusKey], options: [.skipsHiddenFiles]) else { return result }
        for case let url as URL in files where url.lastPathComponent.hasPrefix("taste-") && url.pathExtension == "json" {
            let value = try url.resourceValues(forKeys: [.isRegularFileKey, .ubiquitousItemDownloadingStatusKey])
            guard value.isRegularFile == true else { continue }
            let control = url.lastPathComponent.hasPrefix("taste-control-")
            if let state = value.ubiquitousItemDownloadingStatus, state != .current {
                try FileManager.default.startDownloadingUbiquitousItem(at: url)
                if control { result.pendingControl = true } else { result.pendingData = true }
                if state == .notDownloaded { continue }
            }
            if control { result.controls.append(url) } else { result.data.append(url) }
        }
        result.data.sort { $0.lastPathComponent > $1.lastPathComponent }
        return result
    }
    static func read(_ url: URL) throws -> Data {
        var error: NSError?; var result: Result<Data, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { path in
            result = Result {
                guard (try path.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 8 * 1024 * 1024 else { throw BooruError.invalidResponse }
                return try Data(contentsOf: path)
            }
        }
        if let error { throw error }; guard let result else { throw CocoaError(.fileReadUnknown) }; return try result.get()
    }
    static func remove(_ url: URL) throws {
        var error: NSError?; var result: Result<Void, Error>?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &error) { path in result = Result { try FileManager.default.removeItem(at: path) } }
        if let error { throw error }; try result?.get()
    }
}
