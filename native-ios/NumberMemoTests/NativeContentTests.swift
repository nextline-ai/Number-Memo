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
        for raw in ["https://hitomi.la/reader/123.html#1", "https://example.com/", "http://example.com/"] {
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
        for input in ["", "a", "female:", "12345", "female:sa ", "https://hitomi.la/reader/12345.html", "unknown:sa", "female:a:b"] {
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
        XCTAssertEqual(try HitomiContentSource.suggestionURL("language:KO").absoluteString,
                       "https://tagindex.hitomi.la/language/k/o.json")
        XCTAssertEqual(try HitomiContentSource.suggestionURL("a_b.c").path, "/global/a/_/b/dot/c.json")
        XCTAssertThrowsError(try HitomiContentSource.suggestionURL("bad:aa"))
        XCTAssertTrue(ContentTransport.allows(try HitomiContentSource.suggestionURL("language:ko")))
        XCTAssertFalse(ContentTransport.allows(URL(string: "https://tagindex.hitomi.la.evil.example/a")!))
    }

    func testSuggestionCacheAvoidsRepeatedNetworkAndSkipsShortInput() async throws {
        SuggestionFixtureURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SuggestionFixtureURLProtocol.self]
        let source = HitomiContentSource(transport: ContentTransport(configuration: config))
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
        for raw in ["http://w1.gold-usergeneratedcontent.net/a", "https://w1.gold-usergeneratedcontent.net.evil.example/a",
                    "https://user@w1.gold-usergeneratedcontent.net/a", "https://hitomi.la/", "https://example.com/"] {
            XCTAssertFalse(ContentTransport.allows(URL(string: raw)!))
        }
        XCTAssertTrue(ContentTransport.allows(URL(string: "https://a2.gold-usergeneratedcontent.net/a")!))
    }

    func testReaderRoutesUseTrustedHostAndPage() {
        XCTAssertEqual(ContentRoute.initial("https://hitomi.la/reader/12345.html#7"), .reader(12345, 7))
        XCTAssertEqual(ContentRoute.initial("https://hitomi.la/artist/a%20b-all.html"), .artist("a b"))
        XCTAssertNil(ContentRoute.initial("https://evil.example/reader/12345.html"))
    }

    func testRangeRequiresExactOffsets() throws {
        let url = URL(string: "https://ltn.gold-usergeneratedcontent.net/index-korean.nozomi")!
        let response = HTTPURLResponse(url: url, statusCode: 206, httpVersion: nil, headerFields: ["Content-Range": "bytes 4-11/100"])!
        XCTAssertEqual(try HitomiContentSource.validateRange(response, start: 4, received: 8), 100)
        XCTAssertThrowsError(try HitomiContentSource.validateRange(response, start: 0, received: 8))
        XCTAssertThrowsError(try HitomiContentSource.validateRange(response, start: 4, received: 7))
    }

    func testBinaryDataRejectsTruncationAndOverflow() throws {
        XCTAssertEqual(try BinaryCursor.ids(Data([0, 0, 4, 0, 0, 0, 8, 0])), [1024, 2048])
        XCTAssertThrowsError(try BinaryCursor.ids(Data([0, 0, 1])))
        XCTAssertThrowsError(try BinaryCursor.ids(Data([0, 0, 0, 0])))
        var reader = BinaryCursor(Data(repeating: 255, count: 8))
        XCTAssertThrowsError(try reader.u64())
        XCTAssertThrowsError(try SearchIndexNode(Data([0, 0, 0, 1])))
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
        let model = EmbeddedBrowserModel(initialUrl: HitomiUrls.home)
        model.start()
        for _ in 0..<150 {
            try await Task.sleep(for: .milliseconds(200))
            if model.error != nil || (!model.loading && model.webView.url != nil && !model.title.isEmpty) { break }
        }
        XCTAssertNil(model.error)
        XCTAssertFalse(model.loading)
        XCTAssertEqual(model.webView.url?.host, "hitomi.la")
        let ready = try await model.webView.evaluateJavaScript("document.readyState") as? String
        XCTAssertEqual(ready, "complete")
        let hasBody = try await model.webView.evaluateJavaScript("document.body != null && document.body.childElementCount > 0") as? Bool
        XCTAssertEqual(hasBody, true)
        model.webView.stopLoading()
    }

    func testLiveTagSuggestionsOnDevice() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["NUMBER_MEMO_LIVE_TESTS"] == "1")
        let suggestions = try await HitomiContentSource().suggestions(for: "language:ko")
        XCTAssertTrue(suggestions.contains { $0.token == "language:korean" && $0.count > 0 })
    }

    func testLivePopularPeriodsOnDevice() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["NUMBER_MEMO_LIVE_TESTS"] == "1")
        let source = HitomiContentSource()
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
        let source = HitomiContentSource()
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
