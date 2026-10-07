import XCTest
import GRDB
@testable import NumberMemo

final class BooruLibraryTests: XCTestCase {
    func testLegacyImportFoldersAreRepairedOnUpgradeAndReimport() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) } }
        let backup = try AnimeBoxesBackup.parse(BooruUITestSupport.importFixture)
        let store = try BooruStore(path: url.path)
        var options = AnimeBoxesImportOptions(); options.folderID = "anime-boxes"
        _ = try store.importAnimeBoxes(backup, options: options)
        let custom = try store.saveFolder(name: "My picks")
        let preserved = BooruFixtureSource.post(999, server: backup.servers[0])
        try store.saveFavorite(preserved, folderID: custom)
        let dates = try store.database.read { try Double.fetchAll($0, sql: "SELECT saved_at FROM favorites ORDER BY server_id, post_id") }
        // Simulate a database written by the previous app version.
        try store.database.write { try $0.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'booru_v6_import_site_folders'") }
        let upgraded = try BooruStore(path: url.path)
        for server in backup.servers {
            XCTAssertEqual(upgraded.favorites(serverIDs: [server.id], folderID: "site:" + server.canonicalAddress).count, 1)
        }
        XCTAssertEqual(upgraded.folderID(for: preserved), custom)
        XCTAssertEqual(try upgraded.database.read { try Double.fetchAll($0, sql: "SELECT saved_at FROM favorites ORDER BY server_id, post_id") }, dates)
        // A backup imported later into the former shared folder is repaired on reimport too.
        try upgraded.database.write { db in
            try db.execute(sql: "INSERT INTO folders VALUES ('anime-boxes', 'Anime Boxes', 1, 99)")
            try db.execute(sql: "UPDATE favorites SET folder_id = 'anime-boxes' WHERE post_id = 201")
        }
        let result = try upgraded.importAnimeBoxes(backup, options: .init())
        XCTAssertEqual(result.added, 0)
        XCTAssertEqual(upgraded.visibleFavorites().count, 3)
        XCTAssertEqual(upgraded.folderID(for: preserved), custom)
        XCTAssertFalse(upgraded.folders().contains { $0.id == "anime-boxes" })
    }

    func testAddressDisplayNamesDoNotChangeConnectionAddresses() throws {
        var server = BooruServer.presets[0]
        server.name = "  HTTPS://danbooru.donmai.us/  "
        let store = try BooruStore(); try store.saveServer(server)
        try store.saveFavorite(BooruFixtureSource.post(42, server: server))
        XCTAssertEqual(server.displayName, "danbooru.donmai.us")
        XCTAssertEqual(store.folders().first { $0.id.hasPrefix("site:") }?.displayName, "danbooru.donmai.us")
        XCTAssertEqual(store.servers[0].baseURL.absoluteString, "https://danbooru.donmai.us")
        XCTAssertEqual(BooruServer.displayName("My collection"), "My collection")
        XCTAssertEqual(BooruServer.displayName("https://example.com/booru"), "example.com/booru")
    }

    func testContentControlsMatchPostAndArtistWithoutHidingUnrelatedPosts() {
        let server = BooruServer.presets[0]
        var post = BooruFixtureSource.post(123, server: server)
        post.artists = ["sample_artist"]
        post.tags = ["scenery"]
        XCTAssertTrue(BooruBlacklist("id:123").contains(post))
        XCTAssertFalse(BooruBlacklist("id:124").contains(post))
        XCTAssertTrue(BooruBlacklist("artist:SAMPLE_ARTIST").contains(post))
        XCTAssertFalse(BooruBlacklist("artist:someone_else").contains(post))
        XCTAssertTrue(BooruBlacklist("artist:sample_artist -spoilers").contains(post))
    }

    func testPrivacyPolicyAndRequiredReasonManifestAreBundled() throws {
        for language in ["en", "ko", "ja"] {
            let url = try XCTUnwrap(Bundle.main.url(forResource: "PrivacyPolicy", withExtension: "txt", subdirectory: nil, localization: language))
            let policy = try String(contentsOf: url, encoding: .utf8)
            XCTAssertTrue(policy.contains("contact@nextline.work"))
            XCTAssertTrue(policy.contains("iCloud"))
        }
        let url = try XCTUnwrap(Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"))
        let manifest = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
        XCTAssertEqual(manifest["NSPrivacyTracking"] as? Bool, false)
        let apis = try XCTUnwrap(manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        XCTAssertEqual(apis.first?["NSPrivacyAccessedAPITypeReasons"] as? [String], ["CA92.1", "1C8F.1"])
    }

    func testMultipleSelectionAndFoldersPersistWithoutMixingServers() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try BooruStore(path: path)
        try store.saveServer(BooruServer.presets[0])
        try store.saveServer(BooruServer.presets[2])
        let a = store.servers[0], b = store.servers[1]
        try store.toggleServer(b)
        XCTAssertEqual(store.selectedServers.map(\.id), [a.id, b.id])
        let folder = try store.saveFolder(name: "Landscapes")
        let first = BooruFixtureSource.post(101, server: a), second = BooruFixtureSource.post(101, server: b)
        try store.saveFavorite(first, folderID: folder)
        try store.saveFavorite(second)
        let restored = try BooruStore(path: path)
        XCTAssertEqual(restored.selectedServerIDs, [a.id, b.id])
        XCTAssertEqual(restored.favorites(serverIDs: restored.selectedServerIDs).count, 2)
        XCTAssertEqual(restored.favorites(serverIDs: [a.id, b.id], folderID: folder).map(\.id), [first.id])
        try restored.setBlacklist("scenery", serverID: a.id)
        XCTAssertEqual(restored.visibleFavorites().map(\.id), [second.id])
        try restored.deleteFolder(folder)
        XCTAssertEqual(restored.folderID(for: first), "unsorted")
        XCTAssertTrue(restored.isFavorite(first))
        try restored.toggleServer(a)
        try restored.toggleServer(b) // The last active server cannot be deselected.
        XCTAssertEqual(restored.selectedServerIDs, [b.id])
    }

    func testLegacyFavoritesAndSingleSelectionMigrate() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        do {
            let db = try DatabaseQueue(path: path)
            var migrator = DatabaseMigrator()
            migrator.registerMigration("booru_v1") { db in
                try db.execute(sql: """
                CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                CREATE TABLE servers (id TEXT PRIMARY KEY, payload BLOB NOT NULL, position INTEGER NOT NULL);
                CREATE TABLE favorites (server_id TEXT NOT NULL, post_id INTEGER NOT NULL, payload BLOB NOT NULL, saved_at DOUBLE NOT NULL, PRIMARY KEY(server_id, post_id));
                CREATE TABLE history (server_id TEXT NOT NULL, query TEXT NOT NULL, used_at DOUBLE NOT NULL, PRIMARY KEY(server_id, query));
                CREATE TABLE saved_tags (server_id TEXT NOT NULL, name TEXT NOT NULL, kind TEXT NOT NULL, PRIMARY KEY(server_id, name, kind));
                CREATE INDEX favorite_date ON favorites(server_id, saved_at DESC);
                """)
                let server = BooruServer.presets[1]
                try db.execute(sql: "INSERT INTO servers VALUES (?, ?, 0)", arguments: [server.id, try JSONEncoder().encode(server)])
                try db.execute(sql: "INSERT INTO favorites VALUES (?, 101, ?, 123)", arguments: [server.id, try JSONEncoder().encode(BooruFixtureSource.post(101, server: server))])
                try db.execute(sql: "INSERT INTO settings VALUES ('selected_server', ?)", arguments: [server.id])
            }
            try migrator.migrate(db)
        }
        let store = try BooruStore(path: path)
        XCTAssertEqual(store.selectedServerIDs, ["gelbooru"])
        XCTAssertEqual(store.favorites(serverIDs: ["gelbooru"], folderID: "site:" + BooruServer.presets[1].canonicalAddress).count, 1)
    }

    func testAnimeBoxesMergeIsIdempotentAndPreservesFoldersAndHitomi() throws {
        let defaults = ReaderPreferences.booruDefaults
        let previous = defaults.object(forKey: "search.retentionDays")
        defaults.removeObject(forKey: "search.retentionDays")
        defer { if let previous { defaults.set(previous, forKey: "search.retentionDays") } }
        let store = try BooruStore()
        for server in BooruServer.presets { try store.saveServer(server) }
        let backup = try AnimeBoxesBackup.parse(BooruUITestSupport.importFixture)
        let hitomi = try AppDatabase.inMemory()
        _ = try hitomi.upsertWork(galleryId: 201, title: "Separate")
        let first = try store.importAnimeBoxes(backup, options: .init())
        XCTAssertEqual(first.added, 2)
        XCTAssertEqual(store.selectedServerIDs, ["danbooru", "gelbooru"])
        XCTAssertEqual(store.favorites(serverIDs: store.selectedServerIDs).count, 2)
        for server in store.selectedServers {
            XCTAssertEqual(store.favorites(serverIDs: [server.id], folderID: "site:" + server.canonicalAddress).count, 1)
        }
        let post = try XCTUnwrap(store.favorites(serverID: "danbooru").first)
        let custom = try store.saveFolder(name: "Keep this folder")
        try store.saveFavorite(post, folderID: custom)
        let second = try store.importAnimeBoxes(backup, options: .init())
        XCTAssertEqual(second.added, 0)
        XCTAssertEqual(second.duplicates, 2)
        XCTAssertEqual(store.folderID(for: post), custom)
        XCTAssertEqual(store.servers.count, 3)
        XCTAssertEqual(store.blacklist(serverID: "danbooru"), "spoilers")
        XCTAssertEqual(store.history(serverID: "gelbooru"), ["scenery"], "Imported history is retained indefinitely by default")
        XCTAssertEqual(store.savedTags(serverID: "danbooru", kind: "search"), ["scenery"])
        XCTAssertEqual(try hitomi.listWorks().map(\.galleryId), [201])
    }

    func testImportedFavoriteIndexSurvivesReopeningAndTracksRemoval() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let data = Data(String(decoding: BooruUITestSupport.importFixture, as: UTF8.self).replacingOccurrences(of: "201", with: "5194309").utf8)
        do {
            let store = try BooruStore(path: path)
            // Import before the matching servers have been manually configured.
            _ = try store.importAnimeBoxes(.parse(data), options: .init())
        }
        let restored = try BooruStore(path: path)
        for server in restored.selectedServers {
            let post = BooruFixtureSource.post(5194309, server: server)
            XCTAssertTrue(restored.favoriteIDs.contains(post.id))
            XCTAssertTrue(restored.isFavorite(post))
            try restored.saveFavorite(post)
            XCTAssertEqual(restored.favorites(serverID: server.id).count, 1)
            try restored.toggleFavorite(post)
            XCTAssertFalse(restored.favoriteIDs.contains(post.id))
            XCTAssertFalse(restored.isFavorite(post))
        }
    }

    func testAnimeBoxesInvalidFileAndUnsupportedEntriesDoNotDestroyData() throws {
        XCTAssertThrowsError(try AnimeBoxesBackup.parse(Data("{}".utf8)))
        XCTAssertThrowsError(try AnimeBoxesBackup.parse(Data(#"{"servers":[],"favorites":[],"backupVersion":"99"}"#.utf8)))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: BooruUITestSupport.importFixture) as? [String: Any])
        json["servers"] = [["serverName": "Unknown", "url": "https://unknown.invalid", "type": 999]]
        let invalid = try AnimeBoxesBackup.parse(JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(invalid.skippedServers, 1)
        XCTAssertEqual(invalid.skippedFavorites, 2)
        let store = try BooruStore()
        XCTAssertThrowsError(try store.importAnimeBoxes(invalid, options: .init()))
        XCTAssertTrue(store.servers.isEmpty)
        XCTAssertEqual(store.folders().count, 1)
        let valid = try AnimeBoxesBackup.parse(BooruUITestSupport.importFixture)
        var options = AnimeBoxesImportOptions(); options.folderID = "missing"
        XCTAssertThrowsError(try store.importAnimeBoxes(valid, options: options))
        XCTAssertEqual(store.favorites(serverIDs: store.servers.map(\.id)).count, 0)
    }

    func testModePreferencesRemainIndependentAndPreserveLegacyValues() throws {
        let name = "settings-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let db = try AppDatabase.inMemory()
        let env = AppEnvironment(database: db, browserPreferences: defaults)
        XCTAssertEqual(env.mode, .booru)
        XCTAssertEqual(env.gridColumns, 0)
        XCTAssertFalse(env.isSiteVerified)
        env.mode = .hitomi
        XCTAssertEqual(env.gridColumns, 0)
        env.gridColumns = 4; env.appTheme = .light
        env.defaultTags = "tag:scenery"; env.defaultExcludedTags = "tag:spoilers"
        env.mode = .booru
        XCTAssertEqual(env.gridColumns, 0)
        XCTAssertEqual(env.appTheme, .dark)
        env.gridColumns = 5; env.appTheme = .system
        env.mode = .hitomi
        XCTAssertEqual(env.gridColumns, 4)
        XCTAssertEqual(env.appTheme, .light)
        let restored = AppEnvironment(database: db, browserPreferences: defaults)
        XCTAssertEqual(restored.defaultTags, "tag:scenery")
        XCTAssertEqual(restored.defaultExcludedTags, "tag:spoilers")
        XCTAssertEqual(restored.gridColumns, 4)
        restored.mode = .booru
        XCTAssertEqual(restored.gridColumns, 5)
        XCTAssertEqual(restored.appTheme, .system)
    }

    func testHitomiDefaultTagsComposeWithoutLosingLanguageArtistOrSort() {
        let original = GalleryQuery(language: "japanese", artist: "sample", text: "tag:scenery character:sample", sort: .week)
        let result = original.applyingDefaults(tags: "tag:scenery\ntag:landscape", excluded: "tag:spoilers -tag:gore")
        XCTAssertEqual(result.text, "tag:scenery character:sample tag:landscape -tag:spoilers -tag:gore")
        XCTAssertEqual(result.language, "japanese")
        XCTAssertEqual(result.artist, "sample")
        XCTAssertEqual(result.sort, .week)
        XCTAssertEqual(original.text, "tag:scenery character:sample")
    }

    @MainActor func testCancelledRefreshPreservesPostsAndEmptyQueryCanReload() async throws {
        let loader = BooruFeedLoader(), server = BooruServer.presets[0]
        await loader.load(server: server, source: PartialBooruSource(), query: "", reset: true)
        XCTAssertEqual(loader.posts.map(\.postID), [1])
        let task = Task { await loader.load(server: server, source: PartialBooruSource(), query: "slow", reset: true) }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(loader.posts.map(\.postID), [1])
        task.cancel()
        await task.value
        XCTAssertEqual(loader.posts.map(\.postID), [1])
        XCTAssertTrue(loader.errors.isEmpty)
        XCTAssertFalse(loader.loading)
        await loader.load(server: server, source: PartialBooruSource(), query: "", reset: true)
        XCTAssertEqual(loader.posts.map(\.postID), [1])
        XCTAssertTrue(loader.didLoad)
    }

    func testSavedLibraryIgnoresExploreSelectionAndDefaultsToSiteFolders() throws {
        let store = try BooruStore()
        let a = BooruServer.presets[0], b = BooruServer.presets[1]
        try store.saveServer(a); try store.saveServer(b)
        let first = BooruFixtureSource.post(1, server: a), second = BooruFixtureSource.post(2, server: b)
        try store.toggleFavorite(first); try store.saveFavorite(second)
        try store.setSelectedServers([a.id])
        XCTAssertEqual(Set(store.visibleFavorites().map(\.id)), Set([first.id, second.id]))
        XCTAssertEqual(store.folderID(for: first), "site:" + a.canonicalAddress)
        XCTAssertEqual(store.folderID(for: second), "site:" + b.canonicalAddress)
        try store.setBlacklist("id:1", serverID: a.id)
        try store.setSelectedServers([b.id])
        XCTAssertEqual(store.visibleFavorites().map(\.id), [second.id])
        let custom = try store.saveFolder(name: "Custom")
        try store.saveFavorite(first, folderID: custom)
        try store.saveFavorite(first)
        XCTAssertEqual(store.folderID(for: first), custom)
    }

    @MainActor func testMultiServerPaginationKeepsWorkingWhenOneServerFails() async {
        let loader = BooruFeedLoader()
        await loader.load(servers: Array(BooruServer.presets.prefix(2)), source: PartialBooruSource(), query: "", reset: true)
        XCTAssertEqual(loader.posts.map(\.serverID), ["danbooru"])
        XCTAssertNotNil(loader.errors["gelbooru"])
        XCTAssertTrue(loader.hasMore)
        await loader.load(servers: Array(BooruServer.presets.prefix(2)), source: PartialBooruSource(), query: "", reset: false)
        XCTAssertEqual(loader.posts.map(\.postID), [1, 2])
        XCTAssertFalse(loader.hasMore)
    }
}

private actor PartialBooruSource: BooruProviding {
    func posts(server: BooruServer, query: String, page: Int) async throws -> BooruBatch {
        if query == "slow" { try await Task.sleep(for: .seconds(1)) }
        if server.id == "gelbooru" { throw URLError(.secureConnectionFailed) }
        return .init(posts: [BooruFixtureSource.post(Int64(page + 1), server: server)], hasMore: page == 0)
    }
    func suggestions(server: BooruServer, token: String) async throws -> [BooruTag] { [] }
    func pools(server: BooruServer, query: String, page: Int) async throws -> [BooruPool] { [] }
    func poolPosts(server: BooruServer, poolID: Int64, page: Int) async throws -> BooruBatch { .init(posts: [], hasMore: false) }
    func notes(server: BooruServer, postID: Int64) async throws -> [BooruNote] { [] }
}
