import XCTest
@testable import NumberMemo

final class TasteFeedTests: XCTestCase {
    func testLegacyControlsReceiveModeDefaultsAndPersistUserRemovals() throws {
        let encoded = try JSONEncoder().encode(TasteControl())
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        json.removeValue(forKey: "analysisExclusions")
        var control = try JSONDecoder().decode(TasteControl.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(control.analysisExcluded(.booru), ["1girl", "1boy", "solo"])
        XCTAssertEqual(control.analysisExcluded(.comics), ["female:solo_female", "male:solo_male", "tag:digital", "tag:group"])
        control.setAnalysisExcluded([], mode: .booru)
        control.setAnalysisExcluded(["tag: digital", " FEMALE:solo female "], mode: .comics)
        let restored = try JSONDecoder().decode(TasteControl.self, from: JSONEncoder().encode(control))
        XCTAssertTrue(restored.analysisExcluded(.booru).isEmpty)
        XCTAssertEqual(restored.analysisExcluded(.comics), ["tag:digital", "female:solo_female"])
        control.timestamp = 100
        XCTAssertEqual(TasteControl().merged(with: control).analysisExcluded(.comics), restored.analysisExcluded(.comics))
    }
    func testExcludedTagsAreAbsentFromCurrentAndHistoricalEvidenceAndScores() {
        let item = TasteItem(source: "https://example.test", id: 1, tags: ["solo", "1girl", "blue_hair", "solo_artist"])
        let event = TasteEvent(kind: .save, item: item, context: .init(origin: .search, query: "solo blue_hair"))
        let period = DateInterval(start: .distantPast, end: .distantFuture)
        for range: DateInterval? in [nil, period] {
            let snapshot = TasteAnalyzer.analyze([event], control: .init(), period: range, previous: period)
            XCTAssertEqual(Set(snapshot.tags.map(\.name)), ["blue_hair", "solo_artist"])
            XCTAssertFalse(snapshot.previousTagCounts.keys.contains { $0.hasSuffix("\nsolo") })
            let tag = TasteTag(source: item.source, name: "blue_hair", confirmed: 1)
            var withoutIgnored = item; withoutIgnored.tags = ["blue_hair", "solo_artist"]
            XCTAssertEqual(RecommendationService.score(item, tags: [tag], ignoring: TasteControl().analysisExcluded(.booru)), RecommendationService.score(withoutIgnored, tags: [tag]))
        }
        let comic = TasteItem(source: "https://hitomi.la", id: 1, tags: ["female:solo_female", "male:solo_male", "tag:digital", "tag:group", "artist:group", "tag:watercolor"])
        let result = TasteAnalyzer.analyze([TasteEvent(kind: .seed, item: comic)], control: .init(), mode: .comics)
        XCTAssertEqual(Set(result.tags.map(\.name)), ["artist:group", "tag:watercolor"])
    }
    @MainActor func testPaginationDeduplicatesAndStopsRepeatedServerPages() async throws {
        let env = AppEnvironment.preview()
        let server = BooruServer.presets[0]
        try env.booru.saveServer(server); try env.booru.select(server)
        let source = PagedTasteSource()
        let tag = TasteTag(source: server.canonicalAddress, name: "scenery", general: 5)
        let snapshot = TasteSnapshot(tags: [tag], saves: 5, opens: 0, searches: 0, activity: [:], digest: "test", period: nil)
        let first = try await RecommendationService.load(mode: .booru, snapshot: snapshot, report: nil, env: env, language: "all", booruSource: source, useAIOrdering: false)
        let second = try await RecommendationService.load(mode: .booru, snapshot: snapshot, report: nil, env: env, language: "all", booruSource: source, useAIOrdering: false, cursor: first.cursor, excluding: Set(first.items.map(\.id)))
        XCTAssertEqual(first.items.map(\.item.id), [201, 202])
        XCTAssertEqual(second.items.map(\.item.id), [203])
        let third = try await RecommendationService.load(mode: .booru, snapshot: snapshot, report: nil, env: env, language: "all", booruSource: source, useAIOrdering: false, cursor: second.cursor, excluding: Set((first.items + second.items).map(\.id)))
        XCTAssertTrue(third.items.isEmpty); XCTAssertFalse(third.cursor.hasMore)
        let pages = await source.pages
        XCTAssertEqual(pages, [0, 1, 2])
    }
    @MainActor func testFeedOnlyReplacesOnExplicitRefreshAndKeepsSavedCard() async throws {
        let env = AppEnvironment.preview()
        let server = BooruServer.presets[0]
        try env.booru.saveServer(server); try env.booru.select(server)
        env.taste.change { $0.aiEnabled = false }
        try env.booru.toggleFavorite(BooruFixtureSource.post(101, server: server, tags: ["scenery"]), context: .init(origin: .search, query: "scenery"))
        let source = PagedTasteSource()
        let feed = TasteFeedState(booruSource: source)
        feed.ensureLoaded(mode: .booru, env: env, language: "all"); await feed.waitForRefresh()
        let original = feed.results.items.map(\.id)
        XCTAssertEqual(original.count, 2)
        let post = try XCTUnwrap(feed.results.items.first?.post)
        try env.booru.toggleFavorite(post, context: .init(origin: .recommendation))
        env.taste.change { $0.cloudEnabled = false }
        for _ in 0..<3 { feed.ensureLoaded(mode: .booru, env: env, language: "all") }
        await feed.waitForRefresh()
        XCTAssertEqual(feed.results.items.map(\.id), original)
        let count = await source.pages.count; XCTAssertEqual(count, 1)
        await feed.loadMore(mode: .booru, env: env, language: "all")
        XCTAssertEqual(Array(feed.results.items.prefix(2).map(\.id)), original)
        XCTAssertEqual(feed.results.items.last?.item.id, 203)
        feed.refresh(mode: .booru, env: env, language: "all"); await feed.waitForRefresh()
        XCTAssertFalse(feed.results.items.contains { $0.id == original[0] })
        XCTAssertTrue(env.taste.comicFeed.results.items.isEmpty)
        feed.clear(); XCTAssertTrue(feed.results.items.isEmpty)
    }
    func testExclusionsMatchWhitespaceWithoutRemovingOtherNamespaces() {
        let control = TasteControl()
        for tag in ["female:solo female", "female:solo_female", " FEMALE : solo\u{00a0}female ", "female:solo__female", "female:solo\tfemale"] {
            XCTAssertFalse(control.allows(tag, source: "https://hitomi.la", mode: .comics), tag)
        }
        for tag in ["artist:solo_female", "female:solo_female_artist", "tag:watercolor"] {
            XCTAssertTrue(control.allows(tag, source: "https://hitomi.la", mode: .comics), tag)
        }
    }
    func testDeliberateRecommendationSaveAndUndoPreserveEvidenceWithoutFakeSearch() {
        let item = TasteItem(source: "https://example.test", id: 1, tags: ["blue_hair", "green_eyes"])
        var save = TasteEvent(kind: .save, item: item, context: .recommended("blue_hair", session: "one")); save.at = 1
        var remove = TasteEvent(kind: .remove, item: item); remove.at = 2
        var again = save; again.id = UUID().uuidString; again.at = 3
        let snapshot = TasteAnalyzer.analyze([save, again], control: .init())
        XCTAssertEqual(snapshot.tags.first { $0.name == "blue_hair" }?.confirmed, 1)
        XCTAssertEqual(snapshot.tags.first { $0.name == "green_eyes" }?.hidden, 1)
        XCTAssertEqual(snapshot.searches, 0)
        XCTAssertTrue(TasteAnalyzer.analyze([save, remove], control: .init()).tags.isEmpty)
        XCTAssertEqual(TasteAnalyzer.analyze([save, remove, again], control: .init()).saves, 1)
    }
    func testGenerationBudgetSpacesCallsAndPreventsConcurrentWork() {
        var policy = InsightGenerationPolicy()
        XCTAssertFalse(policy.begin(now: 1, foreground: false, lowPower: false))
        XCTAssertFalse(policy.begin(now: 1, foreground: true, lowPower: true))
        XCTAssertTrue(policy.begin(now: 1, foreground: true, lowPower: false))
        XCTAssertFalse(policy.begin(now: 301, foreground: true, lowPower: false))
        policy.finish()
        XCTAssertFalse(policy.begin(now: 300, foreground: true, lowPower: false))
        XCTAssertTrue(policy.begin(now: 301, foreground: true, lowPower: false))
    }
    @MainActor func testManualRefreshDealsUnseenWorksBeforeRepeating() async throws {
        let env = AppEnvironment.preview(), server = BooruServer.presets[0]
        try env.booru.saveServer(server); try env.booru.select(server)
        env.taste.change { $0.aiEnabled = false }
        try env.booru.toggleFavorite(BooruFixtureSource.post(101, server: server, tags: ["scenery"]), context: .init(origin: .search, query: "scenery"))
        let feed = TasteFeedState(booruSource: PagedTasteSource())
        feed.ensureLoaded(mode: .booru, env: env, language: "all"); await feed.waitForRefresh()
        XCTAssertEqual(Set(feed.results.items.map(\.item.id)), [201, 202])
        feed.refresh(mode: .booru, env: env, language: "all"); await feed.waitForRefresh()
        XCTAssertEqual(feed.results.items.map(\.item.id), [203])
        feed.refresh(mode: .booru, env: env, language: "all"); await feed.waitForRefresh()
        XCTAssertEqual(Set(feed.results.items.map(\.item.id)), [201, 202])
    }
    func testStatisticsCanRotateWithoutInventingEvidence() async {
        let tags = (0..<8).map { TasteTag(source: "https://example.test", name: "tag\($0)", general: 10 - $0) }
        let snapshot = TasteSnapshot(tags: tags, saves: 10, opens: 0, searches: 0, activity: [:], digest: "rotation", period: nil)
        var control = TasteControl(); control.aiEnabled = false
        let first = await OnDeviceInsightService.report(snapshot: snapshot, control: control, language: "en")
        let next = await OnDeviceInsightService.report(snapshot: snapshot, control: control, language: "en", selectionOffset: 3)
        XCTAssertTrue(first.isValid(for: snapshot)); XCTAssertTrue(next.isValid(for: snapshot))
        XCTAssertTrue(Set(first.insights.map(\.tagKey)).isDisjoint(with: next.insights.map(\.tagKey)))
        XCTAssertFalse(next.generatedByAI)
    }
    @MainActor func testRecapDismissalIsPersistedAndScopedToMonth() throws {
        let env = AppEnvironment.preview(), date = Date(timeIntervalSince1970: 1_700_000_000)
        env.taste.monthlyRecaps[.booru] = date
        XCTAssertEqual(env.taste.pendingRecap(.booru), date)
        env.taste.dismissRecap(.booru)
        XCTAssertNil(env.taste.pendingRecap(.booru))
        let saved = try env.taste.store(.booru).metadata(String.self, key: "dismissedRecap")
        XCTAssertEqual(saved, env.taste.recapKey(date))
        env.taste.monthlyRecaps[.booru] = date.addingTimeInterval(32 * 86400)
        XCTAssertNotNil(env.taste.pendingRecap(.booru))
        env.taste.reset(); XCTAssertNil(env.taste.pendingRecap(.booru))
    }
}

private actor PagedTasteSource: BooruProviding {
    var pages: [Int] = []
    func posts(server: BooruServer, query: String, page: Int) async throws -> BooruBatch {
        pages.append(page)
        return .init(posts: (page == 0 ? [201, 202] : [202, 203]).map { BooruFixtureSource.post(Int64($0), server: server, tags: ["scenery"]) }, hasMore: true)
    }
    func suggestions(server: BooruServer, token: String) async throws -> [BooruTag] { [] }
    func pools(server: BooruServer, query: String, page: Int) async throws -> [BooruPool] { [] }
    func poolPosts(server: BooruServer, poolID: Int64, page: Int) async throws -> BooruBatch { .init(posts: [], hasMore: false) }
    func notes(server: BooruServer, postID: Int64) async throws -> [BooruNote] { [] }
}
