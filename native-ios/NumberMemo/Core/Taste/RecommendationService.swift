import Foundation
import GRDB

struct TasteRecommendation: Identifiable, Sendable {
    let item: TasteItem
    let post: BooruPost?
    let gallery: NativeGallery?
    let reason: TasteTag
    let score: Double
    var rankingTags: Set<String>? = nil
    var id: String { item.key }
}
struct RecommendationCursor: Sendable {
    var pages: [String: Int] = [:]
    var finished: Set<String> = []
    var fingerprints: [String: String] = [:]
    var pendingPosts: [String: [BooruPost]] = [:]
    var hasMore = true
}
struct TasteRecommendations: Sendable {
    var items: [TasteRecommendation] = []
    var failures: [String] = []
    var unsupportedSort = false
    var unsupportedSources: Set<String> = []
    var cursor = RecommendationCursor()
}

struct RecommendationService {
    /// The library-wide evidence and denominator are constant for every
    /// candidate from a source. Build them once for each requested page.
    struct ScoringProfile: Sendable {
        private struct WeightedTag: Sendable { let name: String; let weight: Double }
        private let source: String
        private let tags: [WeightedTag]
        private let positions: [String: [Int]]
        private let norm: Double

        init(source: String, tags: [TasteTag]) {
            self.source = source
            let matching = tags.filter { $0.source == source }
            let profile = matching.filter { $0.count > 0 }
            let libraryCount = max(1, Set(profile.flatMap { $0.works.map(\.key) }).count)
            func importance(_ tag: TasteTag) -> Double {
                let confidence = Double(tag.count) / Double(tag.count + 4)
                let rarity = 1 + log(1 + Double(libraryCount) / Double(1 + tag.works.count))
                return tag.weight * confidence * rarity
            }
            norm = sqrt(profile.reduce(0) { $0 + pow(importance($1), 2) })
            // Preserve the original tag order, including duplicate names, so
            // floating-point sums and tie-breaking do not change.
            self.tags = matching.map { WeightedTag(name: $0.name, weight: importance($0)) }
            positions = Dictionary(grouping: matching.indices, by: { matching[$0].name })
        }

        func score(_ item: TasteItem, ignoring: Set<String> = []) -> Double {
            guard item.source == source else { return 0 }
            let eligible = Set(item.eligibleTags.filter { !ignoring.contains(TasteControl.normalizeExclusion($0)) })
            return score(eligibleTags: eligible)
        }

        func score(eligibleTags: Set<String>) -> Double {
            // Only visit matched tags while preserving the original profile's
            // summation order, including duplicate names and floating-point ties.
            let matched = eligibleTags.flatMap { positions[$0] ?? [] }.sorted().reduce(0.0) { $0 + tags[$1].weight }
            return matched / max(1, norm * sqrt(Double(max(1, eligibleTags.count))))
        }
    }

    static func score(_ item: TasteItem, tags: [TasteTag], ignoring: Set<String> = []) -> Double {
        ScoringProfile(source: item.source, tags: tags).score(item, ignoring: ignoring)
    }
    static func mix(_ candidates: [TasteRecommendation], limit: Int = 20, shuffled: Bool = false) -> [TasteRecommendation] {
        let sorted = candidates.sorted { $0.score == $1.score ? $0.id < $1.id : $0.score > $1.score }
        var seen = Set<String>()
        let unique = sorted.filter { seen.insert($0.id).inserted }
        // Maximal marginal relevance discourages near-duplicate tag combinations.
        // Small jitter varies equally useful choices without discarding relevance.
        let rankingTags = Dictionary(uniqueKeysWithValues: unique.map { ($0.id, $0.rankingTags ?? Set($0.item.eligibleTags)) })
        var remaining = unique
        let jitter = Dictionary(uniqueKeysWithValues: unique.map { ($0.id, shuffled ? Double.random(in: 0.9...1.1) : 1) })
        var result: [TasteRecommendation] = []
        let maximum = max(0.001, unique.map(\.score).max() ?? 1)
        while !remaining.isEmpty && result.count < limit {
            if Task.isCancelled { break }
            let wantDiscovery = result.count % 10 >= 7
            let eligible = remaining.filter { $0.reason.discovery == wantDiscovery }
            let pool = eligible.isEmpty ? remaining : eligible
            func utility(_ candidate: TasteRecommendation) -> Double {
                let tags = rankingTags[candidate.id] ?? []
                var overlap = 0.0
                for other in result.suffix(8) where other.item.source == candidate.item.source {
                    let theirs = rankingTags[other.id] ?? []
                    let intersection = tags.reduce(0) { $0 + (theirs.contains($1) ? 1 : 0) }
                    overlap = max(overlap, Double(intersection) / Double(max(1, tags.count + theirs.count - intersection)))
                }
                return 0.8 * candidate.score / maximum * jitter[candidate.id, default: 1] - 0.2 * overlap
            }
            // Compute each utility once; max(by:) otherwise recomputes both
            // sides (and their tag intersections) for every comparison.
            guard let next = pool.map({ (item: $0, utility: utility($0)) }).max(by: { $0.utility < $1.utility })?.item else { break }
            result.append(next); remaining.removeAll { $0.id == next.id }
        }
        return result
    }
    @MainActor
    static func load(mode: TasteMode, snapshot: TasteSnapshot, report: TasteReport?, env: AppEnvironment, language: String,
                     booruSource: any BooruProviding = BooruClient.shared, comicSource: any ContentProviding = MangaContentSource.shared, sourceAddress: String? = nil, sourceAddresses: [String]? = nil, preferencesOverride: [String: RecommendationPreferences]? = nil, cursor: RecommendationCursor = .init(), excluding: Set<String> = [], shuffled: Bool = false, seedOffset: Int = 0, requestTimeout: TimeInterval = 35) async throws -> TasteRecommendations {
        try Task.checkCancellation()
        guard env.taste.control.enabled else { return .init() }
        func settings(for source: String) -> RecommendationPreferences {
            if let value = preferencesOverride?[source] { return value }
            return env.taste.control.preferences(source: source)
        }
        var output = TasteRecommendations(); output.cursor = cursor
        var activeSeeds = Set<String>()
        let highlighted = Set(report?.insights.map(\.tagKey) ?? [])
        let tags = snapshot.tags.filter { $0.count > 0 && TasteTagPolicy.eligible($0.name) && env.taste.control.allows($0.name, source: $0.source, mode: mode) }.sorted {
            if highlighted.contains($0.id) != highlighted.contains($1.id) { return highlighted.contains($0.id) }
            return $0.weight == $1.weight ? $0.id < $1.id : $0.weight > $1.weight
        }
        let scoringProfiles = Dictionary(grouping: tags, by: \.source).mapValues {
            ScoringProfile(source: $0[0].source, tags: $0)
        }
        func seeds(_ source: String) -> [TasteTag] {
            let matching = tags.filter { $0.source == source }
            func rotate(_ values: [TasteTag], count: Int) -> [TasteTag] {
                let pool = Array(values.prefix(8))
                guard !pool.isEmpty else { return [] }
                return (0..<min(count, pool.count)).map { pool[(max(0, seedOffset) + $0) % pool.count] }
            }
            if settings(for: source).sort != .recommended { return Array(matching.prefix(1)) }
            return rotate(matching.filter { !$0.discovery }, count: 2) + rotate(matching.filter(\.discovery), count: 1)
        }
        if mode == .booru {
            let rating = BooruRating(rawValue: ReaderPreferences.booruDefaults.string(forKey: "booru.rating") ?? "all") ?? .all
            let saved = env.booru.favoriteIDs
            // Each server owns its seed selection, cursor, filtering and timeout.
            // HTML-backed engines fetch fewer seeds because detail requests serialize in WebKit.
            let control = env.taste.control
            let addresses = sourceAddresses ?? sourceAddress.map { [$0] } ?? env.booru.selectedServers.map(\.canonicalAddress)
            let servers = env.booru.servers.filter { addresses.contains($0.canonicalAddress) }
            let plans = servers.map { server in
                let available = seeds(server.canonicalAddress)
                let htmlSeed = max(0, seedOffset) % 3 == 2 ? available.first(where: \.discovery) ?? available.first : available.first
                let selected = server.engine.usesGelbooruPages ? htmlSeed.map { [$0] } ?? [] : available
                return (server, selected, BooruBlacklist(env.booru.blacklist(serverID: server.id)))
            }
            await withTaskGroup(of: TasteRecommendations.self) { group in
                for (server, selected, blacklist) in plans {
                    let preferences = settings(for: server.canonicalAddress)
                    let scoped = selected.map { (seed: $0, key: server.id + "|" + server.engine.rawValue + "|" + rating.rawValue + "|" + $0.id) }
                    activeSeeds.formUnion(scoped.map(\.key))
                    group.addTask { @MainActor in
                        var result = TasteRecommendations(); result.cursor = cursor
                        result.cursor.pendingPosts = cursor.pendingPosts.filter { $0.key.hasPrefix(server.id + "|") }
                        var detailFailures = false
                        let started = Date()
                        do {
                            for (seed, key) in scoped where !cursor.finished.contains(key) || !(cursor.pendingPosts[key] ?? []).isEmpty {
                                try Task.checkCancellation()
                                var candidates = cursor.pendingPosts[key] ?? []
                                if candidates.isEmpty {
                                    let page = cursor.pages[key, default: 0]
                                    let query = ([seed.name] + preferences.includedTags).joined(separator: " ")
                                    let sort: BooruSort = preferences.sort.booruSort ?? .latest
                                    // Give each listing the same document-loading allowance as Explore.
                                    // A slow detail page must not discard a successful listing.
                                    let batch = try await RecommendationDeadline.run(seconds: requestTimeout) {
                                        try await BooruSortValidation.posts(source: booruSource, server: server, query: rating.query(query, server: server), page: page, sort: sort)
                                    }
                                    try Task.checkCancellation()
                                    env.booru.recordGoldRestrictions(serverID: server.id, postIDs: batch.goldRestrictedIDs)
                                    let fingerprint = (batch.posts.map(\.id) + batch.goldRestrictedIDs.sorted().map { "gold:\($0)" }).joined(separator: ",")
                                    if !batch.hasMore || batch.sourcePostCount == 0 || cursor.fingerprints[key] == fingerprint { result.cursor.finished.insert(key) }
                                    result.cursor.fingerprints[key] = fingerprint
                                    result.cursor.pages[key] = page + 1
                                    candidates = batch.posts
                                }
                                var deferred: [BooruPost] = []
                                let detailStart = Date(), detailBudget = min(12, requestTimeout)
                                var hydrated = 0
                                for var post in candidates where !saved.contains(post.id) {
                                    try Task.checkCancellation()
                                    guard env.booru.isVisible(post), !excluding.contains(server.canonicalAddress + "#" + String(post.postID)) else { continue }
                                    var names = Set(post.tags.map(TasteTagPolicy.normalize))
                                    let needsDetails = !names.contains(seed.name) || !preferences.includedTags.allSatisfy(names.contains) || rating != .all && post.rating.isEmpty
                                    if server.engine.usesGelbooruPages && needsDetails {
                                        let remaining = detailBudget - Date().timeIntervalSince(detailStart)
                                        guard hydrated < 4, remaining > 0 else { deferred.append(post); continue }
                                        hydrated += 1
                                        let unresolved = post
                                        do {
                                            post = try await RecommendationDeadline.run(seconds: min(6, remaining)) {
                                                try await booruSource.details(server: server, post: unresolved)
                                            }
                                            names = Set(post.tags.map(TasteTagPolicy.normalize))
                                        } catch is CancellationError { throw CancellationError() }
                                        catch BooruPostAccessError.goldRequired { env.booru.recordGoldRestriction(unresolved); continue }
                                        catch { detailFailures = true; continue }
                                    }
                                    guard env.booru.isVisible(post), !blacklist.contains(post), ratingAllows(rating, post: post, server: server) else { continue }
                                    let item = TasteItem(source: server.canonicalAddress, id: post.postID, tags: post.tags, metadata: post.metadataTags ?? [])
                                    let eligible = Set(item.eligibleTags)
                                    guard eligible.contains(seed.name), preferences.includedTags.allSatisfy(names.contains) else { continue }
                                    let rankingTags = eligible.filter { control.allows($0, source: item.source, mode: mode) }
                                    result.items.append(.init(item: item, post: post, gallery: nil, reason: seed, score: scoringProfiles[item.source]?.score(eligibleTags: rankingTags) ?? 0, rankingTags: rankingTags))
                                }
                                // Resume unresolved candidates before fetching another page, even
                                // when this was the website's last page. Never silently skip them.
                                result.cursor.pendingPosts[key] = deferred
                                if Date().timeIntervalSince(started) >= requestTimeout { break }
                            }
                            if detailFailures && result.items.isEmpty { result.failures = [server.displayName] }
                        } catch is UnsupportedBooruSort { result.unsupportedSort = true; result.unsupportedSources.insert(server.canonicalAddress) }
                        catch { result.failures = [server.displayName] }
                        return result
                    }
                }
                for await result in group {
                    output.unsupportedSort = output.unsupportedSort || result.unsupportedSort
                    output.unsupportedSources.formUnion(result.unsupportedSources)
                    output.items += result.items
                    output.failures += result.failures
                    // Only each task's changed keys are merged; unrelated cursors remain intact.
                    for (key, page) in result.cursor.pages where page != cursor.pages[key] { output.cursor.pages[key] = page }
                    for (key, value) in result.cursor.fingerprints where value != cursor.fingerprints[key] { output.cursor.fingerprints[key] = value }
                    for (key, posts) in result.cursor.pendingPosts { output.cursor.pendingPosts[key] = posts }
                    output.cursor.finished.formUnion(result.cursor.finished)
                }
            }

        } else if env.isSiteVerified {
            let preferences = settings(for: "https://manga.la")
            var fetched = Set<Int64>()
            for seed in seeds("https://manga.la") {
                activeSeeds.insert(seed.id)
                guard !cursor.finished.contains(seed.id) else { continue }
                let page = cursor.pages[seed.id, default: 0]
                try Task.checkCancellation()
                guard env.taste.control.enabled else { return .init() }
                do {
                    let query = GalleryQuery(language: preferences.language, text: seed.name, sort: GallerySort(rawValue: preferences.sort.rawValue) ?? .latest).applyingDefaults(tags: preferences.includedTags.joined(separator: " "), excluded: env.defaultExcludedTags)
                    let batch = try await comicSource.list(query, offset: page * 24, count: 24)
                    let fingerprint = batch.ids.map(String.init).joined(separator: ",")
                    let candidates = batch.ids.filter { fetched.insert($0).inserted && !excluding.contains("https://manga.la#" + String($0)) }
                    let saved = try savedComicIDs(candidates, database: env.database)
                    let ids = candidates.filter { !saved.contains($0) }
                    let pendingIDs = ids
                    let galleries = try await RecommendationDeadline.run(seconds: requestTimeout) {
                        try await loadGalleries(pendingIDs, source: comicSource)
                    }
                    if !ids.isEmpty && galleries.isEmpty { throw ContentError.invalidResponse }
                    // Recheck after metadata awaits so saving a work while the
                    // request runs still excludes it, using one indexed query.
                    let savedAfterLoading = try savedComicIDs(galleries.map(\.id), database: env.database)
                    for gallery in galleries {
                        let id = gallery.id
                        try Task.checkCancellation()
                        guard !savedAfterLoading.contains(id) else { continue }
                        let item = TasteItem(source: "https://manga.la", id: id, tags: gallery.tags)
                        let eligible = Set(item.eligibleTags)
                        guard eligible.contains(seed.name), !excluding.contains(item.key) else { continue }
                        let rankingTags = eligible.filter { env.taste.control.allows($0, source: item.source, mode: mode) }
                        output.items.append(.init(item: item, post: nil, gallery: gallery, reason: seed, score: scoringProfiles[item.source]?.score(eligibleTags: rankingTags) ?? 0, rankingTags: rankingTags))
                    }
                    if !batch.hasMore || batch.ids.isEmpty || cursor.fingerprints[seed.id] == fingerprint { output.cursor.finished.insert(seed.id) }
                    output.cursor.fingerprints[seed.id] = fingerprint
                    output.cursor.pages[seed.id] = page + 1
                } catch is CancellationError { throw CancellationError() }
                catch { if !output.failures.contains("manga.la") { output.failures.append("manga.la") } }
            }
        }
        output.cursor.hasMore = activeSeeds.contains { !output.cursor.finished.contains($0) || !(output.cursor.pendingPosts[$0] ?? []).isEmpty }
        let items = output.items.filter { $0.post.map(env.booru.isVisible) ?? true }
        let preferences = Dictionary(uniqueKeysWithValues: Set(items.map { $0.item.source }).map { ($0, settings(for: $0)) })
        let ranking = Task.detached(priority: .userInitiated) { rank(items, preferences: preferences, mode: mode, shuffled: shuffled) }
        output.items = await withTaskCancellationHandler { await ranking.value } onCancel: { ranking.cancel() }
        try Task.checkCancellation()
        guard env.taste.control.enabled else { return .init() }
        output.items.removeAll { $0.post.map { !env.booru.isVisible($0) } ?? false }
        return output
    }

    private static func savedComicIDs(_ ids: [Int64], database: AppDatabase) throws -> Set<Int64> {
        guard !ids.isEmpty else { return [] }
        return try database.dbWriter.read { db in
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
            return Set(try Int64.fetchAll(db, sql: "SELECT gallery_id FROM works WHERE gallery_id IN (\(placeholders))", arguments: StatementArguments(ids)))
        }
    }

    private static func rank(_ candidates: [TasteRecommendation], preferences: [String: RecommendationPreferences], mode: TasteMode, shuffled: Bool) -> [TasteRecommendation] {
        let grouped = Dictionary(grouping: candidates, by: { $0.item.source })
        // Interleave independent server decks; never compare unrelated tag profiles.
        let decks = grouped.keys.sorted().map { address -> [TasteRecommendation] in
            var items = grouped[address] ?? []
            let preference = preferences[address] ?? .init()
            if preference.sort == .recommended { return mix(items, limit: items.count, shuffled: shuffled) }
            if preference.sort == .latest { items.sort { $0.item.id > $1.item.id } }
            else if mode == .booru, let sort = preference.sort.booruSort,
                    items.allSatisfy({ $0.post.flatMap { sort.metric($0) } != nil }) {
                items.sort { ($0.post.flatMap { sort.metric($0) } ?? 0) > ($1.post.flatMap { sort.metric($0) } ?? 0) }
            }
            var seen = Set<String>(); return items.filter { seen.insert($0.id).inserted }
        }
        return (0..<(decks.map(\.count).max() ?? 0)).flatMap { index in decks.compactMap { $0.indices.contains(index) ? $0[index] : nil } }
    }
    static func loadGalleries(_ ids: [Int64], source: any ContentProviding) async throws -> [NativeGallery] {
        try await withThrowingTaskGroup(of: (Int, NativeGallery?).self) { group in
            var next = 0, results: [Int: NativeGallery] = [:]
            func enqueue(_ index: Int) { group.addTask { (index, try? await source.gallery(ids[index])) } }
            for _ in 0..<min(4, ids.count) { enqueue(next); next += 1 }
            for try await (index, gallery) in group {
                try Task.checkCancellation()
                if let gallery { results[index] = gallery }
                if next < ids.count { enqueue(next); next += 1 }
            }
            return results.keys.sorted().compactMap { results[$0] }
        }
    }
    static func ratingAllows(_ rating: BooruRating, post: BooruPost, server: BooruServer) -> Bool {
        guard rating != .all, !server.isSafeOnly else { return true }
        let expected: String
        switch rating { case .general: expected = "g"; case .sensitive: expected = "s"; case .questionable: expected = "q"; case .explicit: expected = "e"; case .all: return true }
        return post.rating == expected
    }
}

/// A deadline must return even when a WebKit callback ignores task cancellation.
/// The losing request is cancelled and its late result cannot mutate the feed.
@MainActor
private final class RecommendationDeadline<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Error>?
    private var operation: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var cancelled = false
    private func resolve(_ result: Result<Value, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        operation?.cancel(); timer?.cancel(); operation = nil; timer = nil
        continuation.resume(with: result)
    }
    static func run(seconds: TimeInterval, operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        let deadline = RecommendationDeadline()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                deadline.continuation = continuation
                if deadline.cancelled { deadline.resolve(.failure(CancellationError())); return }
                deadline.operation = Task {
                    do { deadline.resolve(.success(try await operation())) }
                    catch { deadline.resolve(.failure(error)) }
                }
                deadline.timer = Task {
                    do { try await Task.sleep(for: .seconds(seconds)); deadline.resolve(.failure(URLError(.timedOut))) }
                    catch { }
                }
            }
        } onCancel: {
            Task { @MainActor in deadline.cancelled = true; deadline.resolve(.failure(CancellationError())) }
        }
    }
}
