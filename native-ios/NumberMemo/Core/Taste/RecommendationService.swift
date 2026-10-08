import Foundation

struct TasteRecommendation: Identifiable, Sendable {
    let item: TasteItem
    let post: BooruPost?
    let gallery: NativeGallery?
    let reason: TasteTag
    let score: Double
    var id: String { item.key }
}
struct RecommendationCursor: Sendable {
    var pages: [String: Int] = [:]
    var finished: Set<String> = []
    var fingerprints: [String: String] = [:]
    var hasMore = true
}
struct TasteRecommendations: Sendable {
    var items: [TasteRecommendation] = []
    var failures: [String] = []
    var cursor = RecommendationCursor()
}

struct RecommendationService {
    static func score(_ item: TasteItem, tags: [TasteTag], ignoring: Set<String> = []) -> Double {
        let eligible = Set(item.eligibleTags.filter { !ignoring.contains(TasteControl.normalizeExclusion($0)) })
        let matches = tags.filter { $0.source == item.source && eligible.contains($0.name) }
        return matches.reduce(0) { $0 + $1.weight } / sqrt(Double(max(1, eligible.count)))
    }
    static func mix(_ candidates: [TasteRecommendation], limit: Int = 20, shuffled: Bool = false) -> [TasteRecommendation] {
        let sorted = candidates.sorted { $0.score == $1.score ? $0.id < $1.id : $0.score > $1.score }
        var seen = Set<String>()
        let unique = sorted.filter { seen.insert($0.id).inserted }
        // Randomize within statistically eligible candidates, preserving the discovery mix.
        let discoveries = shuffled ? unique.filter { $0.reason.discovery }.shuffled() : unique.filter { $0.reason.discovery }
        let familiar = shuffled ? unique.filter { !$0.reason.discovery }.shuffled() : unique.filter { !$0.reason.discovery }
        let discoveryCount = min(discoveries.count, Int((Double(limit) * 0.3).rounded(.down)))
        var result = Array(familiar.prefix(limit - discoveryCount)) + Array(discoveries.prefix(discoveryCount))
        let picked = Set(result.map(\.id))
        result += unique.filter { !picked.contains($0.id) }.prefix(max(0, limit - result.count))
        return shuffled ? result.shuffled() : result
    }
    @MainActor
    static func load(mode: TasteMode, snapshot: TasteSnapshot, report: TasteReport?, env: AppEnvironment, language: String,
                     booruSource: any BooruProviding = BooruClient.shared, comicSource: any ContentProviding = HitomiContentSource.shared, useAIOrdering: Bool = true, cursor: RecommendationCursor = .init(), excluding: Set<String> = [], shuffled: Bool = false, seedOffset: Int = 0, requestTimeout: TimeInterval = 20) async throws -> TasteRecommendations {
        guard env.taste.control.enabled else { return .init() }
        var output = TasteRecommendations(); output.cursor = cursor
        var activeSeeds = Set<String>()
        let highlighted = Set(report?.insights.map(\.tagKey) ?? [])
        let tags = snapshot.tags.filter { $0.count > 0 && TasteTagPolicy.eligible($0.name) && env.taste.control.allows($0.name, source: $0.source, mode: mode) }.sorted {
            if highlighted.contains($0.id) != highlighted.contains($1.id) { return highlighted.contains($0.id) }
            return $0.weight == $1.weight ? $0.id < $1.id : $0.weight > $1.weight
        }
        func seeds(_ source: String) -> [TasteTag] {
            let matching = tags.filter { $0.source == source }
            func rotate(_ values: [TasteTag], count: Int) -> [TasteTag] {
                let pool = Array(values.prefix(8))
                guard !pool.isEmpty else { return [] }
                return (0..<min(count, pool.count)).map { pool[(max(0, seedOffset) + $0) % pool.count] }
            }
            return rotate(matching.filter { !$0.discovery }, count: 2) + rotate(matching.filter(\.discovery), count: 1)
        }
        if mode == .booru {
            let rating = BooruRating(rawValue: ReaderPreferences.booruDefaults.string(forKey: "booru.rating") ?? "all") ?? .all
            let saved = env.booru.favoriteIDs
            // Each server owns its seed selection, cursor, filtering and timeout.
            // HTML-backed engines fetch fewer seeds because detail requests serialize in WebKit.
            let control = env.taste.control
            let servers = env.booru.selectedServers
            let plans = servers.map { server in
                let available = seeds(server.canonicalAddress)
                let htmlSeed = max(0, seedOffset) % 3 == 2 ? available.first(where: \.discovery) ?? available.first : available.first
                let selected = server.engine.usesGelbooruPages ? htmlSeed.map { [$0] } ?? [] : available
                return (server, selected, BooruBlacklist(env.booru.blacklist(serverID: server.id)))
            }
            await withTaskGroup(of: TasteRecommendations.self) { group in
                for (server, selected, blacklist) in plans {
                    let scoped = selected.map { (seed: $0, key: server.id + "|" + server.engine.rawValue + "|" + rating.rawValue + "|" + $0.id) }
                    activeSeeds.formUnion(scoped.map(\.key))
                    group.addTask { @MainActor in
                        var result = TasteRecommendations(); result.cursor = cursor
                        do {
                            result = try await RecommendationDeadline.run(seconds: requestTimeout) {
                                var result = TasteRecommendations(); result.cursor = cursor
                                for (seed, key) in scoped where !cursor.finished.contains(key) {
                                    try Task.checkCancellation()
                                    let page = cursor.pages[key, default: 0]
                                    let batch = try await booruSource.posts(server: server, query: rating.query(seed.name, server: server), page: page)
                                    let fingerprint = batch.posts.map(\.id).joined(separator: ",")
                                    if !batch.hasMore || batch.posts.isEmpty || cursor.fingerprints[key] == fingerprint { result.cursor.finished.insert(key) }
                                    result.cursor.fingerprints[key] = fingerprint
                                    result.cursor.pages[key] = page + 1
                                    var hydrated = 0
                                    for var post in batch.posts where !saved.contains(post.id) {
                                        try Task.checkCancellation()
                                        // Public galleries can omit tags/rating. Validate details before ranking;
                                        // never relax rating/blacklist or borrow a different server's profile.
                                        if server.engine.usesGelbooruPages && (!post.tags.contains(seed.name) || rating != .all && post.rating.isEmpty) {
                                            guard hydrated < 8 else { continue }
                                            hydrated += 1
                                            guard let details = try? await booruSource.details(server: server, post: post) else { continue }
                                            post = details
                                        }
                                        guard !blacklist.contains(post), ratingAllows(rating, post: post, server: server) else { continue }
                                        let item = TasteItem(source: server.canonicalAddress, id: post.postID, tags: post.tags, metadata: post.metadataTags ?? [])
                                        guard item.eligibleTags.contains(seed.name), !excluding.contains(item.key) else { continue }
                                        let ignored = Set(item.eligibleTags.filter { !control.allows($0, source: item.source, mode: mode) }.map(TasteControl.normalizeExclusion))
                                        result.items.append(.init(item: item, post: post, gallery: nil, reason: seed, score: score(item, tags: tags, ignoring: ignored)))
                                    }
                                }
                                return result
                            }
                        } catch { result.failures = [server.displayName] }
                        return result
                    }
                }
                for await result in group {
                    output.items += result.items
                    output.failures += result.failures
                    // Only each task's changed keys are merged; unrelated cursors remain intact.
                    for (key, page) in result.cursor.pages where page != cursor.pages[key] { output.cursor.pages[key] = page }
                    for (key, value) in result.cursor.fingerprints where value != cursor.fingerprints[key] { output.cursor.fingerprints[key] = value }
                    output.cursor.finished.formUnion(result.cursor.finished)
                }
            }

        } else if env.isSiteVerified {
            var fetched = Set<Int64>()
            for seed in seeds("https://hitomi.la") {
                activeSeeds.insert(seed.id)
                guard !cursor.finished.contains(seed.id) else { continue }
                let page = cursor.pages[seed.id, default: 0]
                try Task.checkCancellation()
                guard env.taste.control.enabled else { return .init() }
                do {
                    let query = GalleryQuery(language: language, text: seed.name).applyingDefaults(tags: env.defaultTags, excluded: env.defaultExcludedTags)
                    let batch = try await comicSource.list(query, offset: page * 24, count: 24)
                    let fingerprint = batch.ids.map(String.init).joined(separator: ",")
                    for id in batch.ids where fetched.insert(id).inserted && !excluding.contains("https://hitomi.la#" + String(id)) {
                        try Task.checkCancellation()
                        guard try env.database.getWork(galleryId: id) == nil else { continue }
                        let gallery = try await comicSource.gallery(id)
                        let item = TasteItem(source: "https://hitomi.la", id: id, tags: gallery.tags)
                        guard item.eligibleTags.contains(seed.name), !excluding.contains(item.key) else { continue }
                        output.items.append(.init(item: item, post: nil, gallery: gallery, reason: seed, score: score(item, tags: tags, ignoring: Set(item.eligibleTags.filter { !env.taste.control.allows($0, source: item.source, mode: mode) }.map(TasteControl.normalizeExclusion)))))
                    }
                    if !batch.hasMore || batch.ids.isEmpty || cursor.fingerprints[seed.id] == fingerprint { output.cursor.finished.insert(seed.id) }
                    output.cursor.fingerprints[seed.id] = fingerprint
                    output.cursor.pages[seed.id] = page + 1
                } catch is CancellationError { throw CancellationError() }
                catch { if !output.failures.contains("hitomi.la") { output.failures.append("hitomi.la") } }
            }
        }
        output.cursor.hasMore = !activeSeeds.subtracting(output.cursor.finished).isEmpty
        output.items = mix(output.items, limit: output.items.count, shuffled: shuffled)
        if useAIOrdering { output.items = await OnDeviceInsightService.prioritize(output.items, control: env.taste.control) }
        try Task.checkCancellation()
        guard env.taste.control.enabled else { return .init() }
        return output
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
