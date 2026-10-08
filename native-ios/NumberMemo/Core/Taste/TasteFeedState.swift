import Foundation
import Observation

/// Owned by the app, independently of tab/view lifetimes. Only explicit refresh
/// replaces an existing feed; pagination appends without changing its order.
@MainActor @Observable
final class TasteFeedState {
    private(set) var discoverySession = UUID().uuidString
    private(set) var initialized = false
    private(set) var loading = false
    private(set) var loadingMore = false
    private(set) var snapshot: TasteSnapshot?
    private(set) var report: TasteReport?
    private(set) var results = TasteRecommendations()
    private(set) var error: String?
    var sortMessage: String?
    private(set) var pageVersion = 0
    @ObservationIgnored private var work: Task<Void, Never>?
    private var generation = UUID()
    private var shown: [String] = []
    private var seedOffset = -1
    let source: String?
    let sourceAddresses: [String]?
    private var appliedPreferences: [String: RecommendationPreferences]?
    private var previousSorts: [String: RecommendationSort] = [:]
    private func remember(_ items: [TasteRecommendation]) {
        let ids = Set(items.map(\.id))
        shown.removeAll { ids.contains($0) }
        shown += items.map(\.id)
        if shown.count > 2000 { shown.removeFirst(shown.count - 2000) }
    }
    @ObservationIgnored private let booruSource: any BooruProviding
    @ObservationIgnored private let comicSource: any ContentProviding
    init(source: String? = nil, sources: [String]? = nil, booruSource: any BooruProviding = TasteSources.booru, comicSource: any ContentProviding = TasteSources.comic) {
        self.source = source
        self.sourceAddresses = sources ?? source.map { [$0] }
        self.booruSource = booruSource; self.comicSource = comicSource
    }

    func ensureLoaded(mode: TasteMode, env: AppEnvironment, language: String) {
        guard !initialized, env.taste.control.enabled else { return }
        refresh(mode: mode, env: env, language: language)
    }
    func clear() {
        work?.cancel(); work = nil; generation = UUID()
        snapshot = nil; report = nil; results = .init(); error = nil; sortMessage = nil; appliedPreferences = nil; previousSorts = [:]
        loading = false; loadingMore = false; initialized = false; shown = []; seedOffset = -1
    }
    func applyExclusions(_ control: TasteControl, mode: TasteMode) {
        work?.cancel(); work = nil; generation = UUID()
        loading = false; loadingMore = false
        if snapshot == nil { initialized = false }
        if var filtered = snapshot {
            filtered.tags.removeAll { !control.allows($0.name, source: $0.source, mode: mode) }
            filtered.previousTagCounts = filtered.previousTagCounts.filter { key, _ in
                let parts = key.components(separatedBy: "\n")
                return parts.count == 2 && control.allows(parts[1], source: parts[0], mode: mode)
            }
            snapshot = filtered
        }
        let allowed = Set(snapshot?.tags.map(\.id) ?? [])
        report?.insights.removeAll { !allowed.contains($0.tagKey) }
    }

    func refresh(mode: TasteMode, env: AppEnvironment, language: String) {
        guard env.taste.control.enabled, mode == .comics || !(sourceAddresses ?? env.booru.selectedServers.map(\.canonicalAddress)).isEmpty else { return }
        work?.cancel(); let token = UUID(); generation = token
        discoverySession = UUID().uuidString
        seedOffset += 1
        let selection = seedOffset
        initialized = true; loading = true; loadingMore = false; error = nil
        work = Task {
            defer { if generation == token { loading = false; work = nil } }
            do {
                var value = try await env.taste.snapshot(mode, period: .recommendations, offset: 0)
                try Task.checkCancellation()
                guard generation == token else { return }
                let addresses = mode == .comics ? ["https://hitomi.la"] : sourceAddresses ?? env.booru.selectedServers.map(\.canonicalAddress)
                value.tags.removeAll { !addresses.contains($0.source) }
                let control = env.taste.control
                let preferences = Dictionary(uniqueKeysWithValues: addresses.map { ($0, control.preferences(source: $0)) })
                let preferencesChanged = appliedPreferences != preferences
                let explanation = await StatisticalInsightService.report(snapshot: value, control: control, language: L10n.language, selectionOffset: selection)
                var batch = TasteRecommendations(); batch.cursor = preferencesChanged ? .init() : results.cursor
                var excluded = preferencesChanged ? Set<String>() : Set(shown)
                // Continue the deck before starting another cycle. On wrap, prefer
                // works outside the currently visible page; only a depleted deck repeats.
                for cycle in 0..<3 {
                    for _ in 0..<3 {
                        batch = try await RecommendationService.load(mode: mode, snapshot: value, report: explanation, env: env, language: language,
                            booruSource: booruSource, comicSource: comicSource, sourceAddress: source, sourceAddresses: sourceAddresses, preferencesOverride: preferences, cursor: batch.cursor,
                            excluding: excluded, shuffled: true, seedOffset: selection)
                        if batch.unsupportedSort || !batch.items.isEmpty || !batch.cursor.hasMore || !batch.failures.isEmpty { break }
                    }
                    if batch.unsupportedSort || !batch.items.isEmpty || batch.cursor.hasMore || !batch.failures.isEmpty || cycle == 2 { break }
                    batch.cursor = .init()
                    excluded = cycle == 0 ? Set(results.items.map(\.id)) : []
                }
                try Task.checkCancellation()
                guard generation == token, env.taste.control.enabled else { return }
                if batch.unsupportedSort {
                    env.taste.change { control in
                        for address in batch.unsupportedSources {
                            var reverted = preferences[address] ?? .init()
                            reverted.sort = appliedPreferences?[address]?.sort ?? .recommended
                            control.setPreferences(reverted, source: address)
                        }
                    }
                    sortMessage = L10n.text("This server does not support that sort. Your previous sort has been restored.")
                    if snapshot == nil { refresh(mode: mode, env: env, language: language) }
                    return
                }
                for (address, value) in preferences where value.sort != appliedPreferences?[address]?.sort { previousSorts[address] = appliedPreferences?[address]?.sort ?? .recommended }
                appliedPreferences = preferences
                if preferencesChanged { shown = [] }
                if preferences.values.allSatisfy({ $0.sort == .recommended }), batch.items.count > 1, batch.items.map(\.id) == results.items.map(\.id) {
                    batch.items.append(batch.items.removeFirst())
                }
                snapshot = value; report = explanation; results = batch; remember(batch.items); pageVersion += 1; loading = false
            } catch is CancellationError { }
            catch { if generation == token { self.error = L10n.text("Unable to update taste analysis.") } }
        }
    }
    func waitForRefresh() async { await work?.value }

    func loadMore(mode: TasteMode, env: AppEnvironment, language: String) async {
        guard !loading, !loadingMore, results.cursor.hasMore, let snapshot, env.taste.control.enabled else { return }
        loadingMore = true
        let token = generation, selection = seedOffset
        defer { if token == generation { loadingMore = false } }
        do {
            var next = results.cursor
            var added: [TasteRecommendation] = []
            var failures: [String] = []
            // Skip a bounded number of pages containing only saved/filtered works.
            for _ in 0..<3 {
                let batch = try await RecommendationService.load(mode: mode, snapshot: snapshot, report: report, env: env, language: language,
                    booruSource: booruSource, comicSource: comicSource, sourceAddress: source, sourceAddresses: sourceAddresses, preferencesOverride: appliedPreferences, cursor: next, excluding: Set(shown).union(results.items.map(\.id)), shuffled: true, seedOffset: selection)
                try Task.checkCancellation()
                guard token == generation, env.taste.control.enabled else { return }
                if batch.unsupportedSort {
                    env.taste.change { control in
                        for address in batch.unsupportedSources {
                            var value = control.preferences(source: address); value.sort = previousSorts[address] ?? .recommended
                            control.setPreferences(value, source: address)
                        }
                    }
                    sortMessage = L10n.text("This server does not support that sort. Your previous sort has been restored.")
                    results.cursor.hasMore = false
                    return
                }
                next = batch.cursor; added = batch.items; failures = batch.failures
                if !added.isEmpty || !next.hasMore || !failures.isEmpty { break }
            }
            remember(added); results.items += added; results.cursor = next; results.failures = failures
            if !added.isEmpty { pageVersion += 1 }
        } catch is CancellationError { }
        catch { if generation == token { self.error = L10n.text("Unable to update taste analysis.") } }
    }
}
