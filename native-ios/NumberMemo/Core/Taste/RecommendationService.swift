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
                     booruSource: any BooruProviding = BooruClient.shared, comicSource: any ContentProviding = HitomiContentSource.shared, useAIOrdering: Bool = true, cursor: RecommendationCursor = .init(), excluding: Set<String> = [], shuffled: Bool = false, seedOffset: Int = 0) async throws -> TasteRecommendations {
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
            for server in env.booru.selectedServers {
                let blacklist = BooruBlacklist(env.booru.blacklist(serverID: server.id))
                for seed in seeds(server.canonicalAddress) {
                    activeSeeds.insert(seed.id)
                    guard !cursor.finished.contains(seed.id) else { continue }
                    let page = cursor.pages[seed.id, default: 0]
                    try Task.checkCancellation()
                    guard env.taste.control.enabled else { return .init() }
                    do {
                        // One content tag leaves room for the rating constraint on limited accounts.
                        let batch = try await booruSource.posts(server: server, query: rating.query(seed.name, server: server), page: page)
                        let fingerprint = batch.posts.map(\.id).joined(separator: ",")
                        if !batch.hasMore || batch.posts.isEmpty || cursor.fingerprints[seed.id] == fingerprint { output.cursor.finished.insert(seed.id) }
                        output.cursor.fingerprints[seed.id] = fingerprint
                        output.cursor.pages[seed.id] = page + 1
                        for post in batch.posts where !saved.contains(post.id) && !blacklist.contains(post) && ratingAllows(rating, post: post, server: server) {
                            let item = TasteItem(source: server.canonicalAddress, id: post.postID, tags: post.tags, metadata: post.metadataTags ?? [])
                            guard item.eligibleTags.contains(seed.name), !excluding.contains(item.key) else { continue }
                            output.items.append(.init(item: item, post: post, gallery: nil, reason: seed, score: score(item, tags: tags, ignoring: Set(item.eligibleTags.filter { !env.taste.control.allows($0, source: item.source, mode: mode) }.map(TasteControl.normalizeExclusion)))))
                        }
                    } catch is CancellationError { throw CancellationError() }
                    catch { if !output.failures.contains(server.displayName) { output.failures.append(server.displayName) } }
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
