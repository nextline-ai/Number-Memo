#if DEBUG
import Foundation

enum BooruUITestSupport {
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("--booru-ui-test") }
    static var liveEnabled: Bool { ProcessInfo.processInfo.arguments.contains("--booru-live-ui-test") }
    static let importFixture = Data(#"{"backupVersion":"1.0","servers":[{"serverName":"Danbooru","url":"https://danbooru.donmai.us","type":3,"isSelected":true},{"serverName":"Gelbooru","url":"https://gelbooru.com","type":1,"isSelected":true}],"favorites":[{"ppostId":"201","ppostUrl":"https://danbooru.donmai.us/posts/201","tags":"scenery mountain","tag_artist":"sample_artist","dateAdded":"2026-10-01T10:00:00+0900","file":{"url":"https://fixture.invalid/a.png","width":1600,"height":1200,"ext":"png"}},{"ppostId":"201","ppostUrl":"https://gelbooru.com/index.php?page=post&s=view&id=201","tags":"city","file":{"url":"https://fixture.invalid/b.png","width":1600,"height":1200,"ext":"png"}}],"searchHistory":[{"searchText":"scenery","searchDate":"2026-10-01T10:00:00+0900","starred":true}],"bannedTags":["spoilers"]}"#.utf8)
    static let restoredBadgeFixture = Data(String(decoding: importFixture, as: UTF8.self).replacingOccurrences(of: "201", with: "5194309").utf8)
    static func restoredBadgeStore() throws -> BooruStore {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("restored-badge-test.sqlite").path
        if ProcessInfo.processInfo.arguments.contains("--booru-badge-seed") {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
            let seed = try BooruStore(path: path)
            for server in BooruServer.presets { try seed.saveServer(server) }
            _ = try seed.importAnimeBoxes(.parse(restoredBadgeFixture), options: .init())
        }
        return try BooruStore(path: path)
    }
    static let source = BooruFixtureSource()
}

actor BooruFixtureSource: BooruProviding {
    private var failed = false
    static func post(_ id: Int64, server: BooruServer, tags: [String] = ["scenery", "mountain"]) -> BooruPost {
        .init(serverID: server.id, postID: id, previewURL: URL(string: "https://fixture.invalid/preview.png"),
              sampleURL: URL(string: "https://fixture.invalid/sample.png"), fileURL: URL(string: "https://fixture.invalid/original.png"),
              width: 1600, height: 1200, tags: tags, artists: ["sample_artist"], rating: "g", score: 42,
              fileExtension: id == 104 ? "gif" : id == 105 ? "mp4" : "png", poolIDs: [77])
    }
    func posts(server: BooruServer, query: String, page: Int) async throws -> BooruBatch {
        try await Task.sleep(for: .milliseconds(100))
        if ProcessInfo.processInfo.arguments.contains("--booru-initial-error") && !failed { failed = true; throw URLError(.notConnectedToInternet) }
        if ProcessInfo.processInfo.arguments.contains("--booru-tag-limit-test") && query.contains("mountain") { throw BooruError.unavailable(422) }
        if query == "empty" { return .init(posts: [], hasMore: false) }
        if ProcessInfo.processInfo.arguments.contains("--taste-ui-rich"), !query.isEmpty {
            return .init(posts: ((201 + page * 10)...(212 + page * 10)).map { Self.post(Int64($0), server: server) }, hasMore: page < 2)
        }
        if ProcessInfo.processInfo.arguments.contains("--booru-restored-badge-test") {
            return .init(posts: [Self.post(5194309, server: server)], hasMore: false)
        }
        if ProcessInfo.processInfo.arguments.contains("--booru-import-badge-test") {
            return .init(posts: [Self.post(201, server: server)], hasMore: false)
        }
        if ProcessInfo.processInfo.arguments.contains("--booru-media-test") {
            return .init(posts: [Self.post(104, server: server), Self.post(105, server: server)], hasMore: false)
        }
        let offset: Int64 = ProcessInfo.processInfo.arguments.contains("--booru-multi-test") && server.id == "gelbooru" ? 1000 : 0
        let posts = page == 0 ? [Self.post(101 + offset, server: server), Self.post(102 + offset, server: server, tags: ["city", "night"])] : [Self.post(103 + offset, server: server)]
        return .init(posts: posts, hasMore: page == 0)
    }
    func suggestions(server: BooruServer, token: String) async throws -> [BooruTag] {
        if ProcessInfo.processInfo.arguments.contains("--booru-long-suggestions") {
            return (0..<12).map { BooruTag(name: String(format: "sc_%02d", $0), count: 100 - $0, category: 0) }.filter { $0.name.hasPrefix(token) }
        }
        return [.init(name: "scenery", count: 240, category: 0), .init(name: "sample_artist", count: 42, category: 1)].filter { $0.name.hasPrefix(token) }
    }
    func pools(server: BooruServer, query: String, page: Int) async throws -> [BooruPool] {
        page == 0 ? [.init(id: 78, name: "Empty collection", count: 0, hasKnownCount: true), .init(id: 77, name: "Mountain_collection", count: 2, description: "A synthetic collection for testing.", hasKnownCount: true)] : []
    }
    func poolPosts(server: BooruServer, poolID: Int64, page: Int) async throws -> BooruBatch {
        .init(posts: page == 0 ? [Self.post(102, server: server), Self.post(101, server: server)] : [], hasMore: false)
    }
    func notes(server: BooruServer, postID: Int64) async throws -> [BooruNote] {
        [.init(id: 1, x: 120, y: 90, width: 700, height: 180, body: "A mountain in the morning.")]
    }
}
#endif
