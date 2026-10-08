import Foundation

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
    static func score(_ item: TasteItem, tags: [TasteTag], ignoring: Set<String> = []) -> Double {
        let eligible = Set(item.eligibleTags.filter { !ignoring.contains(TasteControl.normalizeExclusion($0)) })
        let matches = tags.filter { $0.source == item.source && eligible.contains($0.name) }
        let profile = tags.filter { $0.source == item.source && $0.count > 0 }
        let libraryCount = max(1, Set(profile.flatMap { $0.works.map(\.key) }).count)
        func importance(_ tag: TasteTag) -> Double {
            let confidence = Double(tag.count) / Double(tag.count + 4)
            let rarity = 1 + log(1 + Double(libraryCount) / Double(1 + tag.works.count))
            return tag.weight * confidence * rarity
        }
        let norm = sqrt(profile.reduce(0) { $0 + pow(importance($1), 2) })
        return matches.reduce(0) { $0 + importance($1) } / max(1, norm * sqrt(Double(max(1, eligible.count))))
    }
    static func mix(_ candidates: [TasteRecommendation], limit: Int = 20, shuffled: Bool = false) -> [TasteRecommendation] {
        let sorted = candidates.sorted { $0.score == $1.score ? $0.id < $1.id : $0.score > $1.score }
        var seen = Set<String>()
        let unique = sorted.filter { seen.insert($0.id).inserted }
        // Maximal marginal relevance discourages near-duplicate tag combinations.
        // Small jitter varies equally useful choices without discarding relevance.
        var remaining = unique
        let jitter = Dictionary(uniqueKeysWithValues: unique.map { ($0.id, shuffled ? Double.random(in: 0.9...1.1) : 1) })
        var result: [TasteRecommendation] = []
        let maximum = max(0.001, unique.map(\.score).max() ?? 1)
        while !remaining.isEmpty && result.count < limit {
            let wantDiscovery = result.count % 10 >= 7
            let eligible = remaining.filter { $0.reason.discovery == wantDiscovery }
            let pool = eligible.isEmpty ? remaining : eligible
            func utility(_ candidate: TasteRecommendation) -> Double {
                let tags = candidate.rankingTags ?? Set(candidate.item.eligibleTags)
                let overlap = result.suffix(8).filter { $0.item.source == candidate.item.source }.map { other in
                    let theirs = other.rankingTags ?? Set(other.item.eligibleTags)
                    return Double(tags.intersection(theirs).count) / Double(max(1, tags.union(theirs).count))
                }.max() ?? 0
                return 0.8 * candidate.score / maximum * jitter[candidate.id, default: 1] - 0.2 * overlap
            }
            guard let next = pool.max(by: { utility($0) < utility($1) }) else { break }
            result.append(next); remaining.removeAll { $0.id == next.id }
        }
        return result
    }
    @MainActor
    static func load(mode: TasteMode, snapshot: TasteSnapshot, report: TasteReport?, env: AppEnvironment, language: String,
                     booruSource: any BooruProviding = BooruClient.shared, comicSource: any ContentProviding = HitomiContentSource.shared, sourceAddress: String? = nil, sourceAddresses: [String]? = nil, preferencesOverride: [String: RecommendationPreferences]? = nil, cursor: RecommendationCursor = .init(), excluding: Set<String> = [], shuffled: Bool = false, seedOffset: Int = 0, requestTimeout: TimeInterval = 20) async throws -> TasteRecommendations {
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
                        do {
                            result = try await RecommendationDeadline.run(seconds: requestTimeout) {
                                var result = TasteRecommendations(); result.cursor = cursor
                                for (seed, key) in scoped where !cursor.finished.contains(key) {
                                    try Task.checkCancellation()
                                    let page = cursor.pages[key, default: 0]
                                    let query = ([seed.name] + preferences.includedTags).joined(separator: " ")
                                    let sort: BooruSort = preferences.sort == .week ? .popular : .latest
                                    let batch = try await BooruSortValidation.posts(source: booruSource, server: server, query: rating.query(query, server: server), page: page, sort: sort)
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
                                        guard item.eligibleTags.contains(seed.name), !excluding.contains(item.key), preferences.includedTags.allSatisfy({ Set(post.tags.map(TasteTagPolicy.normalize)).contains($0) }) else { continue }
                                        let ignored = Set(item.eligibleTags.filter { !control.allows($0, source: item.source, mode: mode) }.map(TasteControl.normalizeExclusion))
                                        result.items.append(.init(item: item, post: post, gallery: nil, reason: seed, score: score(item, tags: tags, ignoring: ignored), rankingTags: Set(item.eligibleTags).filter { !ignored.contains(TasteControl.normalizeExclusion($0)) }))
                                    }
                                }
                                return result
                            }
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
                    output.cursor.finished.formUnion(result.cursor.finished)
                }
            }

        } else if env.isSiteVerified {
            let preferences = settings(for: "https://hitomi.la")
            var fetched = Set<Int64>()
            for seed in seeds("https://hitomi.la") {
                activeSeeds.insert(seed.id)
                guard !cursor.finished.contains(seed.id) else { continue }
                let page = cursor.pages[seed.id, default: 0]
                try Task.checkCancellation()
                guard env.taste.control.enabled else { return .init() }
                do {
                    let query = GalleryQuery(language: preferences.language, text: seed.name, sort: GallerySort(rawValue: preferences.sort.rawValue) ?? .latest).applyingDefaults(tags: preferences.includedTags.joined(separator: " "), excluded: env.defaultExcludedTags)
                    let batch = try await comicSource.list(query, offset: page * 24, count: 24)
                    let fingerprint = batch.ids.map(String.init).joined(separator: ",")
                    var ids: [Int64] = []
                    for id in batch.ids where fetched.insert(id).inserted && !excluding.contains("https://hitomi.la#" + String(id)) {
                        if try env.database.getWork(galleryId: id) == nil { ids.append(id) }
                    }
                    let pendingIDs = ids
                    let galleries = try await RecommendationDeadline.run(seconds: requestTimeout) {
                        try await loadGalleries(pendingIDs, source: comicSource)
                    }
                    if !ids.isEmpty && galleries.isEmpty { throw ContentError.invalidResponse }
                    for gallery in galleries {
                        let id = gallery.id
                        try Task.checkCancellation()
                        guard try env.database.getWork(galleryId: id) == nil else { continue }
                        let item = TasteItem(source: "https://hitomi.la", id: id, tags: gallery.tags)
                        guard item.eligibleTags.contains(seed.name), !excluding.contains(item.key) else { continue }
                        let ignored = Set(item.eligibleTags.filter { !env.taste.control.allows($0, source: item.source, mode: mode) }.map(TasteControl.normalizeExclusion))
                        output.items.append(.init(item: item, post: nil, gallery: gallery, reason: seed, score: score(item, tags: tags, ignoring: ignored), rankingTags: Set(item.eligibleTags).filter { !ignored.contains(TasteControl.normalizeExclusion($0)) }))
                    }
                    if !batch.hasMore || batch.ids.isEmpty || cursor.fingerprints[seed.id] == fingerprint { output.cursor.finished.insert(seed.id) }
                    output.cursor.fingerprints[seed.id] = fingerprint
                    output.cursor.pages[seed.id] = page + 1
                } catch is CancellationError { throw CancellationError() }
                catch { if !output.failures.contains("hitomi.la") { output.failures.append("hitomi.la") } }
            }
        }
        output.cursor.hasMore = !activeSeeds.subtracting(output.cursor.finished).isEmpty
        let grouped = Dictionary(grouping: output.items, by: { $0.item.source })
        // Interleave independent server decks; never compare unrelated tag profiles.
        let decks = grouped.keys.sorted().map { address -> [TasteRecommendation] in
            var items = grouped[address] ?? []
            let preference = settings(for: address)
            if preference.sort == .recommended { return mix(items, limit: items.count, shuffled: shuffled) }
            if preference.sort == .latest { items.sort { $0.item.id > $1.item.id } }
            else if mode == .booru { items.sort { ($0.post?.score ?? 0) > ($1.post?.score ?? 0) } }
            var seen = Set<String>(); return items.filter { seen.insert($0.id).inserted }
        }
        output.items = (0..<(decks.map(\.count).max() ?? 0)).flatMap { index in decks.compactMap { $0.indices.contains(index) ? $0[index] : nil } }
        try Task.checkCancellation()
        guard env.taste.control.enabled else { return .init() }
        return output
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
