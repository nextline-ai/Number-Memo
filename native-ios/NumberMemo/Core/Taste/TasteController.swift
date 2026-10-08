import Foundation
import Observation

@MainActor @Observable
final class TasteController {
    private(set) var control: TasteControl
    private(set) var revision = 0
    var error: String?
    let comics: TasteStore
    let booru: TasteStore
    let cloud = TasteSyncCoordinator()
    let imageFeed = TasteFeedState()
    private var serverFeeds: [String: TasteFeedState] = [:]
    let comicFeed = TasteFeedState()
    var monthlyRecaps: [TasteMode: Date] = [:]
    var dismissedRecaps: [TasteMode: String] = [:]
    func feed(_ mode: TasteMode) -> TasteFeedState { mode == .booru ? imageFeed : comicFeed }
    func feed(_ mode: TasteMode, source: String) -> TasteFeedState {
        guard mode == .booru else { return comicFeed }
        if let feed = serverFeeds[source] { return feed }
        let feed = TasteFeedState(source: source); serverFeeds[source] = feed; return feed
    }
    func feed(_ mode: TasteMode, sources: [String]) -> TasteFeedState {
        guard mode == .booru else { return comicFeed }
        let key = sources.sorted().joined(separator: "\n")
        if let feed = serverFeeds[key] { return feed }
        let feed = TasteFeedState(sources: sources); serverFeeds[key] = feed; return feed
    }
    private let cache = TasteAnalysisCache()
    private let library: AppDatabase
    private let images: BooruStore
    init(library: AppDatabase, images: BooruStore) {
        self.library = library; self.images = images
        comics = library.tasteStore; booru = images.tasteStore
        control = (try? comics.control()) ?? .init()
        do { try booru.setControl(control) } catch { self.error = L10n.text("Unable to update taste analysis.") }
    }
    func store(_ mode: TasteMode) -> TasteStore { mode == .booru ? booru : comics }
    func bootstrap() async {
        guard control.enabled else { return }
        let library = library, images = images
        do {
            try await Task.detached(priority: .utility) {
                if try library.tasteStore.metadata(Bool.self, key: "bootstrapped") != true { try library.tasteStore.bootstrap(library.tasteLibrary()) }
                if try images.tasteStore.metadata(Bool.self, key: "bootstrapped") != true { try images.tasteStore.bootstrap(images.tasteLibrary()) }
            }.value
        } catch { self.error = L10n.text("Unable to update taste analysis.") }
    }
    func change(_ update: (inout TasteControl) -> Void) {
        var next = control; update(&next)
        next.timestamp = max(Date().timeIntervalSince1970, control.timestamp + 0.000001)
        next.author = (try? comics.metadata(String.self, key: "device")) ?? UUID().uuidString
        if next.enabled != control.enabled { next.generation = UUID().uuidString; next.enabledTimestamp = next.timestamp; next.enabledAuthor = next.author }
        if next.epoch != control.epoch { next.resetTimestamp = next.timestamp; next.resetAuthor = next.author }
        apply(next, remote: false)
    }
    func apply(_ next: TasteControl, remote: Bool) {
        do {
            try comics.setControl(next, remote: remote); try booru.setControl(next, remote: remote)
            if next.epoch != control.epoch || !next.enabled {
                imageFeed.clear(); comicFeed.clear(); serverFeeds.values.forEach { $0.clear() }; monthlyRecaps = [:]
            }
            for mode in [TasteMode.booru, .comics] {
                if next.analysisExcluded(mode) != control.analysisExcluded(mode) || next.excluded != control.excluded {
                    feed(mode).applyExclusions(next, mode: mode)
                }
            }
            if next.sourceAnalysisExclusions != control.sourceAnalysisExclusions || next.analysisExclusions != control.analysisExclusions || next.excluded != control.excluded {
                for feed in serverFeeds.values { feed.applyExclusions(next, mode: .booru) }
                comicFeed.applyExclusions(next, mode: .comics)
            }
            control = next; revision += 1
            Task { await cache.invalidate() }
        } catch { self.error = L10n.text("Unable to update taste analysis.") }
    }
    func reset() { change { $0.epoch = UUID().uuidString }; cloud.status = L10n.text("iCloud deletion pending") }
    func rebindAccount() throws {
        let enabled = control.enabled
        var fresh = TasteControl(); fresh.enabled = enabled
        for store in [comics, booru] {
            try store.database.write { db in
                try db.execute(sql: "DELETE FROM taste_events; DELETE FROM taste_reports; DELETE FROM taste_meta WHERE key != 'device';")
                try TasteStore.put(true, key: "bootstrapped", db: db)
                try TasteStore.put(fresh, key: "control", db: db)
            }
        }
        imageFeed.clear(); comicFeed.clear(); serverFeeds.values.forEach { $0.clear() }; monthlyRecaps = [:]; dismissedRecaps = [:]
        control = fresh; revision += 1; awaitCacheInvalidation()
    }
    private func awaitCacheInvalidation() { Task { await cache.invalidate() } }
    func exclude(_ tag: TasteTag) { change { $0.excluded.insert(tag.id) } }
    func snapshot(_ mode: TasteMode, period: TastePeriod, offset: Int, now: Date = Date()) async throws -> TasteSnapshot {
        await bootstrap()
        let interval = period.interval(offset: offset, now: now, timeZone: control.timeZone)
        let previous = offset < 0 ? period.interval(offset: offset - 1, now: now, timeZone: control.timeZone) : nil
        let store = store(mode)
        let keys = try await Task.detached(priority: .utility) { try store.savedKeys() }.value
        return try await cache.snapshot(store: store, control: control, period: interval, previous: previous, savedKeys: keys)
    }
    func synchronize(env: AppEnvironment) async {
        await bootstrap()
        await cloud.synchronize(controller: self, librarySync: env.sync)
    }
    func recapKey(_ date: Date) -> String { control.epoch + ":" + String(Int(date.timeIntervalSince1970)) }
    func pendingRecap(_ mode: TasteMode) -> Date? {
        guard control.enabled, let date = monthlyRecaps[mode], dismissedRecaps[mode] != recapKey(date) else { return nil }
        return date
    }
    func dismissRecap(_ mode: TasteMode) {
        guard let date = monthlyRecaps[mode] else { return }
        let key = recapKey(date)
        do { try store(mode).metadata(key, key: "dismissedRecap"); dismissedRecaps[mode] = key }
        catch { self.error = L10n.text("Unable to update taste analysis.") }
    }
    func prepareCompletedReports() async {
        guard control.enabled else { return }
        for mode in [TasteMode.booru, .comics] {
            for period in [TastePeriod.month, .week] {
                do {
                    try Task.checkCancellation()
                    let captured = control
                    let snapshot = try await snapshot(mode, period: period, offset: -1)
                    guard control.enabled, control.epoch == captured.epoch else { return }
                    if period == .month, snapshot.saves > 0, let start = snapshot.period?.start {
                        monthlyRecaps[mode] = start
                        dismissedRecaps[mode] = try store(mode).metadata(String.self, key: "dismissedRecap")
                    }
                    guard !snapshot.tags.isEmpty else { continue }
                    let cached = try store(mode).report(digest: snapshot.digest, language: L10n.language, epoch: captured.epoch)
                    if cached?.isValid(for: snapshot) == true { continue }
                    let report = await StatisticalInsightService.report(snapshot: snapshot, control: captured, language: L10n.language)
                    try Task.checkCancellation()
                    guard control.enabled, control.epoch == captured.epoch else { return }
                    try store(mode).saveReport(report)
                } catch is CancellationError { return }
                catch { self.error = L10n.text("Unable to update taste analysis.") }
            }
        }
    }
}
