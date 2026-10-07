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
    private(set) var pageVersion = 0
    @ObservationIgnored private var work: Task<Void, Never>?
    private var generation = UUID()
    private var shown: [String] = []
    private var seedOffset = -1
    private func remember(_ items: [TasteRecommendation]) {
        let ids = Set(items.map(\.id))
        shown.removeAll { ids.contains($0) }
        shown += items.map(\.id)
        if shown.count > 2000 { shown.removeFirst(shown.count - 2000) }
    }
    @ObservationIgnored private let booruSource: any BooruProviding
    @ObservationIgnored private let comicSource: any ContentProviding
    init(booruSource: any BooruProviding = TasteSources.booru, comicSource: any ContentProviding = TasteSources.comic) {
        self.booruSource = booruSource; self.comicSource = comicSource
    }

    func ensureLoaded(mode: TasteMode, env: AppEnvironment, language: String) {
        guard !initialized, env.taste.control.enabled else { return }
        refresh(mode: mode, env: env, language: language)
    }
    func clear() {
        work?.cancel(); work = nil; generation = UUID()
        snapshot = nil; report = nil; results = .init(); error = nil
        loading = false; loadingMore = false; initialized = false; shown = []; seedOffset = -1
    }
    func refresh(mode: TasteMode, env: AppEnvironment, language: String) {
        guard env.taste.control.enabled else { return }
        work?.cancel(); let token = UUID(); generation = token
        discoverySession = UUID().uuidString
        seedOffset += 1
        let selection = seedOffset
        initialized = true; loading = true; loadingMore = false; error = nil
        work = Task {
            defer { if generation == token { loading = false; work = nil } }
            do {
                let value = try await env.taste.snapshot(mode, period: .recommendations, offset: 0)
                try Task.checkCancellation()
                guard generation == token else { return }
                let control = env.taste.control
                var statistical = control; statistical.aiEnabled = false
                let cached = try env.taste.store(mode).report(digest: value.digest, language: L10n.language, epoch: control.epoch)
                var explanation: TasteReport
                if control.aiEnabled, let cached, cached.isValid(for: value), cached.generatedByAI {
                    explanation = cached
                    if !cached.insights.isEmpty {
                        explanation.insights = (0..<cached.insights.count).map { cached.insights[(selection + $0) % cached.insights.count] }
                    }
                }
                else { explanation = await OnDeviceInsightService.report(snapshot: value, control: statistical, language: L10n.language, selectionOffset: selection) }
                var batch = TasteRecommendations(); batch.cursor = results.cursor
                var excluded = Set(shown)
                // Continue the deck before starting another cycle. On wrap, prefer
                // works outside the currently visible page; only a depleted deck repeats.
                for cycle in 0..<3 {
                    for _ in 0..<3 {
                        batch = try await RecommendationService.load(mode: mode, snapshot: value, report: explanation, env: env, language: language,
                            booruSource: booruSource, comicSource: comicSource, useAIOrdering: false, cursor: batch.cursor,
                            excluding: excluded, shuffled: true, seedOffset: selection)
                        if !batch.items.isEmpty || !batch.cursor.hasMore || !batch.failures.isEmpty { break }
                    }
                    if !batch.items.isEmpty || batch.cursor.hasMore || !batch.failures.isEmpty || cycle == 2 { break }
                    batch.cursor = .init()
                    excluded = cycle == 0 ? Set(results.items.map(\.id)) : []
                }
                try Task.checkCancellation()
                guard generation == token, env.taste.control.enabled else { return }
                if batch.items.count > 1, batch.items.map(\.id) == results.items.map(\.id) {
                    batch.items.append(batch.items.removeFirst())
                }
                snapshot = value; report = explanation; results = batch; remember(batch.items); pageVersion += 1; loading = false
                // Cache AI refinements for the next explicit refresh, keeping the visible page stable.
                if control.aiEnabled && !explanation.generatedByAI {
                    let refined = await OnDeviceInsightService.report(snapshot: value, control: control, language: L10n.language)
                    try Task.checkCancellation()
                    guard generation == token, env.taste.control == control else { return }
                    try env.taste.store(mode).saveReport(refined)
                }
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
                    booruSource: booruSource, comicSource: comicSource, useAIOrdering: false, cursor: next, excluding: Set(shown).union(results.items.map(\.id)), shuffled: true, seedOffset: selection)
                try Task.checkCancellation()
                guard token == generation, env.taste.control.enabled else { return }
                next = batch.cursor; added = batch.items; failures = batch.failures
                if !added.isEmpty || !next.hasMore || !failures.isEmpty { break }
            }
            remember(added); results.items += added; results.cursor = next; results.failures = failures
            if !added.isEmpty { pageVersion += 1 }
        } catch is CancellationError { }
        catch { if generation == token { self.error = L10n.text("Unable to update taste analysis.") } }
    }
}
