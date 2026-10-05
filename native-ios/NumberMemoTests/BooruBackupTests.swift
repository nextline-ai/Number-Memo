import XCTest
import GRDB
@testable import NumberMemo

final class BooruBackupTests: XCTestCase {
    func testAutomaticColorsUseComicsPaletteAndFallbackWithoutChangingRenames() throws {
        let comics = try AppDatabase.inMemory(), images = try BooruStore()
        let initial = try XCTUnwrap(comics.listFolders().first?.color)
        try images.setFolderColor("unsorted", color: initial)
        for index in 0..<(AppDatabase.presetColors.count + 3) {
            let comic = try comics.createFolder(name: "Folder \(index)")
            let id = try images.saveFolder(name: "Folder \(index)")
            XCTAssertEqual(images.folders().first { $0.id == id }?.color, comic.color)
            try images.saveFolder(id: id, name: "Renamed \(index)")
            XCTAssertEqual(images.folders().first { $0.id == id }?.color, comic.color)
        }
    }

    func testBackupRoundTripMergesCanonicalServersAndPreservesFoldersAndSearches() throws {
        let source = try BooruStore(), destination = try BooruStore()
        let server = BooruServer.presets[0]
        try source.saveServer(server)
        let a = try source.saveFolder(name: "Landscapes"), b = try source.saveFolder(name: "Rooms")
        try source.setFolderColor(a, color: 0xFF112233)
        try source.setFolderColor("unsorted", color: 0xFF334455)
        try source.reorderFolders([b, "unsorted", a])
        let post = BooruFixtureSource.post(5194309, server: server)
        try source.saveFavorite(post, folderID: a)
        try source.recordSearch("scenery sky", serverID: server.id)
        for kind in ["tag", "artist", "search"] { try source.toggleTag("scenery sky", serverID: server.id, kind: kind) }
        try source.setBlacklist("gore", serverID: server.id)
        var local = server; local.id = "already-configured"
        try destination.saveServer(local)
        let extra = try destination.saveFolder(name: "Keep me")
        let backup = try BooruBackup.decode(source.exportBackup().encoded())
        try destination.restoreBackup(backup)
        try destination.restoreBackup(backup)
        XCTAssertEqual(destination.servers.map(\.id), [local.id])
        XCTAssertEqual(destination.folders().map(\.id), [b, "unsorted", a, extra])
        XCTAssertEqual(destination.folders().first { $0.id == a }?.color, 0xFF112233)
        XCTAssertEqual(destination.folders().first { $0.id == "unsorted" }?.color, 0xFF334455)
        let mapped = post.onServer(local.id)
        XCTAssertEqual(destination.favoriteIDs, [mapped.id])
        XCTAssertEqual(destination.folderID(for: mapped), a)
        XCTAssertEqual(destination.savedDate(for: mapped), source.savedDate(for: post))
        XCTAssertEqual(destination.history(serverID: local.id), ["scenery sky"])
        XCTAssertEqual(destination.savedTags(serverID: local.id, kind: "search"), ["scenery sky"])
        XCTAssertEqual(destination.blacklist(serverID: local.id), "gore")
        XCTAssertEqual(destination.selectedServerIDs, [local.id])
    }

    func testInvalidBackupCannotPartiallyChangeLibrary() throws {
        let source = try BooruStore(), destination = try BooruStore()
        let server = BooruServer.presets[0]
        try source.saveServer(server)
        try source.saveFavorite(BooruFixtureSource.post(12, server: server))
        var backup = try source.exportBackup()
        backup.favorites[0].folderID = "missing"
        XCTAssertThrowsError(try destination.restoreBackup(backup))
        XCTAssertTrue(destination.servers.isEmpty)
        XCTAssertEqual(destination.folders().map(\.id), ["unsorted"])
        backup = try source.exportBackup(); backup.version = 999
        XCTAssertThrowsError(try destination.restoreBackup(backup))
        XCTAssertThrowsError(try BooruBackup.decode(Data("{\"version\":2,\"works\":[]}".utf8)))
    }

    func testRestoredFolderColorsAndOrderReachAnotherSyncLibrary() throws {
        let source = try BooruStore()
        let id = try source.saveFolder(name: "Synced folder")
        try source.setFolderColor(id, color: 0xFFABCDEF)
        try source.setFolderColor("unsorted", color: 0xFF102030)
        try source.reorderFolders([id, "unsorted"])
        let restored = try BooruStore()
        try restored.restoreBackup(BooruBackup.decode(source.exportBackup().encoded()))
        let name = "backup-sync-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let a = LibrarySyncAdapter(hitomi: try .inMemory(), booru: restored, hitomiDefaults: defaults, booruDefaults: defaults)
        let b = LibrarySyncAdapter(hitomi: try .inMemory(), booru: try BooruStore(), hitomiDefaults: defaults, booruDefaults: defaults)
        var ledger = LibrarySyncLedger()
        ledger.capture(try a.snapshot(), device: "A")
        try b.apply(ledger.changes)
        XCTAssertEqual(b.booru.folders().map(\.id), [id, "unsorted"])
        XCTAssertEqual(b.booru.folders().map(\.color), [0xFFABCDEF, 0xFF102030])
        try restored.setFolderColor(id, color: 0xFF765432)
        ledger.capture(try a.snapshot(), device: "A")
        try b.apply(ledger.changes)
        XCTAssertEqual(b.booru.folders().first?.color, 0xFF765432)
    }
}
