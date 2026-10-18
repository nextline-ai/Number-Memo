import XCTest
import GRDB
@testable import NumberMemo

final class GalleryIDParserTests: XCTestCase {
    func testStandardMangaUrl() {
        let url = "https://comics.example/galleries/1234567.html"
        let ids = GalleryIDParser.parse(url)
        XCTAssertEqual(ids, [1234567])
    }

    func testReaderUrl() {
        let url = "https://comics.example/reader/9876543.html#1"
        let ids = GalleryIDParser.parse(url)
        XCTAssertEqual(ids, [9876543])
    }

    func testProxyUrl() {
        let url = "https://proxy.example/galleries/2345678.html?lang=ko"
        let ids = GalleryIDParser.parse(url)
        XCTAssertEqual(ids, [2345678])
    }

    func testNestedShareUrl() {
        let url = "https://share.example/link?u=https%3A%2F%2Fcomics.example%2Fgalleries%2F3456789.html"
        let ids = GalleryIDParser.parse(url)
        XCTAssertEqual(ids, [3456789])
    }

    func testPlainNumberTokens() {
        let text = "품번 모음: 123456, 7891011; 4567890"
        let ids = GalleryIDParser.parse(text)
        XCTAssertEqual(ids, [123456, 7891011, 4567890])
    }

    func testMangaUrlWithYearInTitle() {
        let text = "2024 Manga Comic https://comics.example/galleries/888888.html"
        let ids = GalleryIDParser.parse(text)
        XCTAssertEqual(ids, [888888], "Should prioritize the gallery URL and ignore the year 2024")
    }

    func testUniqueFolderColors() throws {
        let db = try AppDatabase.inMemory()
        var createdColors = Set<Int64>()

        for i in 1...20 {
            let folder = try db.createFolder(name: "Folder \(i)")
            XCTAssertNotNil(folder.id, "Folder ID must not be nil upon creation")
            XCTAssertFalse(createdColors.contains(folder.color), "Color for folder \(i) should be unique and not repeated")
            createdColors.insert(folder.color)
        }

        XCTAssertEqual(createdColors.count, 20, "All 20 folders must have unique colors")
    }

    func testCancelledVioletImportStopsBeforeOpeningTheSource() async throws {
        let database = try AppDatabase.inMemory()
        let importer = VioletImportService(appDb: database)
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try importer.importUserDb(path: "/source-that-must-not-be-opened.db")
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(try database.listWorks().isEmpty)
    }

    func testCancelledCatalogImportCommitsOnlyTheCompletedBatch() async throws {
        let database = try AppDatabase.inMemory()
        let importer = VioletImportService(appDb: database)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("data.db").path
        let source = try DatabaseQueue(path: path)
        try await source.write { db in
            try db.execute(sql: """
                CREATE TABLE MangaColumnModel (
                    Id INTEGER PRIMARY KEY, Title TEXT, Type TEXT, Artists TEXT,
                    Characters TEXT, Groups TEXT, Language TEXT, Series TEXT, Tags TEXT, Published TEXT
                );
                WITH RECURSIVE ids(value) AS (SELECT 1 UNION ALL SELECT value + 1 FROM ids WHERE value < 2005)
                INSERT INTO MangaColumnModel (Id, Title) SELECT value, 'Work ' || value FROM ids;
                """)
        }
        let task = Task.detached {
            try importer.importDataDb(path: path) { _ in
                // The first atomic batch completed; cancel before the next one.
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try database.catalogCount(), 1000)
    }

    func testBackgroundBackupExportPreservesLibraryFieldsAndSeparateOutputs() async throws {
        let database = try AppDatabase.inMemory()
        let folder = try database.createFolder(name: "Backup folder", color: 0xFF123456)
        _ = try database.upsertWork(galleryId: 1234, folderId: folder.id, title: "Backup title", artists: "Artist", tags: "tag:test")
        try database.setNote(galleryId: 1234, note: "My note")
        try database.setThumbPage(galleryId: 1234, page: 3)
        _ = try database.addFavoriteArtist(name: "Artist")
        let first = try await Task.detached { try MangaLibraryBackup.export(database: database) }.value
        let second = try await Task.detached { try MangaLibraryBackup.export(database: database) }.value
        defer { try? FileManager.default.removeItem(at: first); try? FileManager.default.removeItem(at: second) }
        XCTAssertNotEqual(first, second)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: first)) as? [String: Any])
        XCTAssertEqual(json["version"] as? Int, 2)
        let work = try XCTUnwrap((json["works"] as? [[String: Any]])?.first)
        XCTAssertEqual(work["gallery_id"] as? Int, 1234)
        XCTAssertEqual(work["title"] as? String, "Backup title")
        XCTAssertEqual(work["note"] as? String, "My note")
        XCTAssertEqual(work["tags"] as? String, "tag:test")
        XCTAssertEqual(work["thumb_page"] as? Int, 3)
        XCTAssertEqual(work["folders"] as? [String], ["Backup folder"])
        XCTAssertEqual((json["artists"] as? [[String: Any]])?.first?["name"] as? String, "Artist")
    }

    func testVioletUserDbImportRoutesToCorrectFolders() throws {
        let appDb = try AppDatabase.inMemory()
        let importer = VioletImportService(appDb: appDb)

        // Create temporary SQLite DB mimicking Violet user.db
        let tempDir = FileManager.default.temporaryDirectory
        let tempDbPath = tempDir.appendingPathComponent("test_violet_user_\(UUID().uuidString).db").path
        defer { try? FileManager.default.removeItem(atPath: tempDbPath) }

        let srcDb = try DatabaseQueue(path: tempDbPath)
        try srcDb.write { db in
            try db.execute(sql: """
            CREATE TABLE BookmarkGroup (
                Id INTEGER PRIMARY KEY,
                Name TEXT,
                DateTime TEXT,
                Description TEXT,
                Color INTEGER,
                Gorder INTEGER
            );
            CREATE TABLE BookmarkArticle (
                Id INTEGER PRIMARY KEY,
                Article TEXT,
                DateTime TEXT,
                GroupId INTEGER
            );
            """)

            try db.execute(sql: "INSERT INTO BookmarkGroup (Id, Name, Gorder) VALUES (1, 'violet_default', 1);")
            try db.execute(sql: "INSERT INTO BookmarkGroup (Id, Name, Gorder) VALUES (2, 'Toy', 2);")
            try db.execute(sql: "INSERT INTO BookmarkGroup (Id, Name, Gorder) VALUES (3, 'Omo', 3);")

            try db.execute(sql: "INSERT INTO BookmarkArticle (Id, Article, GroupId, DateTime) VALUES (1, '1001', 2, '2024-01-01');")
            try db.execute(sql: "INSERT INTO BookmarkArticle (Id, Article, GroupId, DateTime) VALUES (2, '1002', 3, '2024-01-02');")
        }

        let summary = try importer.importUserDb(path: tempDbPath)
        XCTAssertEqual(summary.folders, 3)
        XCTAssertEqual(summary.works, 2)

        let folders = try appDb.listFolders()
        let toyFolder = folders.first(where: { $0.name == "Toy" })
        let omoFolder = folders.first(where: { $0.name == "Omo" })
        let defaultFolder = folders.first(where: { $0.name == "미분류" })

        XCTAssertNotNil(toyFolder)
        XCTAssertNotNil(omoFolder)
        XCTAssertNotNil(defaultFolder)

        XCTAssertEqual(toyFolder?.workCount, 1, "Toy folder must have exactly 1 work")
        XCTAssertEqual(omoFolder?.workCount, 1, "Omo folder must have exactly 1 work")
        XCTAssertEqual(defaultFolder?.workCount, 0, "Default '미분류' folder must have 0 works since all works belong to other folders")

        let toyWorks = try appDb.listWorks(folderId: toyFolder?.id)
        XCTAssertEqual(toyWorks.map { $0.galleryId }, [1001])

        let omoWorks = try appDb.listWorks(folderId: omoFolder?.id)
        XCTAssertEqual(omoWorks.map { $0.galleryId }, [1002])

        let defaultWorks = try appDb.listWorks(folderId: defaultFolder?.id)
        XCTAssertTrue(defaultWorks.isEmpty, "Default folder should not contain works that belong to Toy or Omo")
    }
}
