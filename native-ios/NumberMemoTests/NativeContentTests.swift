import XCTest
import UIKit
@testable import NumberMemo

final class NativeContentTests: XCTestCase {
    private let sampleHash = String(repeating: "0", count: 61) + "abc"
    private var routing: String {
        """
        'use strict';
        gg = { m: function(g) {
        var o = 0;
        switch (g) {
        case 3243:
        o = 1; break;
        }
        return o;
        },
        s: function(h) { var m = /(..)(.)$/.exec(h); return parseInt(m[2]+m[1], 16).toString(10); },
        b: '123456/'
        };
        """
    }

    @MainActor func testBrowserFallbackIsOptInAndPersistsSeparatelyFromLegacyPreference() throws {
        let suite = "browser-preference-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "use_in_app_browser")
        let database = try AppDatabase.inMemory()
        let env = AppEnvironment(database: database, browserPreferences: defaults)
        XCTAssertFalse(env.useEmbeddedBrowser)
        env.useEmbeddedBrowser = true
        let restored = AppEnvironment(database: database, browserPreferences: defaults)
        XCTAssertTrue(restored.useEmbeddedBrowser)
        restored.useEmbeddedBrowser = false
        XCTAssertFalse(AppEnvironment(database: database, browserPreferences: defaults).useEmbeddedBrowser)
        XCTAssertTrue(defaults.bool(forKey: "use_in_app_browser"))
    }

    @MainActor func testBrowserRejectsUnsafeNavigationSchemesAndCredentials() {
        for raw in ["https://manga.la/reader/123.html#1", "https://example.com/", "http://example.com/"] {
            XCTAssertTrue(EmbeddedBrowserModel.allows(URL(string: raw)!))
        }
        for raw in ["javascript:alert(1)", "file:///tmp/private", "data:text/html,test", "https://user:password@example.com", "numbermemo://123"] {
            XCTAssertFalse(EmbeddedBrowserModel.allows(URL(string: raw)!))
        }
    }

    func testLocalizationCatalogsAndShareExtensionContainAllKeys() throws {
        let app = Bundle.main
        let extensionURL = try XCTUnwrap(app.builtInPlugInsURL?.appendingPathComponent("ShareExtension.appex"))
        let share = try XCTUnwrap(Bundle(url: extensionURL))
        for bundle in [app, share] {
            XCTAssertEqual(bundle.developmentLocalization, "en")
            var catalogs: [String: [String: String]] = [:]
            for language in ["en", "ko", "ja"] {
                let path = try XCTUnwrap(bundle.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: language))
                let data = try Data(contentsOf: URL(fileURLWithPath: path))
                catalogs[language] = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
                XCTAssertGreaterThan(catalogs[language]!.count, 270)
            }
            let english = try XCTUnwrap(catalogs["en"])
            for language in ["ko", "ja"] {
                XCTAssertEqual(Set(english.keys), Set(catalogs[language]!.keys))
                for (key, value) in catalogs[language]! {
                    XCTAssertFalse(value.isEmpty, key)
                    let pattern = #"%(?:[0-9]+\$)?@"#
                    let regex = try NSRegularExpression(pattern: pattern)
                    func placeholders(_ text: String) -> Int { regex.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text)) }
                    XCTAssertEqual(placeholders(value), placeholders(english[key]!), "\(language): \(key)")
                }
            }
            XCTAssertEqual(catalogs["ja"]?["Explore"], "探索")
            XCTAssertEqual(catalogs["ko"]?["Explore"], "탐색")
            XCTAssertEqual(catalogs["en"]?["Explore"], "Explore")
            let format = try XCTUnwrap(english["Metadata matched! Filled %2$@ of %1$@ saved works."])
            XCTAssertEqual(String(format: format, "20", "3"), "Metadata matched! Filled 3 of 20 saved works.")
        }
        XCTAssertEqual(L10n.folderName("My Folder"), "My Folder")
        XCTAssertEqual(Folder(name: "미분류").displayName, L10n.text("Unfiled"))
        XCTAssertEqual(Folder(name: "미분류").name, "미분류")
    }

    func testSearchVisibilityAccumulatesSlowScrollAndKeepsFocusedSearchVisible() {
        let tracker = ScrollSearchVisibility()
        for y in stride(from: CGFloat(100), through: 128, by: 4) {
            let change = tracker.update(oldY: y, newY: y + 4, focused: false)
            XCTAssertEqual(change, y == 128 ? false : nil)
        }
        XCTAssertNil(tracker.update(oldY: 132, newY: 130, focused: false))
        XCTAssertEqual(tracker.update(oldY: 130, newY: 108, focused: false), true)
        XCTAssertEqual(tracker.update(oldY: 108, newY: 160, focused: true), true)
        XCTAssertEqual(tracker.update(oldY: 160, newY: 0, focused: false), true)
    }

    func testTagCompletionPreservesEarlierTermsAndNamespaces() throws {
        let context = try XCTUnwrap(TagCompletionContext("language:korean  -female:SA"))
        XCTAssertEqual(context.token, "female:sa")
        XCTAssertEqual(context.inserting(TagSuggestion(namespace: "female", name: "sample tag", count: 42)),
                       "language:korean  -female:sample_tag ")
        for input in ["", "a", "female:", "12345", "female:sa ", "https://manga.la/reader/12345.html", "unknown:sa", "female:a:b"] {
            XCTAssertNil(TagCompletionContext(input), input)
        }
    }

    func testSuggestionsParseDeduplicateAndRejectMalformedRows() throws {
        let rows: [[Any]] = [["sample tag", 42, "female"], ["sample tag", 42, "female"],
                             ["sample tag", 12, "male"], ["bad", -1, "tag"], ["bad", 1, "invalid"], ["incomplete"]]
        let suggestions = try TagSuggestion.parse(JSONSerialization.data(withJSONObject: rows))
        XCTAssertEqual(suggestions.map(\.token), ["female:sample_tag", "male:sample_tag"])
        XCTAssertThrowsError(try TagSuggestion.parse(Data("{}".utf8)))
        XCTAssertThrowsError(try TagSuggestion.parse(JSONSerialization.data(withJSONObject: Array(repeating: rows[0], count: 101))))
    }

    func testSuggestionURLMatchesCharacterIndexAndPolicy() throws {
        XCTAssertEqual(try MangaContentSource.suggestionURL("language:KO").absoluteString,
                       "https://tagindex.manga.la/language/k/o.json")
        XCTAssertEqual(try MangaContentSource.suggestionURL("a_b.c").path, "/global/a/_/b/dot/c.json")
        XCTAssertThrowsError(try MangaContentSource.suggestionURL("bad:aa"))
        XCTAssertTrue(ContentTransport.allows(try MangaContentSource.suggestionURL("language:ko")))
        XCTAssertFalse(ContentTransport.allows(URL(string: "https://tagindex.manga.la.evil.example/a")!))
    }

    func testSuggestionCacheAvoidsRepeatedNetworkAndSkipsShortInput() async throws {
        SuggestionFixtureURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SuggestionFixtureURLProtocol.self]
        let source = MangaContentSource(transport: ContentTransport(configuration: config))
        let first = try await source.suggestions(for: "language:ko")
        let second = try await source.suggestions(for: "language:KO")
        let skipped = try await source.suggestions(for: "k")
        XCTAssertEqual(first.map(\.token), ["language:korean"])
        XCTAssertEqual(first, second)
        XCTAssertTrue(skipped.isEmpty)
        XCTAssertEqual(SuggestionFixtureURLProtocol.count, 1)
    }

    func testMonthDestinationsPreserveVisibleOrderAndCounts() {
        let works = [Work(galleryId: 30, bookmarkedAt: "2026-10-04T00:00:00Z"),
                     Work(galleryId: 20, bookmarkedAt: "2026-10-01T00:00:00Z"),
                     Work(galleryId: 10, bookmarkedAt: "2025-12-01T00:00:00Z")]
        let months = WorkMonthDestination.make(works)
        XCTAssertEqual(months.map(\.id), ["2026-10", "2025-12"])
        XCTAssertEqual(months.map(\.firstGalleryID), [30, 10])
        XCTAssertEqual(months.map(\.count), [2, 1])
        XCTAssertEqual(months.last?.title, L10n.text("%@-%@", "2025", "12"))
        XCTAssertTrue(WorkMonthDestination.make([]).isEmpty)
        XCTAssertEqual(WorkMonthDestination.make([works[1]]).first?.firstGalleryID, 20)
    }

    func testGalleryParsesEntitiesAndPreservesPages() throws {
        let json: [String: Any] = ["title": "A &amp; B &#x1F4D6;", "japanese_title": "",
                                  "files": [["hash": sampleHash, "name": "page.png", "width": 800, "height": 1200, "hasavif": 1]]]
        let text = "var galleryinfo = " + String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self) + ";"
        let gallery = try NativeGallery.parse(Data(text.utf8), id: 1234)
        XCTAssertEqual(gallery.title, "A & B 📖")
        XCTAssertEqual(gallery.pages.first?.width, 800)
        XCTAssertEqual(gallery.pages.first?.hasAVIF, true)
        XCTAssertThrowsError(try NativeGallery.parse(Data((text + "doSomething();").utf8), id: 1234))
        XCTAssertThrowsError(try NativeGallery.parse(Data("bad {\"files\":[]}".utf8), id: 1234))
    }

    func testTagNamespacesAcceptStringAndNumericFlags() throws {
        let json: [String: Any] = ["title": "Fixture", "files": [["hash": sampleHash, "name": "page.png"]],
            "tags": [["tag": "cat", "female": "1", "male": ""], ["tag": "dog", "male": 1],
                     ["tag": "bird", "female": true], ["tag": "general", "female": "0"], ["tag": "both", "male": "1", "female": 1]]]
        let data = Data("var galleryinfo = ".utf8) + (try JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(try NativeGallery.parse(data, id: 1).tags, ["female:cat", "male:dog", "female:bird", "tag:general", "female:both", "male:both"])
    }

    func testSpreadsRespectBoundariesAndLastPartialSpread() {
        XCTAssertEqual(ReaderLayout.start(3, count: 2), 2)
        XCTAssertEqual(ReaderLayout.next(0, delta: 1, count: 2, total: 3), 2)
        XCTAssertEqual(ReaderLayout.next(2, delta: 1, count: 2, total: 3), 2)
        XCTAssertEqual(ReaderLayout.next(2, delta: -1, count: 2, total: 3), 0)
        XCTAssertEqual(ReaderLayout.next(0, delta: -1, count: 0, total: 1), 0)
    }

    func testTranslationCropUsesOriginalPixelsAndViewport() async throws {
        let source = FixtureContentSource()
        let gallery = try await source.gallery(1)
        let store = PageImageStore(source: source)
        let image = try await store.translationCrop(gallery.pages[0], galleryID: 1, rect: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        let data = try await source.image(gallery.pages[0], galleryID: 1, thumbnail: false)
        let original = try XCTUnwrap(UIImage(data: data)?.cgImage)
        XCTAssertEqual(image.cgImage?.width, original.width / 2)
        XCTAssertEqual(image.cgImage?.height, original.height / 2)
    }

    func testRoutingUsesCurrentShardAndEpoch() throws {
        let value = try CDNRouting(routing)
        let full = try value.url(hash: sampleHash, format: "webp", thumbnail: false)
        XCTAssertEqual(full.host, "w2.gold-usergeneratedcontent.net")
        XCTAssertEqual(full.path, "/123456/3243/\(sampleHash).webp")
        let thumb = try value.url(hash: sampleHash, format: "webp", thumbnail: true)
        XCTAssertEqual(thumb.host, "btn.gold-usergeneratedcontent.net")
        XCTAssertEqual(thumb.path, "/webpsmalltn/c/ab/\(sampleHash).webp")
        XCTAssertThrowsError(try CDNRouting(routing + "unexpectedCode();"))
        XCTAssertThrowsError(try value.url(hash: "../invalid", format: "webp", thumbnail: false))
    }

    func testRequestPolicyRejectsForeignHostsAndCredentials() {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "manga.site_address")
        defer {
            if let previous { defaults.set(previous, forKey: "manga.site_address") }
            else { defaults.removeObject(forKey: "manga.site_address") }
        }
        defaults.set("custom-comics.example", forKey: "manga.site_address")
        for raw in ["http://w1.gold-usergeneratedcontent.net/a", "https://w1.gold-usergeneratedcontent.net.evil.example/a",
                    "https://user@w1.gold-usergeneratedcontent.net/a", "https://manga.la/", "https://example.com/",
                    "https://custom-comics.example.evil.example/", "https://user@custom-comics.example/", "http://custom-comics.example/"] {
            XCTAssertFalse(ContentTransport.allows(URL(string: raw)!))
        }
        XCTAssertTrue(ContentTransport.allows(URL(string: "https://custom-comics.example/")!))
        XCTAssertTrue(ContentTransport.allows(URL(string: "https://tagindex.custom-comics.example/a")!))
        XCTAssertTrue(ContentTransport.allows(URL(string: "https://a2.gold-usergeneratedcontent.net/a")!))
    }

    func testReaderRoutesUseTrustedHostAndPage() {
        XCTAssertEqual(ContentRoute.initial("https://manga.la/reader/12345.html#7"), .reader(12345, 7))
        XCTAssertEqual(ContentRoute.initial("https://manga.la/artist/a%20b-all.html"), .artist("a b"))
        XCTAssertNil(ContentRoute.initial("https://evil.example/reader/12345.html"))
    }

    func testRangeRequiresExactOffsets() throws {
        let url = URL(string: "https://ltn.gold-usergeneratedcontent.net/index-korean.nozomi")!
        let response = HTTPURLResponse(url: url, statusCode: 206, httpVersion: nil, headerFields: ["Content-Range": "bytes 4-11/100"])!
        XCTAssertEqual(try MangaContentSource.validateRange(response, start: 4, received: 8), 100)
        XCTAssertThrowsError(try MangaContentSource.validateRange(response, start: 0, received: 8))
        XCTAssertThrowsError(try MangaContentSource.validateRange(response, start: 4, received: 7))
    }

    func testBinaryDataRejectsTruncationAndOverflow() throws {
        XCTAssertEqual(try BinaryCursor.ids(Data([0, 0, 4, 0, 0, 0, 8, 0])), [1024, 2048])
        XCTAssertThrowsError(try BinaryCursor.ids(Data([0, 0, 1])))
        XCTAssertThrowsError(try BinaryCursor.ids(Data([0, 0, 0, 0])))
        var reader = BinaryCursor(Data(repeating: 255, count: 8))
        XCTAssertThrowsError(try reader.u64())
        XCTAssertThrowsError(try SearchIndexNode(Data([0, 0, 0, 1])))
    }

    func testBinaryIDsDecodeSlicedDataAndUnsignedValues() throws {
        let sliced = Data([99, 99, 0, 0, 0, 1, 255, 255, 255, 255]).dropFirst(2)
        XCTAssertEqual(try BinaryCursor.ids(sliced), [1, 4_294_967_295])
        XCTAssertEqual(try BinaryCursor.ids(Data()), [])
        let values = Array(1...100_000).map(UInt32.init)
        var data = Data(capacity: values.count * 4)
        for value in values { withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) } }
        XCTAssertEqual(try BinaryCursor.ids(data), values.map(Int64.init))
    }

    func testBoundedImageDecodeAndCache() async throws {
        let fixture = FixtureContentSource()
        let gallery = try await fixture.gallery(900000001)
        let store = PageImageStore(source: fixture)
        let first = try await store.load(gallery.pages[0], galleryID: gallery.id)
        let again = try await store.load(gallery.pages[0], galleryID: gallery.id)
        XCTAssertTrue(first === again)
        XCTAssertLessThanOrEqual(max(first.size.width, first.size.height), 3000)
    }
}

/// Opt in via the NativeContentDeviceValidation scheme. These tests never display or persist content.
final class NativeContentLiveTests: XCTestCase {
    @MainActor func testLiveBrowserLoadsWebsiteWithoutNativeAdapter() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["NUMBER_MEMO_LIVE_TESTS"] == "1")
        let model = EmbeddedBrowserModel(initialUrl: MangaUrls.home)
        model.start()
        for _ in 0..<150 {
            try await Task.sleep(for: .milliseconds(200))
            if model.error != nil || (!model.loading && model.webView.url != nil && !model.title.isEmpty) { break }
        }
        XCTAssertNil(model.error)
        XCTAssertFalse(model.loading)
        XCTAssertEqual(model.webView.url?.host, "manga.la")
        let ready = try await model.webView.evaluateJavaScript("document.readyState") as? String
        XCTAssertEqual(ready, "complete")
        let hasBody = try await model.webView.evaluateJavaScript("document.body != null && document.body.childElementCount > 0") as? Bool
        XCTAssertEqual(hasBody, true)
        model.webView.stopLoading()
    }

    func testLiveTagSuggestionsOnDevice() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["NUMBER_MEMO_LIVE_TESTS"] == "1")
        let suggestions = try await MangaContentSource().suggestions(for: "language:ko")
        XCTAssertTrue(suggestions.contains { $0.token == "language:korean" && $0.count > 0 })
    }

    func testLivePopularPeriodsOnDevice() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["NUMBER_MEMO_LIVE_TESTS"] == "1")
        let source = MangaContentSource()
        for sort in GallerySort.allCases where sort != .latest {
            let batch = try await source.list(GalleryQuery(sort: sort), offset: 0, count: 3)
            XCTAssertEqual(batch.ids.count, 3)
            XCTAssertEqual(Set(batch.ids).count, 3)
        }
        let query = GalleryQuery(language: "all", text: "language:english", sort: .week)
        let result = try await source.list(query, offset: 0, count: 2)
        XCTAssertEqual(result.ids.count, 2)
    }

    func testLiveMetadataImageDecodeAndSearchOnDevice() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["NUMBER_MEMO_LIVE_TESTS"] == "1")
        let source = MangaContentSource()
        let first = try await source.list(GalleryQuery(), offset: 0, count: 2)
        XCTAssertEqual(first.ids.count, 2)
        let next = try await source.list(GalleryQuery(), offset: 2, count: 2)
        XCTAssertTrue(Set(first.ids).isDisjoint(with: next.ids))
        let store = PageImageStore(source: source)
        for id in first.ids {
            let gallery = try await source.gallery(id)
            XCTAssertFalse(gallery.title.isEmpty)
            XCTAssertFalse(gallery.pages.isEmpty)
            for page in [gallery.pages[0], gallery.pages[gallery.pages.count - 1]] {
                let image = try await store.load(page, galleryID: id)
                XCTAssertGreaterThan(image.size.width, 0)
                XCTAssertGreaterThan(image.size.height, 0)
            }
            let thumb = try await store.load(gallery.pages[0], galleryID: id, thumbnail: true)
            XCTAssertGreaterThan(thumb.size.height, 0)
            if gallery.pages[0].hasAVIF {
                let (ggData, _) = try await ContentTransport.shared.get(URL(string: "https://ltn.gold-usergeneratedcontent.net/gg.js")!, limit: 100_000)
                let routing = try CDNRouting(String(decoding: ggData, as: UTF8.self))
                let url = try routing.url(hash: gallery.pages[0].hash, format: "avif", thumbnail: false)
                let (data, _) = try await ContentTransport.shared.get(url, limit: 24_000_000, galleryID: id)
                XCTAssertNotNil(UIImage(data: data), "AVIF must decode on this device")
            }
        }
        // A neutral keyword exercises the B-tree and language intersection, regardless of result count.
        let results = try await source.list(GalleryQuery(language: "korean", text: "test"), offset: 0, count: 2)
        XCTAssertLessThanOrEqual(results.ids.count, 2)
    }
}

private final class SuggestionFixtureURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var requests = 0
    static var count: Int { lock.withLock { requests } }
    static func reset() { lock.withLock { requests = 0 } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.withLock { Self.requests += 1 }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"[["korean",99947,"language"]]"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

extension NativeContentTests {
    func testGalleryHashValidationPreservesLowercaseASCIIAndPageOrder() throws {
        let hash = String(repeating: "0123456789abcdef", count: 4)
        let files = (0..<96).map { ["hash": hash, "name": "\($0).jpg"] }
        let json = try JSONSerialization.data(withJSONObject: ["title": "Pages", "files": files])
        let document = Data("var galleryinfo = ".utf8) + json
        let gallery = try NativeGallery.parse(document, id: 1)
        XCTAssertEqual(gallery.pages.map(\.name), (0..<96).map { "\($0).jpg" })
        XCTAssertTrue(gallery.pages.allSatisfy { $0.hash == hash })
        for invalid in [String(hash.dropLast()), hash + "a", hash.uppercased(),
                        String(repeating: "g", count: 64), String(repeating: "é", count: 32)] {
            let invalidJSON = try JSONSerialization.data(withJSONObject: ["files": [["hash": invalid, "name": "1.jpg"]]])
            XCTAssertThrowsError(try NativeGallery.parse(Data("var galleryinfo = ".utf8) + invalidJSON, id: 1)) { error in
                guard case ContentError.unsupportedFormat = error else { return XCTFail("Unexpected error: \(error)") }
            }
        }
    }

    @MainActor func testCancelledGalleryParsingStopsBeforeDocumentWork() async throws {
        let json = try JSONSerialization.data(withJSONObject: ["files": [["hash": sampleHash, "name": "1.jpg"]]])
        let document = Data("var galleryinfo = ".utf8) + json
        let task = Task { try NativeGallery.parse(document, id: 1) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Canceled metadata must not continue parsing") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testEntityDecoderPreservesUnicodeAndUnknownEntities() {
        XCTAssertEqual(NativeGallery.decodeEntities("제목 📖"), "제목 📖")
        XCTAssertEqual(NativeGallery.decodeEntities("&#x1F4D6; &amp; &#65; &unknown; &#xD800; &amp;lt;"),
                       "📖 & A &unknown; &#xD800; &lt;")
        XCTAssertEqual(NativeGallery.decodeEntities("&quot;&apos;&nbsp;&lt;&gt;"), "\"' <>")
    }

    func testGalleryMetadataConsumersShareOneDownloadAndCachedResult() async throws {
        let fixture = GalleryDocumentFixture()
        defer { fixture.close() }
        let source = fixture.source()
        let first = Task { try await source.gallery(fixture.id) }
        let second = Task { try await source.gallery(fixture.id) }
        try await waitForGalleryCondition { await source.galleryConsumerCount(fixture.id) == 2 && fixture.requestCount == 1 }
        fixture.complete()
        let a = try await first.value, b = try await second.value
        XCTAssertEqual(a.id, b.id)
        XCTAssertEqual(a.title, "Shared metadata")
        XCTAssertEqual(a.pages.count, 1)
        XCTAssertNotNil(source.cachedGallery(fixture.id))
        _ = try await source.gallery(fixture.id)
        XCTAssertEqual(fixture.requestCount, 1, "Concurrent cards and detail views should download and parse metadata once")
    }

    func testCancellingOneGalleryConsumerReturnsWhileAnotherKeepsDownload() async throws {
        let fixture = GalleryDocumentFixture()
        defer { fixture.close() }
        let source = fixture.source()
        let first = Task { try await source.gallery(fixture.id) }
        let second = Task { try await source.gallery(fixture.id) }
        try await waitForGalleryCondition { await source.galleryConsumerCount(fixture.id) == 2 && fixture.requestCount == 1 }
        first.cancel()
        do { _ = try await first.value; XCTFail("Canceled consumer must finish without waiting for the other consumer") }
        catch { XCTAssertTrue(error is CancellationError) }
        let remaining = await source.galleryConsumerCount(fixture.id)
        XCTAssertEqual(remaining, 1)
        XCTAssertEqual(fixture.stoppedCount, 0)
        fixture.complete()
        let result = try await second.value
        XCTAssertEqual(result.id, fixture.id)
        XCTAssertEqual(fixture.requestCount, 1)
    }

    func testCancellingLastGalleryConsumerStopsDownloadAndAllowsRetry() async throws {
        let fixture = GalleryDocumentFixture()
        defer { fixture.close() }
        let source = fixture.source()
        let first = Task { try await source.gallery(fixture.id) }
        try await waitForGalleryCondition { fixture.requestCount == 1 }
        first.cancel()
        do { _ = try await first.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        try await waitForGalleryCondition { fixture.stoppedCount == 1 }
        XCTAssertNil(source.cachedGallery(fixture.id))
        let retry = Task { try await source.gallery(fixture.id) }
        try await waitForGalleryCondition { fixture.requestCount == 2 }
        fixture.complete()
        let result = try await retry.value
        XCTAssertEqual(result.id, fixture.id)
        let remaining = await source.galleryConsumerCount(fixture.id)
        XCTAssertEqual(remaining, 0)
    }

    private func waitForGalleryCondition(_ condition: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for controlled gallery request")
        throw URLError(.timedOut)
    }
}

extension NativeContentTests {
    @MainActor func testLaunchWarmsTenComicCoversOnceAndRetainsNativePagination() async throws {
        let source = LaunchComicSource(data: launchPixel())
        let images = PageImageStore(source: source, diskCapacity: 0)
        let warmup = LaunchFeedWarmup(manga: source, booru: BooruFixtureSource(), images: images)
        let query = GalleryQuery(language: "english", text: "tag:scenery -tag:spoiler")
        await warmup.run(mangaQuery: query, site: "custom.example", servers: [], rating: .all)
        let calls = await source.listCalls, galleries = await source.galleryIDs, thumbnails = await source.thumbnailIDs
        XCTAssertEqual(calls.map(\.offset), [0])
        XCTAssertEqual(calls.map(\.count), [24], "The API page stays intact; only cover speculation is capped")
        XCTAssertEqual(calls.map(\.query), [query])
        XCTAssertEqual(Set(galleries), Set((1...10).map(Int64.init)))
        XCTAssertEqual(Set(thumbnails), Set((1...10).map(Int64.init)))
        let originalLoads = await source.originalImages
        XCTAssertEqual(originalLoads, 0)
        XCTAssertNotNil(images.cachedImage(hash: "launch-1", thumbnail: true))

        let loader = GalleryFeedLoader(source: source, images: images, startup: warmup)
        await loader.load(query, reset: true, useLaunchPage: true, site: "custom.example").value
        XCTAssertEqual(loader.ids, (1...24).map(Int64.init))
        let initialCalls = await source.listCalls
        XCTAssertEqual(initialCalls.count, 1, "The first visible feed must reuse the warmed page")
        await loader.load(query, reset: false).value
        XCTAssertEqual(loader.ids, (1...48).map(Int64.init))
        loader.suspend(); loader.resume()
        await warmup.run(mangaQuery: query, site: "custom.example", servers: [], rating: .all)
        let resumedCalls = await source.listCalls, resumedThumbnails = await source.thumbnailIDs
        XCTAssertEqual(resumedCalls.map(\.offset), [0, 24])
        XCTAssertEqual(resumedThumbnails.count, 10, "Returning from another app must not restart completed warmup")
        XCTAssertEqual(loader.ids.count, 48)
        XCTAssertTrue(loader.didLoad)

        await source.setVersion(1)
        await loader.load(query, reset: true).value
        XCTAssertEqual(loader.ids, (101...124).map(Int64.init), "Pull refresh must fetch fresh results using the remembered site key")
        let refreshedCalls = await source.listCalls
        XCTAssertEqual(refreshedCalls.map(\.offset), [0, 24, 0])
    }

    @MainActor func testCancelledInitialComicConsumerCanReuseWarmPageOnResume() async throws {
        let source = LaunchComicSource(data: launchPixel(), blocked: true)
        let warmup = LaunchFeedWarmup(manga: source, booru: BooruFixtureSource())
        let query = GalleryQuery(), key = LaunchFeedWarmup.MangaKey(site: "manga.la", query: query)
        let cache = warmup.mangaPages
        let background = Task { try await warmup.mangaPage(query: query, site: "manga.la") }
        try await waitForLaunch { await cache.consumerCount(for: key) == 1 }
        let initial = Task { try await warmup.mangaPage(query: query, site: "manga.la", initialConsumer: true) }
        try await waitForLaunch { await cache.consumerCount(for: key) == 2 }
        initial.cancel()
        try await waitForLaunch { await cache.consumerCount(for: key) == 1 }
        await source.unblock()
        _ = try await background.value
        do { _ = try await initial.value; XCTFail("Expected the hidden initial consumer to cancel") }
        catch { XCTAssertTrue(error is CancellationError) }
        let resumed = try await warmup.mangaPage(query: query, site: "manga.la", initialConsumer: true)
        XCTAssertEqual(resumed.ids.count, 24)
        let calls = await source.listCalls
        XCTAssertEqual(calls.count, 1, "Cancellation cannot consume the initial warm-page handoff")
    }

    @MainActor func testSuspendedLaunchStopsQueuedCoversAndResumesWithoutReloadingThePage() async throws {
        let source = LaunchComicSource(data: launchPixel(), blockedImages: true)
        let warmup = LaunchFeedWarmup(manga: source, booru: BooruFixtureSource())
        let query = GalleryQuery()
        let first = Task { await warmup.run(mangaQuery: query, site: "manga.la", servers: [], rating: .all) }
        try await waitForLaunch { await source.thumbnailIDs.count == 2 }
        first.cancel(); await first.value
        let stopped = await source.thumbnailIDs
        XCTAssertEqual(stopped.count, 2, "A canceled launch must not start queued thumbnail work")
        await source.allowImages()
        await warmup.run(mangaQuery: query, site: "manga.la", servers: [], rating: .all)
        let calls = await source.listCalls, thumbnails = await source.thumbnailIDs
        XCTAssertEqual(calls.count, 1, "App activation resumes unfinished covers using the first page already fetched")
        XCTAssertEqual(Set(thumbnails), Set((1...10).map(Int64.init)))
        let completedCount = thumbnails.count
        await warmup.run(mangaQuery: query, site: "manga.la", servers: [], rating: .all)
        let repeated = await source.thumbnailIDs
        XCTAssertEqual(repeated.count, completedCount)
    }

    func testLaunchPageCacheRejectsLateCancelledResultsAfterRefresh() async throws {
        let cache = LaunchPageCache<String, Int>(), source = LaunchValueGate()
        let old = Task { try await cache.value(for: "page") { await source.load() } }
        try await waitForLaunch { await source.requests == 1 }
        await cache.invalidate("page")
        let current = Task { try await cache.value(for: "page") { await source.load() } }
        try await waitForLaunch { await source.requests == 2 }
        await source.release(request: 2, value: 20)
        let currentValue = try await current.value
        XCTAssertEqual(currentValue, 20)
        await source.release(request: 1, value: 10)
        do { _ = try await old.value; XCTFail("Invalidated work must not publish late results") }
        catch { XCTAssertTrue(error is CancellationError) }
        let cached = try await cache.value(for: "page") { await source.load() }
        XCTAssertEqual(cached, 20)
        let requests = await source.requests
        XCTAssertEqual(requests, 2)
    }

    @MainActor func testEmptyComicFeedRemainsLoadedAcrossSuspension() async {
        let source = LaunchComicSource(data: launchPixel(), empty: true)
        let loader = GalleryFeedLoader(source: source)
        await loader.load(GalleryQuery(), reset: true).value
        loader.suspend(); loader.resume()
        XCTAssertTrue(loader.didLoad, "A completed empty feed must be distinguishable from a canceled initial request")
        XCTAssertTrue(loader.ids.isEmpty)
        XCTAssertFalse(loader.hasMore)
        let calls = await source.listCalls
        XCTAssertEqual(calls.count, 1)
    }

    @MainActor private func launchPixel() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }.pngData()!
    }
    private func waitForLaunch(_ condition: @Sendable () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for launch fixture")
        throw URLError(.timedOut)
    }
}

private actor LaunchComicSource: ContentProviding {
    struct ListCall: Sendable { let query: GalleryQuery; let offset: Int; let count: Int }
    private let data: Data
    private let empty: Bool
    private var blocked: Bool
    private var blockedImages: Bool
    private var version = 0
    private(set) var listCalls: [ListCall] = []
    private(set) var galleryIDs: [Int64] = []
    private(set) var thumbnailIDs: [Int64] = []
    private(set) var originalImages = 0
    init(data: Data, blocked: Bool = false, empty: Bool = false, blockedImages: Bool = false) {
        self.data = data; self.blocked = blocked; self.empty = empty; self.blockedImages = blockedImages
    }
    func unblock() { blocked = false }
    func allowImages() { blockedImages = false }
    func setVersion(_ value: Int) { version = value }
    func list(_ query: GalleryQuery, offset: Int, count: Int) async throws -> GalleryBatch {
        listCalls.append(.init(query: query, offset: offset, count: count))
        while blocked { try await Task.sleep(for: .milliseconds(5)) }
        return GalleryBatch(ids: empty ? [] : (1...count).map { Int64(version * 100 + offset + $0) }, hasMore: !empty)
    }
    func gallery(_ id: Int64) async throws -> NativeGallery {
        galleryIDs.append(id)
        return .init(id: id, title: "Launch \(id)", artists: [], language: "english", type: "manga", tags: [],
                     pages: [.init(hash: "launch-\(id)", name: "1.png", width: 8, height: 8, hasAVIF: false)])
    }
    func image(_ page: GalleryPage, galleryID: Int64, thumbnail: Bool) async throws -> Data {
        if thumbnail { thumbnailIDs.append(galleryID) } else { originalImages += 1 }
        while blockedImages { try await Task.sleep(for: .milliseconds(5)) }
        try await Task.sleep(for: .milliseconds(5))
        return data
    }
    func suggestions(for token: String) async throws -> [TagSuggestion] { [] }
}

private actor LaunchValueGate {
    private(set) var requests = 0
    private var continuations: [Int: CheckedContinuation<Int, Never>] = [:]
    func load() async -> Int {
        requests += 1
        let request = requests
        return await withCheckedContinuation { continuations[request] = $0 }
    }
    func release(request: Int, value: Int) { continuations.removeValue(forKey: request)?.resume(returning: value) }
}

private final class GalleryDocumentFixture: @unchecked Sendable {
    let id = Int64.random(in: 10_000_000...9_000_000_000)
    private let lock = NSLock()
    private var pending: [GalleryDocumentURLProtocol] = []
    private var requests = 0
    private var stopped = 0
    var requestCount: Int { lock.withLock { requests } }
    var stoppedCount: Int { lock.withLock { stopped } }

    init() { GalleryDocumentURLProtocol.register(self) }
    func source() -> MangaContentSource {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GalleryDocumentURLProtocol.self]
        return MangaContentSource(transport: ContentTransport(configuration: configuration))
    }
    func begin(_ request: GalleryDocumentURLProtocol) {
        lock.withLock { pending.append(request); requests += 1 }
    }
    func stop(_ request: GalleryDocumentURLProtocol) {
        lock.withLock {
            if pending.contains(where: { $0 === request }) { stopped += 1 }
            pending.removeAll { $0 === request }
        }
    }
    func complete() {
        let requests = lock.withLock { let copy = pending; pending.removeAll(); return copy }
        let data = Data(("var galleryinfo = {\"title\":\"Shared metadata\",\"files\":[{\"hash\":\"" + String(repeating: "a", count: 64) + "\",\"name\":\"1.jpg\",\"width\":100,\"height\":150}]};").utf8)
        for request in requests { request.complete(data) }
    }
    func close() {
        let requests = lock.withLock { let copy = pending; pending.removeAll(); return copy }
        for request in requests { request.fail() }
        GalleryDocumentURLProtocol.unregister(id)
    }
}

private final class GalleryDocumentURLProtocol: URLProtocol {
    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var registry: [Int64: GalleryDocumentFixture] = [:]
    private var fixture: GalleryDocumentFixture?
    static func register(_ fixture: GalleryDocumentFixture) { registryLock.withLock { registry[fixture.id] = fixture } }
    static func unregister(_ id: Int64) { registryLock.withLock { _ = registry.removeValue(forKey: id) } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let id = request.url.flatMap { Int64($0.deletingPathExtension().lastPathComponent) }
        fixture = Self.registryLock.withLock { id.flatMap { Self.registry[$0] } }
        guard let fixture else { fail(); return }
        fixture.begin(self)
    }
    override func stopLoading() { fixture?.stop(self) }
    func complete(_ data: Data) {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/javascript"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    func fail() { client?.urlProtocol(self, didFailWithError: URLError(.cancelled)) }
}
