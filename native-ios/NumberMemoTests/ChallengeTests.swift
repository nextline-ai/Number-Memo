import XCTest
import GRDB
@testable import NumberMemo

final class ChallengeTests: XCTestCase {
    @MainActor func testReferenceSearchStartsOnlyAfterReveal() throws {
        let controller = try ChallengeSessionController(game: .croquis())
        XCTAssertFalse(controller.session.canSearchImages)
        controller.draw()
        XCTAssertNotNil(controller.session.mission, "Draw is persisted before the animation")
        XCTAssertFalse(controller.session.canSearchImages, "Persisted tags must not trigger image requests while spinning")
        controller.stopReel(1); XCTAssertFalse(controller.session.canSearchImages)
        controller.stopReel(3); XCTAssertFalse(controller.session.canSearchImages)
        controller.reveal(); XCTAssertTrue(controller.session.canSearchImages)
        controller.skip(); XCTAssertFalse(controller.session.canSearchImages)
    }

    @MainActor func testInstructionsAndLegacySessionsCannotSpecifyRating() throws {
        var game = ChallengeDefinition.croquis()
        game.detail = "How to play\n1. Draw\n2. Complete"
        let restored = try ChallengeBackup.decode(ChallengeBackup(games: [game]).encoded()).games[0]
        XCTAssertEqual(restored.detail, game.detail)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(ChallengeSession(definition: restored))) as? [String: Any])
        legacy["rating"] = "explicit"
        let resumed = try JSONDecoder().decode(ChallengeSession.self, from: JSONSerialization.data(withJSONObject: legacy))
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(resumed)) as? [String: Any])
        XCTAssertNil(encoded["rating"])
        let controller = try ChallengeSessionController(game: restored)
        controller.draw(); controller.reveal()
        XCTAssertEqual(controller.session.mission?.tags.count, 1)
        XCTAssertFalse(controller.session.mission!.tags.contains { $0.contains(":") })
    }
    func testHelpTabsRoundTripAndLegacyCompatibility() throws {
        var definition = game()
        definition.helpPages = [.init(id: "rules", title: "Rules", body: "Draw and complete."), .init(id: "tips", title: "Tips", body: "Take your time.")]
        let restored = try ChallengeBackup.decode(ChallengeBackup(games: [definition]).encoded()).games[0]
        XCTAssertEqual(restored.instructionPages.map(\.id), ["overview", "rules", "tips"])
        XCTAssertEqual(restored, definition)
        definition.detail = ""
        XCTAssertEqual(definition.instructionPages.map(\.id), ["rules", "tips"])
        definition.helpPages = nil
        let legacy = try JSONEncoder().encode(definition)
        XCTAssertFalse(String(decoding: legacy, as: UTF8.self).contains("helpPages"))
        XCTAssertNil(try JSONDecoder().decode(ChallengeDefinition.self, from: legacy).helpPages)
        XCTAssertEqual(definition.instructionPages.count, 1)
        for pages in [
            [ChallengeHelpPage(id: "overview", title: "Reserved", body: "Text")],
            [.init(id: "one", title: "A", body: "Text"), .init(id: "one", title: "B", body: "Text")],
            [.init(title: "Blank", body: "  ")],
            [.init(title: "Too long", body: String(repeating: "x", count: 16001))]
        ] {
            definition.helpPages = pages
            XCTAssertThrowsError(try definition.validate())
        }
    }
    @MainActor func testExampleReusesEditedDefinitionAndProgressAndCanBeDeleted() throws {
        let store = ChallengeStore(try BooruStore())
        var first = try store.example()
        first.title = "My edited example"; try store.save(first)
        let controller = try ChallengeSessionController(game: first, store: store)
        controller.draw(); controller.reveal()
        for _ in 0..<5 { XCTAssertEqual(try store.example(), first) }
        XCTAssertEqual(try store.definitions().count, 1)
        XCTAssertEqual(try store.sessionIDs(), [first.id])
        XCTAssertEqual(try store.session(first).mission, controller.session.mission)
        try store.delete(first.id)
        XCTAssertTrue(try store.definitions().isEmpty); XCTAssertTrue(try store.sessionIDs().isEmpty)
        XCTAssertEqual(try store.example().id, first.id)
        XCTAssertNil(try store.session(first).mission)
    }
    @MainActor func testFolderFeedUsesEveryTagPaginationRatingAndBlocks() async throws {
        let store = try BooruStore(), server = BooruServer.presets[0]
        try store.saveServer(server)
        let folder = try store.saveFolder(name: "References")
        for id in 1...45 {
            try store.saveFavorite(BooruFixtureSource.post(Int64(id), server: server, tags: ["mountain", "middle", "scenery"]), folderID: folder)
        }
        try store.setBlacklist("id:1", serverID: server.id)
        let source = ChallengeFolderSource(store: store, folderID: folder, source: BooruFixtureSource())
        let first = try await source.posts(server: server, query: "scenery mountain rating:g", page: 0)
        let second = try await source.posts(server: server, query: "mountain scenery rating:g", page: 1)
        XCTAssertEqual(first.posts.count, 40); XCTAssertTrue(first.hasMore)
        XCTAssertEqual(second.posts.count, 4); XCTAssertFalse(second.hasMore)
        XCTAssertEqual(Set((first.posts + second.posts).map(\.id)).count, 44)
        XCTAssertFalse((first.posts + second.posts).contains { $0.postID == 1 })
        let excluded = try await source.posts(server: server, query: "scenery -mountain", page: 0)
        XCTAssertTrue(excluded.posts.isEmpty)
        let rating = try await source.posts(server: server, query: "rating:custom", page: 0)
        XCTAssertTrue(rating.posts.isEmpty)
    }
    private func game() -> ChallengeDefinition {
        var game = ChallengeDefinition.croquis()
        game.reels[0].options = [.init(text: "Subject", tags: ["scenery"])]
        game.reels[1].options = [.init(text: "Method")]
        game.goal.mode = .count; game.goal.count = .init(minimum: 1, maximum: 1)
        return game
    }
    private func ready(score: Int = 0, multiplier: Double = 1) -> ChallengeSession {
        var value = game(); value.multiplier = multiplier
        var session = ChallengeSession(definition: value); session.score = score
        try! ChallengeEngine(random: { $0.lowerBound }).draw(&session)
        session.phase = .ready; session.count = 1
        return session
    }
    func testOriginalScoreBoundariesAndRounding() {
        for (score, minimum, maximum) in [(0, 12, 20), (40, 12, 20), (41, 6, 11), (80, 6, 11), (81, 1, 5)] {
            var low = ready(score: score), high = low
            ChallengeEngine(random: { $0.lowerBound }).complete(&low, now: .now)
            ChallengeEngine(random: { $0.upperBound - 1 }).complete(&high, now: .now)
            XCTAssertEqual(low.score, score + minimum); XCTAssertEqual(high.score, score + maximum)
        }
        var session = ready(score: 81, multiplier: 0.5)
        ChallengeEngine(random: { $0.lowerBound }).complete(&session, now: .now)
        XCTAssertEqual(session.score, 82)
        session = ready(score: 0, multiplier: 1.5)
        ChallengeEngine(random: { $0.upperBound - 1 }).complete(&session, now: .now)
        XCTAssertEqual(session.score, 30)
    }
    func testEndingWeightsBoundariesAndNoDoubleAward() {
        for (ticket, expected) in [(0, 0), (9, 0), (10, 1), (54, 1), (55, 2), (99, 2)] {
            var value = ready(score: 99)
            ChallengeEngine(random: { $0.lowerBound == 0 && $0.upperBound == 100 ? ticket : $0.lowerBound }).complete(&value, now: .now)
            XCTAssertEqual(value.score, 100); XCTAssertEqual(value.phase, .ended)
            XCTAssertEqual(value.ending?.id, value.definition.endings[expected].id)
            let ended = value
            ChallengeEngine().complete(&value, now: .now)
            XCTAssertEqual(value, ended)
        }
        var fixed = ready(score: 99)
        fixed.definition.fixedEndingID = fixed.definition.endings[1].id
        ChallengeEngine(random: { $0.lowerBound }).complete(&fixed, now: .now)
        XCTAssertEqual(fixed.ending?.id, fixed.definition.fixedEndingID)
    }
    func testWeightedDrawGroupFiltersRangeAndLiteralSubstitution() throws {
        var definition = game()
        definition.reels[0].options = [.init(text: "Excluded", group: "other"), .init(text: "{reel2}", group: "chosen", weight: 10)]
        definition.reels[0].filter = "chosen"
        definition.groups = [.init(title: "Extra", options: [.init(text: "Kneeling")])]
        definition.template = "{reel1} / {reel2} / {extra1} / {goal}"
        definition.goal.mode = .mixed
        var session = ChallengeSession(definition: definition)
        try ChallengeEngine(random: { $0.lowerBound }).draw(&session)
        XCTAssertEqual(session.mission?.kind, .time); XCTAssertEqual(session.mission?.goal, 30)
        XCTAssertTrue(session.mission!.text.hasPrefix("{reel2} / Method / Kneeling /"))
        let spinning = session
        try ChallengeEngine().draw(&session)
        XCTAssertEqual(session, spinning)
        session = .init(definition: definition)
        try ChallengeEngine(random: { $0.upperBound - 1 }).draw(&session)
        XCTAssertEqual(session.mission?.kind, .count)
        definition.goal.mode = .time; session = .init(definition: definition)
        try ChallengeEngine(random: { $0.upperBound - 1 }).draw(&session)
        XCTAssertEqual(session.mission?.goal, 120)
    }
    func testValidationRejectsInvalidRulesAndExecutableVariables() throws {
        let original = game()
        let invalid: [(inout ChallengeDefinition) -> Void] = [
            { $0.reels.removeLast() }, { $0.reels[0].options.removeAll() },
            { $0.reels[0].options[0].enabled = false }, { $0.reels[0].filter = "missing" },
            { $0.reels[0].options[0].weight = 0 }, { $0.reels[0].options[0].tags = ["rating:explicit"] },
            { $0.goal.time.step = 0 }, { $0.goal.time.maximum = 119 },
            { $0.target = 1000 }, { $0.bands.reverse() }, { $0.bands[0].maximum = -1 },
            { $0.endings.removeAll() }, { $0.endings[0].weight = -1 }, { $0.fixedEndingID = "missing" },
            { $0.template = "{unknown}" }, { $0.template = "{reel1" }, { $0.template = "{{reel1}}" },
            { $0.multiplier = .infinity }, { $0.reels[0].options.append($0.reels[0].options[0]) }
        ]
        for mutate in invalid { var value = original; mutate(&value); XCTAssertThrowsError(try value.validate()) }
        XCTAssertNoThrow(try original.validate())
    }
    func testBackupRoundTripLimitsAndUnsupportedVersion() throws {
        let backup = ChallengeBackup(games: [game()])
        let data = try backup.encoded()
        XCTAssertEqual(try ChallengeBackup.decode(data).games, backup.games)
        let text = String(decoding: data, as: UTF8.self)
        for privateKey in ["deadline", "selectedPost", "serverIDs", "apiKey", "cookie", "revision"] { XCTAssertFalse(text.contains("\"" + privateKey + "\"")) }
        var future = backup; future.schemaVersion = 2
        XCTAssertThrowsError(try ChallengeBackup.decode(JSONEncoder().encode(future)))
        XCTAssertThrowsError(try ChallengeBackup.decode(Data(repeating: 32, count: ChallengeBackup.maximumBytes + 1)))
        XCTAssertThrowsError(try ChallengeBackup.decode(Data("{}".utf8)))
        XCTAssertThrowsError(try ChallengeBackup(games: [backup.games[0], backup.games[0]]).validate())
    }
    func testAtomicRestoreAndCollisionModes() throws {
        let store = ChallengeStore(try BooruStore()), original = game()
        try store.save(original)
        var edited = original; edited.title = "Edited"
        try store.restore(.init(games: [edited]), replace: false)
        XCTAssertEqual(try store.definitions().count, 2)
        XCTAssertEqual(try store.definitions().first { $0.id == original.id }?.title, original.title)
        try store.restore(.init(games: [edited]), replace: true)
        XCTAssertEqual(try store.definitions().first { $0.id == original.id }?.title, "Edited")
        var invalid = game(); invalid.title = ""
        let before = try store.definitions()
        XCTAssertThrowsError(try store.restore(.init(games: [game(), invalid]), replace: true))
        XCTAssertEqual(try store.definitions(), before)
    }
    @MainActor func testTimerPauseResetBackgroundAndSpinningRestore() throws {
        let store = ChallengeStore(try BooruStore())
        var definition = game(); definition.goal.mode = .time; definition.goal.time = .init(minimum: 10, maximum: 10)
        try store.save(definition)
        var clock = Date(timeIntervalSince1970: 1000)
        let controller = try ChallengeSessionController(game: definition, store: store, now: { clock })
        controller.draw()
        let mission = controller.session.mission
        let restored = try ChallengeSessionController(game: definition, store: store, now: { clock })
        XCTAssertEqual(restored.session.phase, .active); XCTAssertEqual(restored.session.mission, mission)
        restored.toggleTimer(); clock.addTimeInterval(3); restored.toggleTimer()
        XCTAssertEqual(restored.session.remaining, 7); XCTAssertNil(restored.session.deadline)
        clock.addTimeInterval(100)
        let paused = try ChallengeSessionController(game: definition, store: store, now: { clock })
        XCTAssertEqual(paused.session.remaining, 7)
        paused.toggleTimer(); clock.addTimeInterval(8)
        let expired = try ChallengeSessionController(game: definition, store: store, now: { clock })
        XCTAssertEqual(expired.session.phase, .ready); XCTAssertEqual(expired.session.remaining, 0)
        expired.resetTimer(); XCTAssertEqual(expired.session.phase, .active); XCTAssertEqual(expired.session.remaining, 10)
    }
    @MainActor func testCountClampingSkipAndPreviewIsolation() throws {
        let controller = try ChallengeSessionController(game: game())
        controller.draw(); controller.reveal()
        controller.adjust(-9); XCTAssertEqual(controller.session.count, 0)
        controller.complete(); XCTAssertEqual(controller.session.score, 0)
        controller.adjust(9); XCTAssertEqual(controller.session.count, 1); XCTAssertEqual(controller.session.phase, .ready)
        controller.adjust(-1); XCTAssertEqual(controller.session.phase, .active)
        controller.skip(); XCTAssertEqual(controller.session.score, 0); XCTAssertEqual(controller.session.phase, .idle)
        controller.draw(); controller.reveal(); controller.adjust(1); controller.complete()
        XCTAssertGreaterThan(controller.session.score, 0)
    }
    @MainActor func testConcurrentControllersCannotDoubleAwardAndEditsKeepSnapshot() throws {
        let store = ChallengeStore(try BooruStore()); let definition = game()
        try store.save(definition)
        let first = try ChallengeSessionController(game: definition, store: store)
        first.draw(); first.reveal(); first.adjust(1)
        let second = try ChallengeSessionController(game: definition, store: store)
        first.complete(); second.complete()
        XCTAssertNotNil(second.error); XCTAssertTrue(second.unavailable)
        let score = try store.session(definition).score
        XCTAssertEqual(score, first.session.score)
        var updated = definition; updated.title = "New Rules"; updated.multiplier = 2
        try store.save(updated)
        let restored = try ChallengeSessionController(game: updated, store: store)
        XCTAssertEqual(restored.session.definition, definition)
        restored.restart(); XCTAssertEqual(restored.session.definition, updated)
    }
    @MainActor func testSessionSurvivesDatabaseReopenAndDefinitionReplacement() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("test.sqlite").path
        let definition = game(); var mission: ChallengeMission?
        do {
            let store = ChallengeStore(try BooruStore(path: path)); try store.save(definition)
            let controller = try ChallengeSessionController(game: definition, store: store)
            controller.draw(); mission = controller.session.mission
        }
        let reopened = ChallengeStore(try BooruStore(path: path))
        let controller = try ChallengeSessionController(game: definition, store: reopened)
        XCTAssertEqual(controller.session.mission, mission); XCTAssertEqual(controller.session.phase, .active)
        try reopened.delete(definition.id)
        controller.adjust(1); XCTAssertNotNil(controller.error)
    }

    func testRestoringMaximumLengthTitleAsCopyRemainsValid() throws {
        let store = ChallengeStore(try BooruStore())
        var original = game(); original.title = String(repeating: "A", count: 200)
        try store.save(original)
        try store.restore(.init(games: [original]), replace: false)
        let copies = try store.definitions()
        XCTAssertEqual(copies.count, 2)
        for copy in copies { XCTAssertNoThrow(try copy.validate()) }
    }
    func testMediaFilteringRespectsTagsAndBlocks() {
        let post = BooruFixtureSource.post(101, server: BooruServer.presets[0])
        XCTAssertTrue(ChallengeMediaFilter.matches(post, tags: ["scenery"], blacklist: ""))
        for block in ["scenery", "id:101", "artist:sample_artist"] {
            XCTAssertFalse(ChallengeMediaFilter.matches(post, tags: [], blacklist: block))
        }
        XCTAssertFalse(ChallengeMediaFilter.matches(post, tags: ["missing"], blacklist: ""))
    }
    func testCloudDefinitionMergeDeletionAndSessionExclusion() throws {
        let suites = ["challenge-a-" + UUID().uuidString, "challenge-b-" + UUID().uuidString]
        defer { for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) } }
        func adapter(_ index: Int) throws -> LibrarySyncAdapter {
            let defaults = UserDefaults(suiteName: suites[index])!
            return .init(manga: try .inMemory(), booru: try BooruStore(), mangaDefaults: defaults, booruDefaults: defaults)
        }
        let a = try adapter(0), b = try adapter(1)
        let original = game(), sa = ChallengeStore(a.booru), sb = ChallengeStore(b.booru)
        try sa.save(original)
        var session = ChallengeSession(definition: original); session.serverIDs = ["private-server"]
        _ = try sa.commit(session, expected: 0)
        var la = LibrarySyncLedger(), lb = LibrarySyncLedger()
        la.capture(try a.snapshot(), device: "A", now: 10)
        XCTAssertFalse(la.changes.values.contains { $0.row.table.contains("session") })
        lb.merge(la.changes); try b.apply(lb.changes); lb.baseline = try b.snapshot()
        XCTAssertEqual(try sb.definitions(), [original]); XCTAssertFalse(sb.hasSession(original.id))
        var edited = original; edited.title = "B wins"
        try sb.save(edited); lb.capture(try b.snapshot(), device: "B", now: 20)
        la.merge(lb.changes); try a.apply(la.changes); la.baseline = try a.snapshot()
        XCTAssertEqual(try sa.definitions().first?.title, "B wins")
        XCTAssertEqual(try sa.session(original).definition.title, original.title)
        // Missing rows in an old peer's document are not tombstones.
        let challengeRow = try XCTUnwrap(la.changes.values.first { $0.row.table == "booru.challenges" }?.row)
        // An older binary does not know the new table's key columns. If downgraded on
        // the same device, its attempted tombstone has no key and must be ignored.
        let unknownKeyRow = LibrarySyncRow(table: "booru.challenges", values: [:])
        la.merge([challengeRow.key: .init(row: unknownKeyRow, timestamp: 99, device: "old", deleted: true)])
        XCTAssertFalse(la.changes[challengeRow.key]!.deleted)
        try sb.delete(original.id); lb.capture(try b.snapshot(), device: "B", now: 30)
        la.merge(lb.changes); try a.apply(la.changes)
        XCTAssertTrue(try sa.definitions().isEmpty); XCTAssertFalse(sa.hasSession(original.id))
        la.merge(lb.changes.filter { $0.value.timestamp < 20 })
        XCTAssertTrue(la.changes.values.first { $0.row.table == "booru.challenges" }!.deleted)
    }
    func testCloudTieBreakIsDeterministicAndInvalidDefinitionRollsBack() throws {
        let booru = try BooruStore(), store = ChallengeStore(booru), definition = game()
        let suite = "challenge-sync-" + UUID().uuidString
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let adapter = LibrarySyncAdapter(manga: try .inMemory(), booru: booru, mangaDefaults: UserDefaults(suiteName: suite)!, booruDefaults: UserDefaults(suiteName: suite)!)
        try store.save(definition)
        let row = try XCTUnwrap(adapter.snapshot().values.first { $0.table == "booru.challenges" })
        var ledger = LibrarySyncLedger()
        let a = LibrarySyncChange(row: row, timestamp: 10, device: "A", deleted: false)
        let b = LibrarySyncChange(row: row, timestamp: 10, device: "B", deleted: true)
        ledger.merge([row.key: b]); ledger.merge([row.key: a]); XCTAssertTrue(ledger.changes[row.key]!.deleted)
        var invalid = definition; invalid.reels.removeAll()
        let badRow = LibrarySyncRow(table: "booru.challenges", values: ["id": .text(definition.id), "payload": .blob(try JSONEncoder().encode(invalid))])
        XCTAssertThrowsError(try adapter.apply([badRow.key: .init(row: badRow, timestamp: 20, device: "C", deleted: false)]))
        XCTAssertEqual(try store.definitions(), [definition])
    }
}
