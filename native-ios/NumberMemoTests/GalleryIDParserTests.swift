import XCTest
import GRDB
@testable import NumberMemo

final class GalleryIDParserTests: XCTestCase {
    func testStandardHitomiUrl() {
        let url = "https://hitomi.la/galleries/1234567.html"
        let ids = GalleryIDParser.parse(url)
        XCTAssertEqual(ids, [1234567])
    }

    func testReaderUrl() {
        let url = "https://hitomi.la/reader/9876543.html#1"
        let ids = GalleryIDParser.parse(url)
        XCTAssertEqual(ids, [9876543])
    }

    func testTranslatedGoogleUrl() {
        let url = "https://hitomi-la.translate.goog/galleries/2345678.html?_x_tr_sl=auto&_x_tr_tl=ko"
        let ids = GalleryIDParser.parse(url)
        XCTAssertEqual(ids, [2345678])
    }

    func testNestedGoogleTranslateUrl() {
        let url = "https://translate.google.com/translate?u=https%3A%2F%2Fhitomi.la%2Fgalleries%2F3456789.html"
        let ids = GalleryIDParser.parse(url)
        XCTAssertEqual(ids, [3456789])
    }

    func testPlainNumberTokens() {
        let text = "품번 모음: 123456, 7891011; 4567890"
        let ids = GalleryIDParser.parse(text)
        XCTAssertEqual(ids, [123456, 7891011, 4567890])
    }

    func testHitomiUrlWithYearInTitle() {
        let text = "2024 Hitomi Comic https://hitomi.la/galleries/888888.html"
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
