import XCTest
import GRDB
@testable import NumberMemo

final class LibrarySyncTests: XCTestCase {
    private var suites: [String] = []
    override func tearDown() { for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }; suites = [] }
    private func adapter() throws -> LibrarySyncAdapter {
        func defaults() -> UserDefaults {
            let name = "library-sync-tests-" + UUID().uuidString; suites.append(name)
            return UserDefaults(suiteName: name)!
        }
        return LibrarySyncAdapter(hitomi: try .inMemory(), booru: try BooruStore(), hitomiDefaults: defaults(), booruDefaults: defaults())
    }
    private func exchange(_ a: LibrarySyncAdapter, _ b: LibrarySyncAdapter, _ la: inout LibrarySyncLedger, _ lb: inout LibrarySyncLedger) throws {
        la.capture(try a.snapshot(), device: "A"); lb.capture(try b.snapshot(), device: "B")
        la.merge(lb.changes); lb.merge(la.changes)
        try a.apply(la.changes); try b.apply(lb.changes)
        la.baseline = try a.snapshot(); lb.baseline = try b.snapshot()
    }
    func testManuallyAddedFirstServerSyncsAsUserData() throws {
        let a = try adapter(), b = try adapter()
        let server = BooruServer.presets[2]
        try a.booru.saveServer(server)
        try a.booru.saveFavorite(BooruFixtureSource.post(101, server: server))
        var la = LibrarySyncLedger(), lb = LibrarySyncLedger()
        try exchange(a, b, &la, &lb)
        try b.booru.refresh()
        XCTAssertEqual(b.booru.servers.map(\.canonicalAddress), [server.canonicalAddress])
        XCTAssertEqual(b.booru.favorites(serverIDs: b.booru.servers.map(\.id)).count, 1)
        let row = try XCTUnwrap(try a.snapshot().values.first { $0.table == "booru.servers" })
        XCTAssertFalse(row.isFactoryDefault)
    }

    func testTwoDevicesMergeFoldersWorksSettingsAndOfflineDeletionWithoutLocalPaths() throws {
        let a = try adapter(), b = try adapter()
        let fa = try a.hitomi.createFolder(name: "Art"), fb = try b.hitomi.createFolder(name: "Reading")
        XCTAssertEqual(fa.id, fb.id) // Local IDs collide, global folder identities must not.
        _ = try a.hitomi.upsertWork(galleryId: 100, folderId: fa.id, title: "First")
        _ = try b.hitomi.upsertWork(galleryId: 200, folderId: fb.id, title: "Second")
        try a.hitomi.setThumb(galleryId: 100, status: "ready", path: "/private/device-a/cover.jpg")
        a.hitomiDefaults.set(5, forKey: "grid_columns")
        a.hitomiDefaults.set("tag:landscape", forKey: "hitomi.defaultTags")
        a.booruDefaults.set(true, forKey: "reader.keepAwake")
        var la = LibrarySyncLedger(), lb = LibrarySyncLedger()
        try exchange(a, b, &la, &lb)
        XCTAssertEqual(try a.hitomi.worksCount(), 2); XCTAssertEqual(try b.hitomi.worksCount(), 2)
        XCTAssertEqual(try b.hitomi.getWork(galleryId: 100)?.folders.first?.name, "Art")
        XCTAssertNil(try b.hitomi.getWork(galleryId: 100)?.thumbPath)
        XCTAssertNil(b.hitomiDefaults.object(forKey: "grid_columns")); XCTAssertNil(b.booruDefaults.object(forKey: "reader.keepAwake"))
        XCTAssertEqual(b.hitomiDefaults.string(forKey: "hitomi.defaultTags"), "tag:landscape")
        try a.hitomi.deleteWork(galleryId: 100)
        _ = try b.hitomi.upsertWork(galleryId: 300, folderId: fb.id)
        try exchange(a, b, &la, &lb)
        XCTAssertNil(try b.hitomi.getWork(galleryId: 100)); XCTAssertNotNil(try a.hitomi.getWork(galleryId: 300))
        let old = la.changes
        la.capture(try a.snapshot(), device: "A")
        XCTAssertEqual(old, la.changes, "Applying remote records must not create an endless echo")
    }
    func testBooruServerIdentityAndFolderOrderSurviveMerge() throws {
        let a = try adapter(), b = try adapter()
        let sa = BooruServer(id: "a", name: "Gelbooru", baseURL: URL(string: "https://gelbooru.com")!, engine: .gelbooru)
        let sb = BooruServer(id: "b", name: "Gelbooru", baseURL: URL(string: "https://www.gelbooru.com/")!, engine: .gelbooru)
        try a.booru.saveServer(sa); try b.booru.saveServer(sb)
        let folder = try a.booru.saveFolder(name: "Favorites", color: 0xFF112233)
        try a.booru.reorderFolders([folder, "unsorted"])
        let post = BooruPost(serverID: sa.id, postID: 123, width: 100, height: 100, tags: ["landscape"], artists: [], rating: "g", score: 1, fileExtension: "jpg")
        try a.booru.saveFavorite(post, folderID: folder)
        try a.booru.toggleTag("landscape sky", serverID: sa.id, kind: "search")
        var la = LibrarySyncLedger(), lb = LibrarySyncLedger()
        try exchange(a, b, &la, &lb)
        try b.booru.refresh()
        XCTAssertTrue(b.booru.isFavorite(post.onServer(sb.id)))
        XCTAssertEqual(b.booru.folderID(for: post.onServer(sb.id)), folder)
        XCTAssertEqual(b.booru.folders().first?.id, folder)
        XCTAssertEqual(b.booru.savedTags(serverID: sb.id, kind: "search"), ["landscape sky"])
        try a.booru.deleteFolder(folder)
        try exchange(a, b, &la, &lb)
        XCTAssertEqual(b.booru.folderID(for: post.onServer(sb.id)), "unsorted")
        XCTAssertFalse(b.booru.folders().contains { $0.id == folder })
    }
    func testFreshDeviceDoesNotOverwriteExistingDefaultFolderColor() throws {
        let a = try adapter(), b = try adapter()
        try a.booru.setFolderColor("unsorted", color: 0xFFABCDEF)
        let folder = try XCTUnwrap(a.hitomi.listFolders().first?.id)
        try a.hitomi.setFolderColor(id: folder, color: 0xFF123456)
        var la = LibrarySyncLedger(), lb = LibrarySyncLedger()
        try exchange(a, b, &la, &lb)
        XCTAssertEqual(b.booru.folders().first?.color, 0xFFABCDEF)
        XCTAssertEqual(try b.hitomi.listFolders().first?.color, 0xFF123456)
    }

    func testFileRoundTripAndDeleteTombstoneDoesNotRetainWorkMetadata() throws {
        let a = try adapter()
        _ = try a.hitomi.upsertWork(galleryId: 90, title: "Private title")
        var ledger = LibrarySyncLedger(); ledger.capture(try a.snapshot(), device: "A")
        try a.hitomi.deleteWork(galleryId: 90); ledger.capture(try a.snapshot(), device: "A")
        let deletion = try XCTUnwrap(ledger.changes.values.first { $0.deleted && $0.row.table == "hitomi.works" })
        XCTAssertEqual(Set(deletion.row.values.keys), ["gallery_id"])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let data = try JSONEncoder().encode(LibrarySyncDocument(changes: ledger.changes))
        try CloudLibraryFiles.write(data, to: root.appendingPathComponent("library-A.json"))
        XCTAssertEqual(try CloudLibraryFiles.read(in: root).first?.changes, ledger.changes)
    }
    func testHistoryExpiresButSavedMultiTagSearchDoesNot() throws {
        let a = try adapter()
        try a.hitomi.recordSearch("tag:landscape tag:sky")
        try a.hitomi.toggleSavedSearch("tag:landscape tag:sky")
        try a.hitomi.dbWriter.write { try $0.execute(sql: "UPDATE search_history SET used_at = ?", arguments: [Date().addingTimeInterval(-4 * 86400).timeIntervalSince1970]) }
        XCTAssertTrue(try a.hitomi.searchHistory().isEmpty)
        XCTAssertEqual(try a.hitomi.savedSearches(), ["tag:landscape tag:sky"])
        try a.hitomi.clearSearchHistory()
        XCTAssertEqual(try a.hitomi.savedSearches().count, 1)
    }
    @MainActor func testBookmarkCopiesTheVisibleCoverIntoFolderPreviews() async throws {
        let env = AppEnvironment(database: try .inMemory(), browserPreferences: UserDefaults(suiteName: "cover-test-" + UUID().uuidString)!)
        let source = FixtureContentSource()
        let gallery = try await source.gallery(900000001)
        let images = PageImageStore(source: source)
        _ = try await images.load(gallery.pages[0], galleryID: gallery.id, thumbnail: true)
        _ = try ContentBookmarkAction.toggle(id: gallery.id, gallery: gallery, env: env, images: images)
        for _ in 0..<50 {
            if try env.database.getWork(galleryId: gallery.id)?.thumbStatus == "ready" { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let work = try XCTUnwrap(env.database.getWork(galleryId: gallery.id))
        XCTAssertEqual(work.thumbStatus, "ready")
        let path = try XCTUnwrap(work.thumbPath)
        XCTAssertNotNil(UIImage(contentsOfFile: path))
        XCTAssertEqual(try env.database.folderPreviews().values.flatMap { $0 }.first?.galleryId, gallery.id)
        _ = try ContentBookmarkAction.toggle(id: gallery.id, gallery: gallery, env: env, images: images)
        XCTAssertNil(try env.database.getWork(galleryId: gallery.id))
        try? FileManager.default.removeItem(atPath: path)
    }

    func testPreviouslyFailedCoversAreRetriedWithoutRepeatingTheSameBatch() throws {
        let db = try AppDatabase.inMemory()
        _ = try db.upsertWork(galleryId: 17, title: "Existing item", tags: "sky")
        try db.setThumb(galleryId: 17, status: "failed")
        XCTAssertEqual(try db.worksNeedingFill().map(\.galleryId), [17])
        XCTAssertEqual(try db.countNeedingFill(), 1)
        XCTAssertTrue(try db.worksNeedingFill(exclude: [17]).isEmpty)
    }

    func testOriginalTagIsNotMistakenForTheOriginalImage() throws {
        let html = Data("""
        <html><li><a href="index.php?page=post&amp;s=list&amp;tags=original">original</a></li>
        <img id="image" src="https://img.example/sample.jpg">
        <a href="https://img.example/full.png">Original image</a></html>
        """.utf8)
        let post = try BooruLegacyHTML.post(html, server: BooruServer.presets[1], id: 15029425)
        XCTAssertEqual(post.fileURL?.absoluteString, "https://img.example/full.png")
        XCTAssertEqual(post.fileExtension, "png")
        let withoutDownload = Data("<html><a href='?tags=original'>original</a><img id='image' src='https://img.example/full.jpg'></html>".utf8)
        XCTAssertEqual(try BooruLegacyHTML.post(withoutDownload, server: BooruServer.presets[1], id: 1).fileURL?.path, "/full.jpg")
    }

    func testGelbooruVideoUsesPlayableMP4SourceRatherThanPosterOrWebM() throws {
        let html = Data("<html><video id='image' poster='https://img.example/poster.jpg'><source src='https://video.example/file.webm' type='video/webm'><source src='https://video.example/file.mp4' type='video/mp4'></video><a href='https://video.example/file.webm'>Original video</a></html>".utf8)
        let post = try BooruLegacyHTML.post(html, server: BooruServer.presets[1], id: 10)
        XCTAssertEqual(post.fileURL?.pathExtension, "mp4")
        XCTAssertTrue(post.isVideo)
    }

    func testAnimeBoxesImportMatchesEquivalentServerAddresses() throws {
        let a = try adapter()
        let server = BooruServer(id: "local", name: "Gelbooru", baseURL: URL(string: "https://gelbooru.com")!, engine: .gelbooru)
        try a.booru.saveServer(server)
        let data = Data(#"{"backupVersion":"1.0","servers":[{"serverName":"Gelbooru","url":"https://www.gelbooru.com/","type":1}],"favorites":[{"ppostId":"123","ppostUrl":"https://gelbooru.com/index.php?page=post&s=view&id=123","file":{"url":"https://img.example/a.jpg"}}]}"#.utf8)
        let result = try a.booru.importAnimeBoxes(.parse(data), options: .init())
        XCTAssertEqual(result.serversAdded, 0); XCTAssertEqual(result.added, 1)
        XCTAssertEqual(a.booru.favorites(serverID: server.id).first?.postID, 123)
    }
}
