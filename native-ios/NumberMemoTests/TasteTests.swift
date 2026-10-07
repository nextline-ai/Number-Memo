import XCTest
import GRDB
@testable import NumberMemo

final class TasteTests: XCTestCase {
    func testOnDeviceInsightGenerationWhenAvailable() async throws {
        guard OnDeviceInsightService.canGenerate else { throw XCTSkip("The on-device model is unavailable on this device.") }
        let snapshot = TasteAnalyzer.analyze((1...8).map { event(Int64($0), session: "sample-\($0)") }, control: .init())
        let report = await OnDeviceInsightService.report(snapshot: snapshot, control: .init(), language: "en")
        XCTAssertTrue(report.isValid(for: snapshot))
        let result = XCTAttachment(string: report.generatedByAI ? "On-device generation succeeded with validated anonymous references." : "On-device generation used the validated statistical fallback.")
        result.name = "On-device insight result"; result.lifetime = .keepAlways; add(result)
    }
    func testSearchRetentionDefaultsToForeverAndPreservesExplicitChoice() throws {
        let suite = "taste-retention-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(SearchRetention.days(in: defaults), 0)
        defaults.set(7, forKey: "search.retentionDays")
        XCTAssertEqual(SearchRetention.days(in: defaults), 7)
        defaults.set(0, forKey: "search.retentionDays")
        XCTAssertEqual(SearchRetention.days(in: defaults), 0)
    }
    private let source = "https://example.test"
    private func event(_ id: Int64, tags: [String] = ["blue_hair", "green_eyes"], query: String = "blue_hair", session: String = "s1", kind: TasteEvent.Kind = .save, at: Double = 100) -> TasteEvent {
        var e = TasteEvent(kind: kind, item: .init(source: source, id: id, tags: tags), context: .init(origin: .search, query: query, session: session)); e.at = at; return e
    }
    func testExplicitAndHiddenStacksAndTechnicalExclusion() {
        var e = event(1, tags: ["blue_hair", "green_eyes", "animated", "png", "highres", "tagme", "custom_meta", "pixel_art"])
        e.item.metadata = ["custom_meta"]
        let result = TasteAnalyzer.analyze([e], control: .init())
        XCTAssertEqual(result.tags.first { $0.name == "blue_hair" }?.confirmed, 1)
        XCTAssertEqual(result.tags.first { $0.name == "green_eyes" }?.hidden, 1)
        XCTAssertEqual(Set(result.tags.map(\.name)), ["blue_hair", "green_eyes", "pixel_art"])
        XCTAssertFalse(result.tags.contains(where: \.discovery))
    }
    func testExactExclusionsPreserveArtisticAndUnknownTags() {
        let tags = ["PNG", "highres", "translation_request", "monochrome", "pixel_art", "gif_artist", "character:tagme", "unknown_category"]
        XCTAssertEqual(Set(TasteTagPolicy.filter(tags)), ["monochrome", "pixel_art", "gif_artist", "character:tagme", "unknown_category"])
        XCTAssertTrue(TasteTagPolicy.filter(["rating:safe", "order:score", "filetype:png"]).isEmpty)
    }
    func testSearchedTechnicalTagsNeverBecomeConfirmed() {
        let result = TasteAnalyzer.analyze([event(1, tags: ["png", "animated", "green_eyes"], query: "png animated")], control: .init())
        XCTAssertEqual(result.tags.map(\.name), ["green_eyes"])
    }
    func testDuplicateEventsAndResavesCountOnceAndRemovalWithdraws() {
        let first = event(1), second = event(1, at: 200)
        let result = TasteAnalyzer.analyze([first, first, second], control: .init())
        XCTAssertEqual(result.tags.first { $0.name == "green_eyes" }?.hidden, 1)
        let removal = event(1, kind: .remove, at: 300)
        XCTAssertTrue(TasteAnalyzer.analyze([first, second, removal], control: .init()).tags.isEmpty)
        let historical = TasteAnalyzer.analyze([first, second, removal], control: .init(), period: .init(start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 400)))
        XCTAssertEqual(historical.saves, 1)
        XCTAssertEqual(historical.tags.first { $0.name == "green_eyes" }?.count, 1)
    }
    func testSeedsAreGeneralAndNotCurrentActivity() {
        var seed = event(1, kind: .seed); seed.at = 0; seed.context = .unknown
        let result = TasteAnalyzer.analyze([seed], control: .init())
        XCTAssertEqual(result.tags.first?.general, 1); XCTAssertEqual(result.saves, 0)
        let week = TasteAnalyzer.analyze([seed], control: .init(), period: .init(start: Date(timeIntervalSince1970: 1), end: Date(timeIntervalSince1970: 1000)))
        XCTAssertTrue(week.tags.isEmpty); XCTAssertEqual(week.saves, 0)
    }
    func testSearchOnlyDoesNotIncreasePreferenceAndKnownTagsAreNotDiscoveries() {
        var events = (1...6).map { event(Int64($0), session: "s\($0)") }
        XCTAssertTrue(TasteAnalyzer.analyze(events, control: .init()).tags.first { $0.name == "green_eyes" }!.discovery)
        events.append(event(0, tags: ["green_eyes"], query: "green_eyes", kind: .search))
        let result = TasteAnalyzer.analyze(events, control: .init())
        let tag = result.tags.first { $0.name == "green_eyes" }!
        XCTAssertEqual(tag.count, 6); XCTAssertEqual(tag.searches, 1); XCTAssertFalse(tag.discovery)
    }
    func testRecommendationsCannotManufactureOrganicEvidence() {
        let events = (1...10).map { id -> TasteEvent in
            var e = event(Int64(id), session: "s\(id)"); e.context.origin = .recommendation; return e
        }
        let result = TasteAnalyzer.analyze(events, control: .init())
        XCTAssertTrue(result.tags.allSatisfy { $0.confirmed == 0 && $0.hidden == 0 && !$0.discovery })
        XCTAssertEqual(result.opens, 0)
    }
    func testConstraintsAreNotHidden() {
        var e = event(1); e.context.constraints = ["green_eyes"]
        XCTAssertEqual(TasteAnalyzer.analyze([e], control: .init()).tags.map(\.name), ["blue_hair"])
    }
    func testLiftRequiresEnoughSamplesAndCommonTagsAreNotDiscoveries() {
        let opens = (1...40).map { event(Int64($0), tags: ["common", $0 <= 10 ? "rare" : "other"], query: "", session: "s\($0)", kind: .open) }
        let saves = (1...10).map { event(Int64($0), tags: ["common", "rare"], query: "", session: "s\($0)") }
        let result = TasteAnalyzer.analyze(opens + saves, control: .init())
        XCTAssertGreaterThan(result.tags.first { $0.name == "rare" }!.lift!, 1)
        XCTAssertFalse(result.tags.first { $0.name == "common" }!.discovery)
        XCTAssertNil(TasteAnalyzer.analyze(Array(saves.prefix(2)), control: .init()).tags.first?.lift)
    }
    func testMetadataBackfillDoesNotAddAnotherSave() {
        var metadata = event(1, tags: ["blue_hair", "green_eyes", "highres"], kind: .metadata, at: 200); metadata.context = .unknown
        let result = TasteAnalyzer.analyze([event(1, tags: []), metadata], control: .init())
        XCTAssertEqual(result.saves, 1); XCTAssertEqual(result.tags.first { $0.name == "blue_hair" }?.confirmed, 1)
        XCTAssertEqual(result.tags.first { $0.name == "green_eyes" }?.hidden, 1)
    }
    func testSourceNamespacesRemainSeparate() {
        var b = event(2); b.item.source = "https://other.test"
        XCTAssertEqual(TasteAnalyzer.analyze([event(1), b], control: .init()).tags.filter { $0.name == "blue_hair" }.count, 2)
    }
    func testPromptBoundaryContainsOnlyOpaqueTokensAndMetrics() throws {
        let snapshot = TasteAnalyzer.analyze([event(1)], control: .init())
        let boundary = TastePromptBoundary(snapshot: snapshot)
        let text = String(decoding: try JSONEncoder().encode(boundary.input), as: UTF8.self)
        for forbidden in ["blue_hair", "green_eyes", "example.test", "https", "s1"] { XCTAssertFalse(text.contains(forbidden)) }
        XCTAssertNil(boundary.validate([("invented", "frequent")]))
        let token = boundary.input.candidates[0].token
        XCTAssertNil(boundary.validate([(token, "discovery")]))
        XCTAssertNil(boundary.validate([(token, "frequent"), (token, "frequent")]))
        XCTAssertNotNil(boundary.validate([(token, "frequent")]))
    }
    func testDigestIsStableAcrossEncodingAndEventOrder() throws {
        let events = [event(1, tags: ["green_eyes", "blue_hair"], query: "blue_hair another_tag"), event(2)]
        let decoded = try JSONDecoder().decode([TasteEvent].self, from: JSONEncoder().encode(events))
        XCTAssertEqual(TasteAnalyzer.analyze(events, control: .init()).digest, TasteAnalyzer.analyze(decoded.reversed(), control: .init()).digest)
    }
    func testWeekMonthAndTimezoneBoundaries() throws {
        let now = ISO8601DateFormatter().date(from: "2026-10-07T18:00:00Z")!
        let week = try XCTUnwrap(TastePeriod.week.interval(offset: 0, now: now, timeZone: "Asia/Seoul"))
        XCTAssertEqual(ISO8601DateFormatter().string(from: week.start), "2026-10-04T15:00:00Z")
        let month = try XCTUnwrap(TastePeriod.month.interval(offset: 0, now: now, timeZone: "Asia/Seoul"))
        XCTAssertEqual(ISO8601DateFormatter().string(from: month.start), "2026-09-30T15:00:00Z")
    }
    func testAtomicComicSaveMetadataAndRemoval() throws {
        let db = try AppDatabase.inMemory()
        let context = DiscoveryContext(origin: .search, query: "female:blue_hair")
        _ = try db.upsertWork(galleryId: 1, tags: "female:blue_hair, female:green_eyes", discoveryContext: context)
        _ = try db.upsertWork(galleryId: 1, tags: "female:blue_hair, female:green_eyes", discoveryContext: context)
        XCTAssertEqual(try db.tasteStore.events().filter { $0.kind == .save }.count, 1)
        XCTAssertEqual(try db.tasteStore.events().count, 1)
        try db.deleteWork(galleryId: 1)
        XCTAssertTrue(TasteAnalyzer.analyze(try db.tasteStore.events(), control: .init()).tags.isEmpty)
    }
    func testPeerMergePauseAndResetDoNotResurrectActivity() throws {
        let a = try AppDatabase.inMemory().tasteStore, b = try AppDatabase.inMemory().tasteStore
        try a.record(.save, item: event(1).item, context: event(1).context)
        let original = try a.events()
        try b.merge(original); try b.merge(original)
        XCTAssertEqual(try b.events().count, 1)
        try b.record(.save, item: event(2).item, context: event(2).context)
        var paused = TasteControl(); paused.enabled = false; paused.generation = "paused"; paused.timestamp = 200
        try b.setControl(paused, remote: true)
        XCTAssertEqual(try b.events().count, 1)
        try b.record(.save, item: event(3).item, context: .unknown)
        XCTAssertEqual(try b.events().count, 1)
        var reset = paused; reset.epoch = "reset"; reset.timestamp = 300
        try a.setControl(reset, remote: true); try b.setControl(reset, remote: true)
        try a.merge(original); try b.merge(original)
        XCTAssertTrue(try a.events().isEmpty); XCTAssertTrue(try b.events().isEmpty)
        try b.bootstrap([event(4).item]); XCTAssertTrue(try b.events().isEmpty)
    }
    func testCloudChunksRoundTripWithoutMediaAndDeduplicate() throws {
        let chunk = TasteSyncChunk(mode: .booru, epoch: "initial", events: [event(1)])
        let data = try JSONEncoder().encode(chunk)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("fileURL")); XCTAssertFalse(text.contains("previewURL")); XCTAssertFalse(text.contains("title"))
        let decoded = try JSONDecoder().decode(TasteSyncChunk.self, from: data)
        let store = try AppDatabase.inMemory().tasteStore
        try store.merge(decoded.events); try store.merge(decoded.events)
        XCTAssertEqual(try store.events().count, 1)
    }
    func testAnalysisCacheIncludesLateEventsAndReset() async throws {
        let store = try AppDatabase.inMemory().tasteStore, cache = TasteAnalysisCache()
        try store.merge([event(1, at: 200)])
        let first = try await cache.snapshot(store: store, control: .init(), period: nil, previous: nil)
        try store.merge([event(2, at: 100)])
        let second = try await cache.snapshot(store: store, control: .init(), period: nil, previous: nil)
        XCTAssertEqual(first.saves, 1); XCTAssertEqual(second.saves, 2)
        var reset = TasteControl(); reset.epoch = "new"
        try store.setControl(reset)
        let last = try await cache.snapshot(store: store, control: reset, period: nil, previous: nil)
        XCTAssertTrue(last.tags.isEmpty)
    }
    func testRecommendationMixAndTechnicalScoring() {
        var candidates: [TasteRecommendation] = []
        for i in 1...30 {
            var tag = TasteTag(source: source, name: "green_eyes"); tag.hidden = i > 15 ? 5 : 0; tag.general = i <= 15 ? 2 : 0; tag.sessions = ["a", "b", "c"]
            candidates.append(.init(item: event(Int64(i)).item, post: nil, gallery: nil, reason: tag, score: Double(i)))
        }
        let mixed = RecommendationService.mix(candidates)
        XCTAssertEqual(mixed.count, 20); XCTAssertEqual(mixed.filter { $0.reason.discovery }.count, 6)
        let tag = TasteTag(source: source, name: "png", general: 100)
        XCTAssertEqual(RecommendationService.score(.init(source: source, id: 1, tags: ["png"]), tags: [tag]), 0)
    }
    func testStalePreferenceEditCannotUndoResetOrPause() {
        var original = TasteControl()
        original.author = "a"
        var reset = original; reset.timestamp = 100; reset.epoch = UUID().uuidString; reset.resetTimestamp = 100; reset.resetAuthor = "a"
        reset.enabled = false; reset.enabledTimestamp = 100; reset.enabledAuthor = "a"; reset.generation = "paused"
        var stale = original; stale.timestamp = 200; stale.author = "b"; stale.aiEnabled = false
        let merged = reset.merged(with: stale)
        XCTAssertEqual(merged.epoch, reset.epoch); XCTAssertFalse(merged.enabled); XCTAssertEqual(merged.generation, "paused")
        XCTAssertFalse(merged.aiEnabled)
        XCTAssertEqual(merged, stale.merged(with: reset))
    }
    func testServerMetadataClassificationAlsoExcludesSearchAndLegacyEvidence() {
        var typed = event(2, tags: ["custom_technical", "green_eyes"], kind: .open)
        typed.item.metadata = ["custom_technical"]
        let search = event(0, tags: ["custom_technical"], query: "custom_technical", kind: .search)
        let legacy = event(1, tags: ["custom_technical", "green_eyes"], query: "custom_technical")
        XCTAssertEqual(TasteAnalyzer.analyze([typed, search, legacy], control: .init()).tags.map(\.name), ["green_eyes"])
    }
    func testBooruMetaTagsSurviveLegacyDecodingAndServerRemap() throws {
        let server = BooruServer.presets[0]
        let post = try BooruDecoder.post(["id": 1, "tag_string": "blue_hair custom_meta", "tag_string_meta": "custom_meta", "file_ext": "png"], server: server)
        XCTAssertEqual(post.metadataTags, ["custom_meta"])
        XCTAssertEqual(post.onServer("another").metadataTags, ["custom_meta"])
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(post)) as! [String: Any]
        object.removeValue(forKey: "metadataTags")
        let legacy = try JSONDecoder().decode(BooruPost.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(legacy.metadataTags)
    }

    func testImportsSeedGeneralTasteWithoutCountingNewActivity() throws {
        let db = try AppDatabase.inMemory()
        _ = try db.upsertWork(galleryId: 5, tags: "blue_hair, green_eyes")
        try db.tasteStore.bootstrap([.comic(5, tags: "blue_hair, green_eyes")])
        let events = try db.tasteStore.events()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.kind, .imported)
        let snapshot = TasteAnalyzer.analyze(events, control: .init())
        XCTAssertEqual(snapshot.saves, 0)
        XCTAssertTrue(snapshot.tags.allSatisfy { $0.general == 1 && $0.confirmed == 0 && $0.hidden == 0 })
    }

    func testTaxonomyDoesNotAddActivityAndRetroactivelyFiltersTechnicalTags() {
        var taxonomy = event(0, tags: [], kind: .taxonomy)
        taxonomy.item.metadata = ["custom_meta"]
        let saved = event(1, tags: ["custom_meta", "green_eyes"], query: "custom_meta")
        let result = TasteAnalyzer.analyze([saved, taxonomy], control: .init())
        XCTAssertEqual(result.tags.map(\.name), ["green_eyes"])
        XCTAssertEqual(result.saves, 1)
        XCTAssertEqual(result.searches, 0)
    }

    func testOlderLibraryRemovalInvalidatesCurrentProfileAndDigest() {
        let saved = event(1)
        let before = TasteAnalyzer.analyze([saved], control: .init(), savedKeys: [saved.item.key])
        let after = TasteAnalyzer.analyze([saved], control: .init(), savedKeys: [])
        XCTAssertFalse(before.tags.isEmpty)
        XCTAssertTrue(after.tags.isEmpty)
        XCTAssertNotEqual(before.digest, after.digest)
        let historical = TasteAnalyzer.analyze([saved], control: .init(), period: .init(start: .init(timeIntervalSince1970: 0), end: .init(timeIntervalSince1970: 200)), savedKeys: [])
        XCTAssertEqual(historical.saves, 1)
        XCTAssertFalse(historical.tags.isEmpty)
    }

    func testCachedReportRejectsUnsupportedEvidence() {
        let snapshot = TasteAnalyzer.analyze([event(1)], control: .init())
        var report = TasteReport(epoch: "initial", digest: snapshot.digest, language: "en", insights: [.init(tagKey: snapshot.tags[0].id, pattern: .frequent)], generatedByAI: true)
        XCTAssertTrue(report.isValid(for: snapshot))
        report.insights[0].pattern = .discovery
        XCTAssertFalse(report.isValid(for: snapshot))
        report.insights[0].pattern = .association
        report.insights[0].relatedKey = snapshot.tags[1].id
        XCTAssertFalse(report.isValid(for: snapshot))
        report.insights[0] = .init(tagKey: "invented", pattern: .frequent)
        XCTAssertFalse(report.isValid(for: snapshot))
    }

    func testCoordinatedChunkFilesInventoryReadAndDelete() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let controlURL = root.appendingPathComponent("taste-control-device.json")
        let chunkURL = root.appendingPathComponent("initial/taste-2026-10-device.json")
        let data = try JSONEncoder().encode(TasteSyncChunk(mode: .booru, epoch: "initial", events: [event(1)]))
        try CloudLibraryFiles.write(try JSONEncoder().encode(TasteControl()), to: controlURL, ubiquitous: false)
        try CloudLibraryFiles.write(data, to: chunkURL, ubiquitous: false)
        let inventory = try TasteCloudFiles.inventory(root)
        XCTAssertEqual(inventory.controls, [controlURL])
        XCTAssertEqual(inventory.data, [chunkURL])
        XCTAssertEqual(try TasteCloudFiles.read(chunkURL), data)
        try TasteCloudFiles.remove(chunkURL)
        XCTAssertTrue(try TasteCloudFiles.inventory(root).data.isEmpty)
    }

    func testRemovingServerWithdrawsSavedTasteEvidence() throws {
        let store = try BooruStore(), server = BooruServer.presets[0]
        try store.saveServer(server)
        try store.toggleFavorite(BooruFixtureSource.post(42, server: server), context: .init(origin: .feed))
        XCTAssertEqual(try store.tasteStore.events().filter { $0.kind == .save }.count, 1)
        try store.deleteServer(server)
        let events = try store.tasteStore.events()
        XCTAssertEqual(events.filter { $0.kind == .remove }.count, 1)
        XCTAssertTrue(TasteAnalyzer.analyze(events, control: .init()).tags.isEmpty)
    }

    func testRecommendationPromptOmitsContentAndRejectsUnknownSelections() throws {
        let candidate = TasteRecommendation(item: event(1).item, post: nil, gallery: nil, reason: .init(source: source, name: "blue_hair", general: 3), score: 2)
        let boundary = RecommendationPromptBoundary([candidate])
        let encoded = String(decoding: try JSONEncoder().encode(boundary.input), as: UTF8.self)
        XCTAssertFalse(encoded.contains("blue_hair"))
        XCTAssertFalse(encoded.contains(source))
        XCTAssertEqual(boundary.validate(["C1"])?.map(\.id), [candidate.id])
        XCTAssertNil(boundary.validate(["C2"]))
        XCTAssertNil(boundary.validate(["C1", "C1"]))
    }

}
