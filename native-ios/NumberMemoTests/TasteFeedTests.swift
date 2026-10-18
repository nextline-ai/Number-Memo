import XCTest
@testable import NumberMemo

final class TasteFeedTests: XCTestCase {
    @MainActor func testGoldOnlyRecommendationPagesAdvanceAndRepeatedRestrictedPagesStop() async throws {
        for repeatsRestrictedPage in [false, true] {
            let env = AppEnvironment.preview(), server = BooruServer.presets[0]
            try env.booru.saveServer(server); try env.booru.select(server)
            let source = GoldRestrictedTasteSource(repeatsRestrictedPage: repeatsRestrictedPage)
            let snapshot = TasteSnapshot(tags: [TasteTag(source: server.canonicalAddress, name: "scenery", general: 5)], saves: 5, opens: 0, searches: 0, activity: [:], digest: "gold", period: nil)
            let first = try await RecommendationService.load(mode: .booru, snapshot: snapshot, report: nil, env: env, language: "all", booruSource: source)
            XCTAssertTrue(first.items.isEmpty); XCTAssertTrue(first.failures.isEmpty)
            XCTAssertTrue(first.cursor.hasMore, "A page with only restricted rows still advances the source cursor")
            XCTAssertEqual(env.booru.confirmedGoldRestrictedIDs, [server.id + ":201"])
            let second = try await RecommendationService.load(mode: .booru, snapshot: snapshot, report: nil, env: env, language: "all", booruSource: source, cursor: first.cursor)
            XCTAssertEqual(second.items.map(\.item.id), repeatsRestrictedPage ? [] : [203])
            XCTAssertTrue(second.failures.isEmpty); XCTAssertFalse(second.cursor.hasMore)
            let pages = await source.pages
            XCTAssertEqual(pages, [0, 1])
        }
    }

    @MainActor func testGoldRestrictionsAlsoFilterPendingRecommendationCandidates() async throws {
        let env = AppEnvironment.preview(), server = BooruServer.presets[0]
        try env.booru.saveServer(server); try env.booru.select(server)
        let source = GoldRestrictedTasteSource()
        let snapshot = TasteSnapshot(tags: [TasteTag(source: server.canonicalAddress, name: "scenery", general: 5)], saves: 5, opens: 0, searches: 0, activity: [:], digest: "gold", period: nil)
        let first = try await RecommendationService.load(mode: .booru, snapshot: snapshot, report: nil, env: env, language: "all", booruSource: source)
        let key = try XCTUnwrap(first.cursor.pages.keys.first)
        var cursor = first.cursor
        cursor.pendingPosts[key] = [201, 204].map { BooruFixtureSource.post(Int64($0), server: server, tags: ["scenery"]) }
        cursor.finished.insert(key)
        let second = try await RecommendationService.load(mode: .booru, snapshot: snapshot, report: nil, env: env, language: "all", booruSource: source, cursor: cursor)
        XCTAssertEqual(second.items.map(\.item.id), [204])
        XCTAssertTrue(second.failures.isEmpty); XCTAssertFalse(second.cursor.hasMore)
        let pages = await source.pages
        XCTAssertEqual(pages, [0], "Filtering a resumed candidate must not restart its source page")
    }

    @MainActor func testGoldRestrictionProjectsExistingRecommendationDeckWithoutResettingIt() async throws {
        let env = AppEnvironment.preview(), server = BooruServer.presets[0]
        try env.booru.saveServer(server); try env.booru.select(server)
        try env.booru.toggleFavorite(BooruFixtureSource.post(101, server: server, tags: ["scenery"]))
        let feed = TasteFeedState(booruSource: PagedTasteSource())
        feed.ensureLoaded(mode: .booru, env: env, language: "all"); await feed.waitForRefresh()
        let original = feed.results.items.map(\.id), cursor = feed.results.cursor.pages, session = feed.discoverySession
        let post = try XCTUnwrap(feed.results.items.first?.post)
        env.booru.recordGoldRestriction(post)
        XCTAssertEqual(feed.visibleItems(in: env.booru).map(\.id), Array(original.dropFirst()))
        XCTAssertEqual(feed.results.items.map(\.id), original)
        XCTAssertEqual(feed.results.cursor.pages, cursor); XCTAssertEqual(feed.discoverySession, session)
        env.booru.clearGoldRestrictions(serverID: server.id)
        XCTAssertEqual(feed.visibleItems(in: env.booru).map(\.id), original)
    }

    func testPreparedRecommendationMixPreservesRankingAndTieOrder() {
        var candidates: [TasteRecommendation] = (0..<90).map { index in
            let source = "https://site\(index % 3).example"
            let item = TasteItem(source: source, id: Int64(index), tags: ["theme_\(index % 7)", "theme_\(index % 11)", "common", "png"])
            let reason = TasteTag(source: source, name: "reason", hidden: index.isMultiple(of: 3) ? 5 : 0,
                                  general: 5, sessions: ["a", "b", "c"])
            return TasteRecommendation(item: item, post: nil, gallery: nil, reason: reason,
                score: Double(index % 5) / 10, rankingTags: index.isMultiple(of: 2) ? ["theme_\(index % 7)"] : nil)
        }
        candidates += Array(candidates.prefix(8))
        for limit in [0, 1, 20, 100] {
            XCTAssertEqual(RecommendationService.mix(candidates, limit: limit).map(\.id), originalRecommendationMix(candidates, limit: limit).map(\.id))
        }
        XCTAssertTrue(RecommendationService.mix([], limit: 20).isEmpty)
    }

    private func originalRecommendationMix(_ candidates: [TasteRecommendation], limit: Int) -> [TasteRecommendation] {
        let sorted = candidates.sorted { $0.score == $1.score ? $0.id < $1.id : $0.score > $1.score }
        var seen = Set<String>()
        let unique = sorted.filter { seen.insert($0.id).inserted }
        var remaining = unique, result: [TasteRecommendation] = []
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
                return 0.8 * candidate.score / maximum - 0.2 * overlap
            }
            guard let next = pool.max(by: { utility($0) < utility($1) }) else { break }
            result.append(next); remaining.removeAll { $0.id == next.id }
        }
        return result
    }

    @MainActor func testComicRecommendationsBatchSavedChecksAndRecheckAfterMetadata() async throws {
        let env = AppEnvironment.preview(); env.isSiteVerified = true
        _ = try env.database.upsertWork(galleryId: 1)
        let source = SavingComicTasteSource(database: env.database)
        let tag = TasteTag(source: "https://manga.la", name: "tag:scenery", general: 5)
        let snapshot = TasteSnapshot(tags: [tag], saves: 5, opens: 0, searches: 0, activity: [:], digest: "saved-checks", period: nil)
        let result = try await RecommendationService.load(mode: .comics, snapshot: snapshot, report: nil, env: env, language: "all", comicSource: source)
        let requested = await source.requested
        XCTAssertEqual(Set(requested), Set((2...8).map(Int64.init)), "Already saved works need no metadata request")
        XCTAssertEqual(Set(result.items.map(\.item.id)), Set([2, 4, 5, 6, 7, 8].map(Int64.init)), "Works saved during metadata loading remain excluded")
        XCTAssertFalse(result.cursor.hasMore)
    }

    func testPrecomputedRecommendationScoresExactlyMatchTheOriginalFormula() {
        let sources = ["https://one.example", "https://two.example", "https://manga.la"]
        var tags: [TasteTag] = []
        for (sourceIndex, source) in sources.enumerated() {
            for index in 0..<18 {
                tags.append(TasteTag(source: source, name: "theme_\(index)", confirmed: index % 4, hidden: index % 7, general: index % 3,
                    works: (0..<(index % 9)).map { TasteItem(source: source, id: Int64($0 + sourceIndex), tags: ["theme_\(index)"]) },
                    lift: index.isMultiple(of: 2) ? Double(index + 1) / 4 : nil))
            }
        }
        // Duplicate names and zero-evidence/search-only tags must retain their
        // old sum and denominator behavior as well.
        tags.append(tags[5])
        tags.append(TasteTag(source: sources[0], name: "search_only", searches: 5))
        for source in sources {
            let profile = RecommendationService.ScoringProfile(source: source, tags: tags)
            for index in 0..<30 {
                let item = TasteItem(source: source, id: Int64(index), tags: ["theme_\(index % 18)", "theme_\((index + 3) % 18)", "unknown", "search_only", "png"])
                let exclusions: [Set<String>] = [[], ["theme_5"], Set(item.tags)]
                for ignored in exclusions {
                    XCTAssertEqual(profile.score(item, ignoring: ignored), originalRecommendationScore(item, tags: tags, ignoring: ignored))
                }
            }
        }
    }

    func testRecommendationScoreProfilesHandleEmptyAndUnrelatedSources() {
        let source = "https://one.example"
        let item = TasteItem(source: source, id: 1, tags: [])
        XCTAssertEqual(RecommendationService.ScoringProfile(source: source, tags: []).score(item), 0)
        let tag = TasteTag(source: source, name: "scenery", general: 5)
        let profile = RecommendationService.ScoringProfile(source: source, tags: [tag])
        XCTAssertEqual(profile.score(TasteItem(source: "https://two.example", id: 1, tags: ["scenery"])), 0)
        XCTAssertEqual(profile.score(TasteItem(source: source, id: 2, tags: ["png"])), 0)
        XCTAssertEqual(profile.score(TasteItem(source: source, id: 3, tags: ["scenery"]), ignoring: ["scenery"]), 0)
    }

    /// Reference behavior before per-source precomputation; exact equality also
    /// protects recommendation ordering when candidates have near-equal scores.
    private func originalRecommendationScore(_ item: TasteItem, tags: [TasteTag], ignoring: Set<String>) -> Double {
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

    func testLegacyControlsReceiveModeDefaultsAndPersistUserRemovals() throws {
        let encoded = try JSONEncoder().encode(TasteControl())
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        json.removeValue(forKey: "analysisExclusions")
        var control = try JSONDecoder().decode(TasteControl.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(control.analysisExcluded(.booru), ["1girl", "1boy", "solo"])
        XCTAssertEqual(control.analysisExcluded(.comics), ["female:sole_female", "male:sole_male", "tag:digital", "tag:group"])
        control.setAnalysisExcluded([], mode: .booru)
        control.setAnalysisExcluded(["tag: digital", " FEMALE:solo female "], mode: .comics)
        let restored = try JSONDecoder().decode(TasteControl.self, from: JSONEncoder().encode(control))
        XCTAssertTrue(restored.analysisExcluded(.booru).isEmpty)
        XCTAssertEqual(restored.analysisExcluded(.comics), ["tag:digital", "female:sole_female"])
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
        let comic = TasteItem(source: "https://manga.la", id: 1, tags: ["female:solo_female", "male:solo_male", "tag:digital", "tag:group", "artist:group", "tag:watercolor"])
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
        let first = try await RecommendationService.load(mode: .booru, snapshot: snapshot, report: nil, env: env, language: "all", booruSource: source)
        let second = try await RecommendationService.load(mode: .booru, snapshot: snapshot, report: nil, env: env, language: "all", booruSource: source, cursor: first.cursor, excluding: Set(first.items.map(\.id)))
        XCTAssertEqual(first.items.map(\.item.id), [201, 202])
        XCTAssertEqual(second.items.map(\.item.id), [203])
        let third = try await RecommendationService.load(mode: .booru, snapshot: snapshot, report: nil, env: env, language: "all", booruSource: source, cursor: second.cursor, excluding: Set((first.items + second.items).map(\.id)))
        XCTAssertTrue(third.items.isEmpty); XCTAssertFalse(third.cursor.hasMore)
        let pages = await source.pages
        XCTAssertEqual(pages, [0, 1, 2])
    }
    @MainActor func testFeedOnlyReplacesOnExplicitRefreshAndKeepsSavedCard() async throws {
        let env = AppEnvironment.preview()
        let server = BooruServer.presets[0]
        try env.booru.saveServer(server); try env.booru.select(server)
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
    @MainActor func testSuspendingRecommendationsCancelsPaginationAndKeepsCursorRetryable() async throws {
        let env = AppEnvironment.preview(), server = BooruServer.presets[0]
        try env.booru.saveServer(server); try env.booru.select(server)
        try env.booru.toggleFavorite(BooruFixtureSource.post(101, server: server, tags: ["scenery"]), context: .init(origin: .search, query: "scenery"))
        let source = CancellableTasteSource(), feed = TasteFeedState(booruSource: source)
        feed.ensureLoaded(mode: .booru, env: env, language: "all"); await feed.waitForRefresh()
        let original = feed.results.items.map(\.id), cursor = feed.results.cursor.pages
        let pagination = Task { await feed.loadMore(mode: .booru, env: env, language: "all") }
        await source.waitForPagination()
        feed.cancelLoading()
        await pagination.value
        XCTAssertFalse(feed.loadingMore)
        XCTAssertEqual(feed.results.items.map(\.id), original)
        XCTAssertEqual(feed.results.cursor.pages, cursor)
        await source.allowPagination()
        await feed.loadMore(mode: .booru, env: env, language: "all")
        XCTAssertEqual(feed.results.items.last?.item.id, 203)
        let pages = await source.pages
        XCTAssertEqual(pages, [0, 1, 1], "Returning to the feed must retry the interrupted page")
    }
    @MainActor func testRecommendationsKeepServerProfilesSeparateAndHydratePublicPages() async throws {
        let env = AppEnvironment.preview()
        let servers = BooruEngine.allCases.map { BooruServer(id: $0.rawValue, name: $0.rawValue, baseURL: URL(string: "https://" + $0.rawValue.lowercased() + ".test")!, engine: $0) }
        for server in servers { try env.booru.saveServer(server) }
        try env.booru.setSelectedServers(servers.map(\.id))
        let tags = servers.map { TasteTag(source: $0.canonicalAddress, name: "taste_" + $0.id.lowercased(), general: 5) }
        let snapshot = TasteSnapshot(tags: tags, saves: 5, opens: 0, searches: 0, activity: [:], digest: "servers", period: nil)
        let source = ServerTasteSource()
        let result = try await RecommendationService.load(mode: .booru, snapshot: snapshot, report: nil, env: env, language: "all", booruSource: source)
        XCTAssertEqual(Set(result.items.map(\.item.source)), Set(servers.map(\.canonicalAddress)))
        XCTAssertEqual(result.cursor.pages.count, 4)
        XCTAssertTrue(result.items.allSatisfy { $0.item.tags.contains($0.reason.name) && $0.item.source == $0.reason.source })
        let requests = await source.queries
        for server in servers { XCTAssertTrue(requests[server.id]?.contains("taste_" + server.id.lowercased()) == true) }
        XCTAssertTrue(result.failures.isEmpty)
    }
    @MainActor func testHTMLRecommendationsRotateBothAvailablePreferenceSeeds() async throws {
        let env = AppEnvironment.preview(), server = BooruServer.presets[1]
        try env.booru.saveServer(server); try env.booru.select(server)
        let snapshot = TasteSnapshot(tags: [TasteTag(source: server.canonicalAddress, name: "first", general: 5), TasteTag(source: server.canonicalAddress, name: "second", general: 4)], saves: 9, opens: 0, searches: 0, activity: [:], digest: "rotation", period: nil)
        let source = ServerTasteSource()
        _ = try await RecommendationService.load(mode: .booru, snapshot: snapshot, report: nil, env: env, language: "all", booruSource: source, seedOffset: 0)
        let first = await source.queries[server.id]
        _ = try await RecommendationService.load(mode: .booru, snapshot: snapshot, report: nil, env: env, language: "all", booruSource: source, seedOffset: 1)
        let second = await source.queries[server.id]
        XCTAssertNotNil(first); XCTAssertNotNil(second); XCTAssertNotEqual(first, second)
    }
    @MainActor func testSlowServerCannotHoldSuccessfulRecommendationsOrCommitLateResults() async throws {
        let env = AppEnvironment.preview()
        let servers = [BooruServer.presets[0], BooruServer.presets[1]]
        for server in servers { try env.booru.saveServer(server) }
        try env.booru.setSelectedServers(servers.map(\.id))
        let snapshot = TasteSnapshot(tags: servers.map { TasteTag(source: $0.canonicalAddress, name: "taste_" + $0.id.lowercased(), general: 5) }, saves: 5, opens: 0, searches: 0, activity: [:], digest: "timeout", period: nil)
        let source = ServerTasteSource(slowID: servers[1].id)
        let clock = ContinuousClock(), start = clock.now
        let result = try await RecommendationService.load(mode: .booru, snapshot: snapshot, report: nil, env: env, language: "all", booruSource: source, requestTimeout: 0.1)
        XCTAssertLessThan(start.duration(to: clock.now), .seconds(1))
        XCTAssertEqual(result.items.map(\.item.source), [servers[0].canonicalAddress])
        XCTAssertEqual(result.failures, [servers[1].displayName])
        XCTAssertFalse(result.cursor.pages.keys.contains { $0.hasPrefix(servers[1].id + "|") })
    }
    @MainActor func testHTMLLastPageResumesUnresolvedCandidatesWithoutRefetching() async throws {
        let env = AppEnvironment.preview()
        let server = BooruServer(id: "legacy", name: "Legacy", baseURL: URL(string: "https://legacy.booru.org")!, engine: .oldGelbooru)
        try env.booru.saveServer(server); try env.booru.select(server)
        let snapshot = TasteSnapshot(tags: [TasteTag(source: server.canonicalAddress, name: "scenery", general: 5)], saves: 5, opens: 0, searches: 0, activity: [:], digest: "legacy", period: nil)
        let source = LegacyDetailTasteSource()
        let first = try await RecommendationService.load(mode: .booru, snapshot: snapshot, report: nil, env: env, language: "all", booruSource: source)
        XCTAssertEqual(first.items.count, 4)
        XCTAssertTrue(first.cursor.hasMore)
        let second = try await RecommendationService.load(mode: .booru, snapshot: snapshot, report: nil, env: env, language: "all", booruSource: source, cursor: first.cursor, excluding: Set(first.items.map(\.id)))
        XCTAssertEqual(second.items.count, 3)
        XCTAssertFalse(second.cursor.hasMore)
        XCTAssertEqual(Set((first.items + second.items).map(\.item.id)).count, 7)
        let listings = await source.listings
        XCTAssertEqual(listings, 1)
    }
    @MainActor func testSlowHTMLDetailPreservesReadyCandidatesAndPagination() async throws {
        let env = AppEnvironment.preview()
        let server = BooruServer(id: "legacy", name: "Legacy", baseURL: URL(string: "https://legacy.booru.org")!, engine: .oldGelbooru)
        try env.booru.saveServer(server); try env.booru.select(server)
        let snapshot = TasteSnapshot(tags: [TasteTag(source: server.canonicalAddress, name: "scenery", general: 5)], saves: 5, opens: 0, searches: 0, activity: [:], digest: "legacy", period: nil)
        let source = LegacyDetailTasteSource(slowDetail: true)
        let result = try await RecommendationService.load(mode: .booru, snapshot: snapshot, report: nil, env: env, language: "all", booruSource: source, requestTimeout: 0.1)
        XCTAssertEqual(result.items.map(\.item.id), [900])
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertTrue(result.cursor.hasMore)
        XCTAssertEqual(result.cursor.pendingPosts.values.flatMap { $0 }.count, 5)
    }
    func testExclusionsMatchWhitespaceWithoutRemovingOtherNamespaces() {
        let control = TasteControl()
        for tag in ["female:solo female", "female:solo_female", " FEMALE : solo\u{00a0}female ", "female:solo__female", "female:solo\tfemale"] {
            XCTAssertFalse(control.allows(tag, source: "https://manga.la", mode: .comics), tag)
        }
        for tag in ["artist:solo_female", "female:solo_female_artist", "tag:watercolor"] {
            XCTAssertTrue(control.allows(tag, source: "https://manga.la", mode: .comics), tag)
        }
    }
    func testLegacyUnqualifiedComicTagsAndUnicodeSpacingAreExcludedEverywhere() {
        let item = TasteItem.comic(1, tags: "solo female, solo_male, digital, group, female : solo\u{00a0}female, artist:group, tag:watercolor")
        var event = TasteEvent(kind: .save, item: item, context: .init(origin: .search, query: "digital"))
        event.at = 100
        let period = DateInterval(start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 200))
        for range: DateInterval? in [nil, period] {
            let result = TasteAnalyzer.analyze([event], control: .init(), period: range, previous: period, mode: .comics)
            XCTAssertEqual(Set(result.tags.map(\.name)), ["artist:group", "tag:watercolor"])
            XCTAssertFalse(result.previousTagCounts.keys.contains { $0.hasSuffix("\nsolo_female") })
        }
        var control = TasteControl()
        control.setAnalysisExcluded([], mode: .comics)
        XCTAssertTrue(control.allows("solo female", source: item.source, mode: .comics))
        XCTAssertTrue(TasteControl().allows("digital", source: "https://example.test", mode: .booru))
        XCTAssertTrue(TasteControl().allows("male:solo_female", source: item.source, mode: .comics))
    }
    func testCorrectSoleSpellingAndStoredSoloControlsFilterAllAnalysisPeriods() throws {
        var control = TasteControl()
        // Simulate controls saved by the previous release, bypassing the new setter.
        control.analysisExclusions = ["comics": ["female:solo_female", "male:solo_male", "tag:digital", "tag:group"]]
        control = try JSONDecoder().decode(TasteControl.self, from: JSONEncoder().encode(control))
        let actual = NativeGallery.parseTags([["tag": "sole female", "female": "1"], ["tag": "sole male", "male": "1"], ["tag": "watercolor"]])
        let item = TasteItem(source: "https://manga.la", id: 1, tags: actual + ["sole female", "sole_male", "artist:solo_female", "female:sole_female_artist"])
        let event = TasteEvent(kind: .save, item: item, context: .init(origin: .search, query: "female:sole_female"))
        let period = DateInterval(start: .distantPast, end: .distantFuture)
        for range: DateInterval? in [nil, period] {
            let result = TasteAnalyzer.analyze([event], control: control, period: range, previous: period, mode: .comics)
            XCTAssertEqual(Set(result.tags.map(\.name)), ["tag:watercolor", "artist:solo_female", "female:sole_female_artist"])
            XCTAssertFalse(result.previousTagCounts.keys.contains { $0.hasSuffix("\nfemale:sole_female") })
        }
        XCTAssertEqual(control.analysisExcluded(.comics), TasteControl().analysisExcluded(.comics))
        control.setAnalysisExcluded(["female:solo_female", "female:sole female"], mode: .comics)
        XCTAssertEqual(control.analysisExclusions?["comics"], ["female:sole_female"])
        control.setAnalysisExcluded([], mode: .comics)
        XCTAssertTrue(control.allows("female:sole female", source: item.source, mode: .comics))
        XCTAssertTrue(TasteControl().allows("female:sole_female", source: "https://example.test", mode: .booru))
    }

    func testMetadataParserPreservesComicNamespaces() {
        let tags = NativeGallery.parseTags([
            ["tag": "solo female", "female": "1"], ["tag": "solo male", "male": 1],
            ["tag": "digital"], ["tag": "sample", "female": true, "male": true]
        ])
        XCTAssertEqual(tags, ["female:solo female", "male:solo male", "tag:digital", "female:sample", "male:sample"])
    }
    @MainActor func testExclusionImmediatelyRemovesCachedEvidenceWithoutReplacingWorks() async throws {
        let env = AppEnvironment.preview(), server = BooruServer.presets[0]
        try env.booru.saveServer(server); try env.booru.select(server)
        try env.booru.toggleFavorite(BooruFixtureSource.post(101, server: server, tags: ["scenery"]), context: .init(origin: .search, query: "scenery"))
        let source = PagedTasteSource(), feed = TasteFeedState(booruSource: PagedTasteSource())
        feed.ensureLoaded(mode: .booru, env: env, language: "all"); await feed.waitForRefresh()
        let ids = feed.results.items.map(\.id), session = feed.discoverySession, version = feed.pageVersion
        XCTAssertFalse(ids.isEmpty); XCTAssertFalse(try XCTUnwrap(feed.snapshot).tags.isEmpty)
        var control = env.taste.control
        control.setAnalysisExcluded(["scenery"], mode: .booru)
        feed.applyExclusions(control, mode: .booru)
        XCTAssertTrue(try XCTUnwrap(feed.snapshot).tags.isEmpty)
        XCTAssertTrue(feed.report?.insights.isEmpty ?? true)
        XCTAssertEqual(feed.results.items.map(\.id), ids)
        XCTAssertEqual(feed.discoverySession, session); XCTAssertEqual(feed.pageVersion, version)
        env.taste.change { $0 = control }
        await feed.loadMore(mode: .booru, env: env, language: "all")
        XCTAssertEqual(feed.results.items.map(\.id), ids)
        let refreshed = try await env.taste.snapshot(.booru, period: .recommendations, offset: 0)
        XCTAssertTrue(refreshed.tags.isEmpty)
        let result = try await RecommendationService.load(mode: .booru, snapshot: refreshed, report: nil, env: env, language: "all", booruSource: source)
        XCTAssertTrue(result.items.isEmpty)
        let requests = await source.pages; XCTAssertTrue(requests.isEmpty)
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
    @MainActor func testManualRefreshDealsUnseenWorksBeforeRepeating() async throws {
        let env = AppEnvironment.preview(), server = BooruServer.presets[0]
        try env.booru.saveServer(server); try env.booru.select(server)
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
        let control = TasteControl()
        let first = await StatisticalInsightService.report(snapshot: snapshot, control: control, language: "en")
        let next = await StatisticalInsightService.report(snapshot: snapshot, control: control, language: "en", selectionOffset: 3)
        XCTAssertTrue(first.isValid(for: snapshot)); XCTAssertTrue(next.isValid(for: snapshot))
        XCTAssertTrue(Set(first.insights.map(\.tagKey)).isDisjoint(with: next.insights.map(\.tagKey)))
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

private actor ServerTasteSource: BooruProviding {
    var queries: [String: String] = [:]
    let slowID: String?
    init(slowID: String? = nil) { self.slowID = slowID }
    func posts(server: BooruServer, query: String, page: Int) async throws -> BooruBatch {
        queries[server.id] = query
        if server.id == slowID {
            // Deliberately ignores cancellation, like a late WebKit callback.
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) { continuation.resume() }
            }
        }
        var post = BooruFixtureSource.post(900, server: server, tags: ["taste_" + server.id.lowercased()])
        if server.engine.usesGelbooruPages { post.tags = []; post.fileURL = nil; post.sampleURL = nil }
        return .init(posts: [post], hasMore: false)
    }
    func details(server: BooruServer, post: BooruPost) async throws -> BooruPost { BooruFixtureSource.post(post.postID, server: server, tags: ["taste_" + server.id.lowercased()]) }
    func suggestions(server: BooruServer, token: String) async throws -> [BooruTag] { [] }
    func pools(server: BooruServer, query: String, page: Int) async throws -> [BooruPool] { [] }
    func poolPosts(server: BooruServer, poolID: Int64, page: Int) async throws -> BooruBatch { .init(posts: [], hasMore: false) }
    func notes(server: BooruServer, postID: Int64) async throws -> [BooruNote] { [] }
}

extension TasteFeedTests {
    func testAllServersCanBeDeselectedAcrossReloadWithoutFallback() throws {
        let store = try BooruStore()
        for server in BooruServer.presets { try store.saveServer(server) }
        try store.select(BooruServer.presets[0])
        try store.toggleServer(BooruServer.presets[0])
        XCTAssertTrue(store.selectedServers.isEmpty); XCTAssertNil(store.selectedServer)
        try store.reload()
        XCTAssertTrue(store.selectedServerIDs.isEmpty); XCTAssertNil(store.selectedServer)
        try store.toggleServer(BooruServer.presets[1])
        XCTAssertEqual(store.selectedServerIDs, [BooruServer.presets[1].id])
        try store.setSelectedServers([]); try store.reload()
        XCTAssertTrue(store.selectedServers.isEmpty)
    }
    @MainActor func testSameEngineServersHaveIndependentSettingsEvidenceAndFeeds() async throws {
        let env = AppEnvironment.preview()
        let a = BooruServer(id: "a", name: "A", baseURL: URL(string: "https://a.booru.org")!, engine: .oldGelbooru)
        let b = BooruServer(id: "b", name: "B", baseURL: URL(string: "https://b.booru.org")!, engine: .oldGelbooru)
        for server in [a, b] { try env.booru.saveServer(server) }
        var control = TasteControl()
        control.setPreferences(.init(includedTags: ["watercolor"], language: "all", sort: .latest), source: a.canonicalAddress)
        control.setAnalysisExcluded(["common"], mode: .booru, source: a.canonicalAddress)
        XCTAssertTrue(control.preferences(source: b.canonicalAddress).includedTags.isEmpty)
        XCTAssertEqual(control.preferences(source: b.canonicalAddress).sort, .recommended)
        XCTAssertFalse(control.allows("common", source: a.canonicalAddress, mode: .booru))
        XCTAssertTrue(control.allows("common", source: b.canonicalAddress, mode: .booru))
        let restored = try JSONDecoder().decode(TasteControl.self, from: JSONEncoder().encode(control))
        XCTAssertEqual(restored, control)
        XCTAssertFalse(env.taste.feed(.booru, source: a.canonicalAddress) === env.taste.feed(.booru, source: b.canonicalAddress))
        XCTAssertTrue(env.taste.feed(.booru, source: a.canonicalAddress) === env.taste.feed(.booru, source: a.canonicalAddress))
        let events = [a,b].map { TasteEvent(kind: .save, item: .init(source: $0.canonicalAddress, id: 1, tags: ["common", "watercolor"])) }
        let result = TasteAnalyzer.analyze(events, control: control)
        XCTAssertEqual(result.tags.filter { $0.name == "common" }.map(\.source), [b.canonicalAddress])
    }
    @MainActor func testUnsupportedRecommendationSortPreservesPriorFeedAndCursor() async throws {
        let env = AppEnvironment.preview(), server = BooruServer.presets[0]
        try env.booru.saveServer(server); try env.booru.select(server)
        try env.booru.toggleFavorite(BooruFixtureSource.post(101, server: server, tags: ["scenery"]), context: .init(origin: .search, query: "scenery"))
        let feed = TasteFeedState(source: server.canonicalAddress, booruSource: SortingTasteSource())
        feed.refresh(mode: .booru, env: env, language: "all"); await feed.waitForRefresh()
        let ids = feed.results.items.map(\.id), pages = feed.results.cursor.pages
        XCTAssertFalse(ids.isEmpty)
        env.taste.change { $0.setPreferences(.init(sort: .week), source: server.canonicalAddress) }
        feed.refresh(mode: .booru, env: env, language: "all"); await feed.waitForRefresh()
        XCTAssertEqual(feed.results.items.map(\.id), ids)
        XCTAssertEqual(feed.results.cursor.pages, pages)
        XCTAssertEqual(env.taste.control.preferences(source: server.canonicalAddress).sort, .recommended)
        XCTAssertNotNil(feed.sortMessage)
        XCTAssertFalse(feed.loading)
    }
    @MainActor func testExploreUnsupportedSortPreservesPostsAndNetworkErrorsAreNotUnsupported() async throws {
        let loader = BooruFeedLoader(), server = BooruServer.presets[0]
        await loader.load(servers: [server], source: SortingTasteSource(), query: "scenery", reset: true)
        let ids = loader.posts.map(\.id)
        await loader.load(servers: [server], source: SortingTasteSource(), query: "scenery", sort: .popular, reset: true)
        XCTAssertTrue(loader.unsupportedSort); XCTAssertEqual(loader.posts.map(\.id), ids)
        do {
            _ = try await BooruSortValidation.posts(source: SortingTasteSource(networkError: true), server: server, query: "scenery", page: 0, sort: .popular)
            XCTFail("Expected network error")
        } catch { XCTAssertTrue(error is URLError); XCTAssertFalse(error is UnsupportedBooruSort) }
    }
    @MainActor func testComicRecommendationLanguageAndRequiredTagsAreExplicit() async throws {
        let env = AppEnvironment.preview(); env.isSiteVerified = true
        env.defaultTags = "implicit_tag"
        let source = CapturingComicTasteSource()
        let tag = TasteTag(source: "https://manga.la", name: "tag:scenery", general: 5)
        let snapshot = TasteSnapshot(tags: [tag], saves: 5, opens: 0, searches: 0, activity: [:], digest: "language", period: nil)
        _ = try await RecommendationService.load(mode: .comics, snapshot: snapshot, report: nil, env: env, language: "korean", comicSource: source)
        var requests = await source.queries
        XCTAssertEqual(requests.last?.language, "all")
        XCTAssertFalse(requests.last?.text.contains("implicit_tag") ?? true)
        env.taste.change { $0.setPreferences(.init(includedTags: ["tag:watercolor"], language: "japanese", sort: .month), source: "https://manga.la") }
        _ = try await RecommendationService.load(mode: .comics, snapshot: snapshot, report: nil, env: env, language: "korean", comicSource: source)
        requests = await source.queries
        XCTAssertEqual(requests.last?.language, "japanese")
        XCTAssertEqual(requests.last?.sort, .month)
        XCTAssertTrue(requests.last?.text.contains("tag:watercolor") ?? false)
    }
}
private struct SortingTasteSource: BooruProviding {
    var networkError = false
    func posts(server: BooruServer, query: String, page: Int) async throws -> BooruBatch {
        if query.contains("order:score") || query.contains("sort:score") {
            if networkError { throw URLError(.notConnectedToInternet) }
            throw BooruError.unavailable(422)
        }
        return .init(posts: [BooruFixtureSource.post(201, server: server, tags: ["scenery"])], hasMore: false)
    }
    func suggestions(server: BooruServer, token: String) async throws -> [BooruTag] { [] }
    func pools(server: BooruServer, query: String, page: Int) async throws -> [BooruPool] { [] }
    func poolPosts(server: BooruServer, poolID: Int64, page: Int) async throws -> BooruBatch { .init(posts: [], hasMore: false) }
    func notes(server: BooruServer, postID: Int64) async throws -> [BooruNote] { [] }
}
private actor CapturingComicTasteSource: ContentProviding {
    var queries: [GalleryQuery] = []
    func list(_ query: GalleryQuery, offset: Int, count: Int) async throws -> GalleryBatch { queries.append(query); return .init(ids: [], hasMore: false) }
    func gallery(_ id: Int64) async throws -> NativeGallery { throw ContentError.invalidResponse }
    func image(_ page: GalleryPage, galleryID: Int64, thumbnail: Bool) async throws -> Data { throw ContentError.invalidResponse }
}

extension TasteFeedTests {
    @MainActor func testIncludedTagsAreIndependentForSitesWithTheSameEngine() async throws {
        let env = AppEnvironment.preview()
        let sites = ["a", "b"].map { BooruServer(id: $0, name: $0, baseURL: URL(string: "https://\($0).booru.org")!, engine: .oldGelbooru) }
        for site in sites { try env.booru.saveServer(site) }
        env.taste.change { control in
            control.setPreferences(.init(includedTags: ["watercolor"]), source: sites[0].canonicalAddress)
            control.setPreferences(.init(includedTags: ["oil_painting"]), source: sites[1].canonicalAddress)
        }
        let source = RequiredTagTasteSource()
        let tags = sites.map { TasteTag(source: $0.canonicalAddress, name: "taste_" + $0.id, general: 5) }
        let snapshot = TasteSnapshot(tags: tags, saves: 10, opens: 0, searches: 0, activity: [:], digest: "same-engine", period: nil)
        let result = try await RecommendationService.load(mode: .booru, snapshot: snapshot, report: nil, env: env, language: "all", booruSource: source, sourceAddresses: sites.map(\.canonicalAddress))
        XCTAssertEqual(result.items.count, 2)
        let queries = await source.queries
        XCTAssertTrue(queries["a"]?.contains("watercolor") ?? false)
        XCTAssertFalse(queries["a"]?.contains("oil_painting") ?? true)
        XCTAssertTrue(queries["b"]?.contains("oil_painting") ?? false)
        XCTAssertFalse(queries["b"]?.contains("watercolor") ?? true)
        XCTAssertEqual(result.cursor.pages.count, 2)
        XCTAssertTrue(result.items.allSatisfy { $0.item.source == $0.reason.source })
    }
    func testSilentlyIgnoredPopularitySortIsRejected() async throws {
        do {
            _ = try await BooruSortValidation.posts(source: RequiredTagTasteSource(), server: BooruServer.presets[0], query: "scenery", page: 0, sort: .popular)
            XCTFail("Ascending scores cannot satisfy descending popularity")
        } catch { XCTAssertTrue(error is UnsupportedBooruSort) }
    }
}
private actor GoldRestrictedTasteSource: BooruProviding {
    let repeatsRestrictedPage: Bool
    var pages: [Int] = []
    init(repeatsRestrictedPage: Bool = false) { self.repeatsRestrictedPage = repeatsRestrictedPage }
    func posts(server: BooruServer, query: String, page: Int) async throws -> BooruBatch {
        pages.append(page)
        if page == 0 || repeatsRestrictedPage { return .init(posts: [], hasMore: true, goldRestrictedIDs: [201]) }
        return .init(posts: [BooruFixtureSource.post(203, server: server, tags: ["scenery"])], hasMore: false)
    }
    func suggestions(server: BooruServer, token: String) async throws -> [BooruTag] { [] }
    func pools(server: BooruServer, query: String, page: Int) async throws -> [BooruPool] { [] }
    func poolPosts(server: BooruServer, poolID: Int64, page: Int) async throws -> BooruBatch { .init(posts: [], hasMore: false) }
    func notes(server: BooruServer, postID: Int64) async throws -> [BooruNote] { [] }
}
private actor RequiredTagTasteSource: BooruProviding {
    var queries: [String: String] = [:]
    func posts(server: BooruServer, query: String, page: Int) async throws -> BooruBatch {
        queries[server.id] = query
        let tags = query.split(separator: " ").map(String.init)
        var first = BooruFixtureSource.post(201, server: server, tags: tags); first.score = 1
        if query.contains("order:score") {
            var second = BooruFixtureSource.post(202, server: server, tags: tags); second.score = 20
            return .init(posts: [first, second], hasMore: false)
        }
        return .init(posts: [first], hasMore: false)
    }
    func suggestions(server: BooruServer, token: String) async throws -> [BooruTag] { [] }
    func pools(server: BooruServer, query: String, page: Int) async throws -> [BooruPool] { [] }
    func poolPosts(server: BooruServer, poolID: Int64, page: Int) async throws -> BooruBatch { .init(posts: [], hasMore: false) }
    func notes(server: BooruServer, postID: Int64) async throws -> [BooruNote] { [] }
}

private actor LegacyDetailTasteSource: BooruProviding {
    var listings = 0
    let slowDetail: Bool
    init(slowDetail: Bool = false) { self.slowDetail = slowDetail }
    func posts(server: BooruServer, query: String, page: Int) async throws -> BooruBatch {
        listings += 1
        return .init(posts: (900...906).map { id in
            BooruFixtureSource.post(Int64(id), server: server, tags: slowDetail && id == 900 ? ["scenery"] : [])
        }, hasMore: false)
    }
    func details(server: BooruServer, post: BooruPost) async throws -> BooruPost {
        if slowDetail { try await Task.sleep(for: .seconds(2)) }
        return BooruFixtureSource.post(post.postID, server: server, tags: ["scenery"])
    }
    func suggestions(server: BooruServer, token: String) async throws -> [BooruTag] { [] }
    func pools(server: BooruServer, query: String, page: Int) async throws -> [BooruPool] { [] }
    func poolPosts(server: BooruServer, poolID: Int64, page: Int) async throws -> BooruBatch { .init(posts: [], hasMore: false) }
    func notes(server: BooruServer, postID: Int64) async throws -> [BooruNote] { [] }
}

private actor PopularityTasteSource: BooruProviding {
    var queries: [String] = []
    var empty: Bool
    init(empty: Bool = false) { self.empty = empty }
    func posts(server: BooruServer, query: String, page: Int) async throws -> BooruBatch {
        queries.append(query)
        if empty { return .init(posts: [], hasMore: false) }
        var first = BooruFixtureSource.post(201, server: server, tags: ["scenery"])
        var second = BooruFixtureSource.post(202, server: server, tags: ["scenery"])
        first.score = 1; first.favoriteCount = 100
        second.score = 90; second.favoriteCount = 2
        return .init(posts: [first, second], hasMore: false)
    }
    func suggestions(server: BooruServer, token: String) async throws -> [BooruTag] { [] }
    func pools(server: BooruServer, query: String, page: Int) async throws -> [BooruPool] { [] }
    func poolPosts(server: BooruServer, poolID: Int64, page: Int) async throws -> BooruBatch { .init(posts: [], hasMore: false) }
    func notes(server: BooruServer, postID: Int64) async throws -> [BooruNote] { [] }
}

extension TasteFeedTests {
    @MainActor func testFavoriteAndTrendingOrdersSurviveExploreAndRecommendations() async throws {
        let env = AppEnvironment.preview(), server = BooruServer.presets[0]
        try env.booru.saveServer(server); try env.booru.select(server)
        let snapshot = TasteSnapshot(tags: [.init(source: server.canonicalAddress, name: "scenery", general: 5)], saves: 5, opens: 0, searches: 0, activity: [:], digest: "sort", period: nil)
        for sort: BooruSort in [.mostFavorited, .trending] {
            let source = PopularityTasteSource(), loader = BooruFeedLoader()
            await loader.load(servers: [server], source: source, query: "scenery", sort: sort, reset: true)
            XCTAssertFalse(loader.unsupportedSort)
            XCTAssertEqual(loader.posts.map(\.postID), [201, 202])
            let result = try await RecommendationService.load(mode: .booru, snapshot: snapshot, report: nil, env: env, language: "all", booruSource: source, preferencesOverride: [server.canonicalAddress: .init(sort: try XCTUnwrap(RecommendationSort(rawValue: sort.rawValue)))])
            XCTAssertEqual(result.items.map(\.item.id), [201, 202])
            let queries = await source.queries
            XCTAssertEqual(queries.count, 2)
            XCTAssertTrue(queries.allSatisfy { $0.contains(sort == .trending ? "order:rank" : "order:favcount") })
        }
    }
    func testTimeRestrictedEmptySortDoesNotProbeAndUnsupportedEngineDoesNotRequest() async throws {
        for sort: BooruSort in [.trending, .popularWeek, .popularMonth] {
            let source = PopularityTasteSource(empty: true)
            _ = try await BooruSortValidation.posts(source: source, server: BooruServer.presets[0], query: "scenery", page: 0, sort: sort)
            let count = await source.queries.count
            XCTAssertEqual(count, 1)
        }
        let source = PopularityTasteSource()
        let server = BooruServer(id: "gel", name: "Gel", baseURL: URL(string: "https://gel.test")!, engine: .gelbooru)
        do {
            _ = try await BooruSortValidation.posts(source: source, server: server, query: "scenery", page: 0, sort: .mostFavorited)
            XCTFail("Unsupported sort must be rejected before transmission")
        } catch { XCTAssertTrue(error is UnsupportedBooruSort) }
        let queries = await source.queries
        XCTAssertTrue(queries.isEmpty)
    }
}

private actor CancellableTasteSource: BooruProviding {
    var pages: [Int] = []
    private var waiting: CheckedContinuation<Void, Never>?
    private var paginationStarted = false
    private var delayPagination = true
    func waitForPagination() async {
        if paginationStarted { return }
        await withCheckedContinuation { waiting = $0 }
    }
    func allowPagination() { delayPagination = false }
    func posts(server: BooruServer, query: String, page: Int) async throws -> BooruBatch {
        pages.append(page)
        if page > 0 && delayPagination {
            paginationStarted = true; waiting?.resume(); waiting = nil
            try await Task.sleep(for: .seconds(30))
        }
        return .init(posts: (page == 0 ? [201, 202] : [203]).map { BooruFixtureSource.post(Int64($0), server: server, tags: ["scenery"]) }, hasMore: page == 0)
    }
    func suggestions(server: BooruServer, token: String) async throws -> [BooruTag] { [] }
    func pools(server: BooruServer, query: String, page: Int) async throws -> [BooruPool] { [] }
    func poolPosts(server: BooruServer, poolID: Int64, page: Int) async throws -> BooruBatch { .init(posts: [], hasMore: false) }
    func notes(server: BooruServer, postID: Int64) async throws -> [BooruNote] { [] }
}

private actor SavingComicTasteSource: ContentProviding {
    let database: AppDatabase
    var requested: [Int64] = []
    init(database: AppDatabase) { self.database = database }
    func list(_ query: GalleryQuery, offset: Int, count: Int) async throws -> GalleryBatch {
        .init(ids: Array(1...8).map(Int64.init), hasMore: false)
    }
    func gallery(_ id: Int64) async throws -> NativeGallery {
        requested.append(id)
        if id == 2 { _ = try database.upsertWork(galleryId: 3) }
        return .init(id: id, title: "Work \(id)", artists: [], language: "", type: "manga", tags: ["tag:scenery"], pages: [])
    }
    func image(_ page: GalleryPage, galleryID: Int64, thumbnail: Bool) async throws -> Data { throw ContentError.invalidResponse }
}
