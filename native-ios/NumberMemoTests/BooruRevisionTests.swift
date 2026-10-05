import XCTest
import WebKit
@testable import NumberMemo

final class BooruRevisionTests: XCTestCase {
    private let legacy = BooruServer(id: "legacy", name: "Legacy", baseURL: URL(string: "https://example.booru.org")!, engine: .oldGelbooru)

    func testDanbooruPublicPoolListParsesNamesCountsAndIgnoresPagination() throws {
        let data = Data("""
        <html><div id="c-pools"><table><tr><th>Name</th><th>Count</th></tr>
        <tr><td><span><a href="/pools/42">Sky &amp; Sea</a></span><a href="/pools/42?page=2">page 2</a></td><td>1,234</td></tr>
        <tr><td><a href="/pools/77">Clouds</a></td><td>18</td></tr></table>
        <a href="/pools?page=2">Next</a></div></html>
        """.utf8)
        let pools = try BooruHTML.danbooruPools(data)
        XCTAssertEqual(pools.map(\.id), [42, 77])
        XCTAssertEqual(pools.first?.name, "Sky & Sea")
        XCTAssertEqual(pools.first?.count, 1234)
        XCTAssertTrue(try BooruHTML.danbooruPools(Data("<html><div id='c-pools'><table></table></div></html>".utf8)).isEmpty)
        XCTAssertThrowsError(try BooruHTML.danbooruPools(Data("<html>Login required</html>".utf8)))
    }

    func testConnectionRetriesExcludeAuthenticationChallengesAndCancellation() {
        XCTAssertTrue(BooruConnectionRetry.isTransient(URLError(.networkConnectionLost)))
        XCTAssertTrue(BooruConnectionRetry.isTransient(URLError(.secureConnectionFailed)))
        XCTAssertFalse(BooruConnectionRetry.isTransient(URLError(.cancelled)))
        XCTAssertFalse(BooruConnectionRetry.isTransient(URLError(.serverCertificateUntrusted)))
        XCTAssertFalse(BooruConnectionRetry.isTransient(BooruError.validationRequired))
        XCTAssertFalse(BooruConnectionRetry.isTransient(BooruError.authentication))
    }

    func testFreshInstallHasNoServers() throws {
        let store = try BooruStore()
        XCTAssertTrue(store.servers.isEmpty)
        XCTAssertTrue(store.selectedServerIDs.isEmpty)
    }

    func testServerRecognitionDoesNotSuggestUnknownOrLookalikeHosts() throws {
        for (address, engine) in [("safebooru.org", BooruEngine.gelbooru), ("danbooru.donmai.us", .danbooru), ("sample.booru.org", .oldGelbooru), ("yande.re", .moebooru)] {
            XCTAssertEqual(BooruEngine.suggested(for: try BooruServer.validatedURL(address)), engine)
        }
        XCTAssertNil(BooruEngine.suggested(for: try BooruServer.validatedURL("safebooru.org.example.com")))
        XCTAssertNil(BooruEngine.suggested(for: try BooruServer.validatedURL("my-images.example.com")))
    }

    func testExistingServersAndFavoritesSurviveReopenAndEmptyLibraryStaysEmpty() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let server = BooruServer.presets[2]
        let post = BooruFixtureSource.post(101, server: server)
        do {
            let store = try BooruStore(path: url.path)
            XCTAssertTrue(store.servers.isEmpty)
            try store.saveServer(server)
            try store.saveFavorite(post)
        }
        do {
            let restored = try BooruStore(path: url.path)
            XCTAssertEqual(restored.servers, [server])
            XCTAssertTrue(restored.isFavorite(post))
            try restored.deleteServer(server)
        }
        let empty = try BooruStore(path: url.path)
        XCTAssertTrue(empty.servers.isEmpty)
        XCTAssertTrue(empty.selectedServerIDs.isEmpty)
    }

    func testReplayingSetupDoesNotRemoveAnExistingConnectionOnATypo() throws {
        let name = "onboarding-test-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { preferences.removePersistentDomain(forName: name) }
        let env = AppEnvironment(database: try AppDatabase.inMemory(), browserPreferences: preferences)
        XCTAssertFalse(env.verifySite(input: "incorrect.invalid"))
        XCTAssertFalse(env.isSiteVerified)
        XCTAssertTrue(env.verifySite(input: "hitomi.la"))
        XCTAssertFalse(env.verifySite(input: "incorrect.invalid"))
        XCTAssertTrue(env.isSiteVerified)
    }

    func testLegacyHTMLListingDetailTagsAndNotes() throws {
        let listing = Data("""
        <html><body>Running Gelbooru Beta 0.1.11
        <span class="thumb"><a id="p42" href="index.php?page=post&amp;s=view&amp;id=42"><img src="http://img.booru.org/thumbnails/1/thumbnail_hash.jpg" title="scenery blue_sky score:12 rating:safe"/></a></span>
        <span class="thumb"><a id="p42"><img src="https://img.booru.org/duplicate.jpg"/></a></span>
        </body></html>
        """.utf8)
        let posts = try BooruLegacyHTML.posts(listing, server: legacy)
        XCTAssertEqual(posts.count, 1)
        XCTAssertEqual(posts[0].tags, ["scenery", "blue_sky"])
        XCTAssertEqual(posts[0].score, 12)
        XCTAssertEqual(posts[0].previewURL?.scheme, "https")
        XCTAssertNil(posts[0].fileURL, "Do not guess original formats from thumbnails")
        let details = Data("""
        <html><body>Size: 1600x1200 <br>Rating: Safe<br>Score: <span>12</span>
        <img alt="img" src="http://img.booru.org/images/1/hash.png" onclick="Note.toggle();"/>
        <textarea id="tags" name="tags">scenery blue_sky artist_a</textarea>
        <li class="artist-tag"><a href="?tags=artist_a">artist_a</a> <small>34</small></li>
        <div id="note-box-5" style="left: 10px; top: 20px; width: 100px; height: 50px"></div>
        <div id="note-body-5">Hello &amp; world</div></body></html>
        """.utf8)
        let post = try BooruLegacyHTML.post(details, server: legacy, id: 42, preview: posts[0].previewURL)
        XCTAssertEqual(post.fileExtension, "png")
        XCTAssertEqual(post.width, 1600)
        XCTAssertEqual(post.height, 1200)
        XCTAssertEqual(post.artists, ["artist_a"])
        XCTAssertEqual(post.fileURL?.scheme, "https")
        XCTAssertEqual(try BooruLegacyHTML.notes(details).first?.body, "Hello & world")
        XCTAssertEqual(try BooruLegacyHTML.notes(details).first?.width, 100)
        XCTAssertThrowsError(try BooruLegacyHTML.posts(Data("<html>Just a moment...</html>".utf8), server: legacy))
    }

    func testRatingDisabledLeavesLegacyQueryAndUnratedPostsIntact() throws {
        XCTAssertEqual(BooruRating.all.query("", server: legacy), "")
        XCTAssertEqual(legacy.browsingURL(query: "").query, "page=post&s=list")
        XCTAssertEqual(BooruRating.all.query("scenery", server: legacy), "scenery")
        XCTAssertEqual(BooruRating.general.query("scenery", server: legacy), "scenery rating:safe")
        XCTAssertEqual(BooruRating.general.query("scenery", server: BooruServer.presets[0]), "scenery rating:general")
        XCTAssertEqual(try BooruDecoder.post(["id": 1, "rating": "s"], server: BooruServer.presets[1]).rating, "s")
        let data = Data("<html><a id='p7'><img src='/preview.jpg' title='scenery'></a></html>".utf8)
        let posts = try BooruLegacyHTML.posts(data, server: legacy)
        XCTAssertEqual(posts.count, 1); XCTAssertEqual(posts[0].rating, "")
        XCTAssertFalse(BooruBlacklist("").contains(posts[0]))
    }

    func testModernGelbooruMarkupWithoutAnchorIDAndLazyImage() throws {
        let html = Data("""
        <html><article class="thumbnail-preview"><a href="index.php?page=post&amp;s=view&amp;id=123"><picture><img src="/loading.png" data-original="/thumb.jpg" title="landscape"></picture></a></article>
        <script>posts[123] = {'rating':'general', 'score':42, 'user':'fixture'};</script></html>
        """.utf8)
        let posts = try BooruLegacyHTML.posts(html, server: BooruServer.presets[1])
        XCTAssertEqual(posts.count, 1); XCTAssertEqual(posts[0].postID, 123)
        XCTAssertEqual(posts[0].previewURL?.path, "/thumb.jpg")
        XCTAssertEqual(posts[0].score, 42); XCTAssertEqual(posts[0].rating, "g")
    }

    func testPaginationKeepsTheServerLinkAndRejectsOtherOrigins() throws {
        let html = Data("""
        <html><a href="https://elsewhere.invalid/?s=list&amp;pid=10">Other</a>
        <a href="?page=post&amp;s=list&amp;tags=all&amp;pid=20&amp;cursor=fixture">Next</a></html>
        """.utf8)
        let url = try XCTUnwrap(BooruLegacyHTML.nextPageURL(html, server: legacy, after: 0))
        XCTAssertEqual(url.host, legacy.baseURL.host)
        XCTAssertEqual(url.path, "/index.php")
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.last?.value, "fixture")
    }

    func testBrowserRoutesUsePublicPagesAndPreserveSearch() {
        for server in BooruServer.presets + [legacy] {
            let url = server.browsingURL(query: "landscape -rain")
            XCTAssertTrue(BooruWebTransport.sameOrigin(url, server.baseURL))
            XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "tags" }?.value, "landscape -rain")
            XCTAssertFalse(url.absoluteString.contains("dapi"))
            XCTAssertFalse(server.browsingURL(query: "", poolID: 77).absoluteString.contains("tags="))
        }
    }

    func testPopularSortUsesEachEngineSyntaxAndRetainsUserTags() {
        XCTAssertEqual(BooruSort.popular.query("scenery -spoilers", engine: .danbooru), "scenery -spoilers order:score")
        XCTAssertEqual(BooruSort.popular.query("scenery order:id", engine: .gelbooru), "scenery sort:score:desc")
        XCTAssertEqual(BooruSort.popular.query("scenery", engine: .oldGelbooru), "scenery order:score")
        XCTAssertEqual(BooruSort.latest.query("scenery order:id", engine: .moebooru), "scenery order:id")
    }

    func testAppLanguagePersistsWithoutChangingSystemTranslationLanguage() throws {
        let name = "language-test-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: name))
        let previous = L10n.appLanguage
        defer { preferences.removePersistentDomain(forName: name); L10n.appLanguage = previous }
        let system = L10n.systemLanguage
        let env = AppEnvironment(database: try AppDatabase.inMemory(), browserPreferences: preferences)
        XCTAssertEqual(env.appLanguage, "system")
        env.appLanguage = "ja"
        XCTAssertEqual(L10n.text("Saved"), "保存")
        XCTAssertEqual(ReaderTranslationLanguage.resolved("system"), system)
        XCTAssertEqual(ReaderTranslationLanguage.resolved("ko"), "ko")
        XCTAssertEqual(AppEnvironment(database: env.database, browserPreferences: preferences).appLanguage, "ja")
        env.appLanguage = "ko"
        XCTAssertEqual(L10n.text("Saved"), "저장")
    }

    func testBrowserTransportOriginBoundaryAndChallengeDetection() throws {
        let root = URL(string: "https://example.com")!
        XCTAssertTrue(BooruWebTransport.sameOrigin(URL(string: "https://example.com:443/posts.json")!, root))
        for url in ["http://example.com", "https://example.com:444", "https://elsewhere.com", "https://user:secret@example.com"] {
            XCTAssertFalse(BooruWebTransport.sameOrigin(URL(string: url)!, root))
        }
        let response = try XCTUnwrap(HTTPURLResponse(url: root, statusCode: 200, httpVersion: nil, headerFields: nil))
        XCTAssertTrue(BooruClient.needsBrowser(Data("<html>Just a moment...</html>".utf8), response: response))
        XCTAssertFalse(BooruClient.needsBrowser(Data("[]".utf8), response: response))
    }

    @MainActor func testValidatedBrowserIsReusedAndRequestsRunInIsolatedWorld() async throws {
        let server = BooruServer(id: UUID().uuidString, name: "Fixture", baseURL: URL(string: "https://example.com")!, engine: .danbooru)
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let web = BusyBooruTestWebView(frame: .zero, configuration: config)
        web.loadHTMLString("<html><body>Validated fixture</body></html>", baseURL: server.baseURL)
        for _ in 0..<100 where web.isLoading || web.url == nil { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(web.url?.host, server.baseURL.host)
        // Only the isolated test world returns this response; a fresh browser cannot do so.
        _ = try await web.callAsyncJavaScript("globalThis.fetch = () => { throw new Error('page-world fetch must not run'); }; return true;", arguments: [:], in: nil, contentWorld: .page)
        _ = try await web.callAsyncJavaScript("""
            globalThis.fetch = async (url, options) => new Response(JSON.stringify({
                reused: true, cookies: options.credentials, redirect: options.redirect,
                authorized: options.headers.Authorization === 'Basic fixture'
            }), {status: 200});
            return true;
            """, arguments: [:], in: nil, contentWorld: .defaultClient)
        web.pretendSubresourcesAreLoading = true
        BooruWebTransport.adopt(web, server: server)
        XCTAssertTrue(BooruWebTransport.hasSession(for: server))
        var request = URLRequest(url: server.baseURL.appendingPathComponent("posts.json"))
        request.setValue("Basic fixture", forHTTPHeaderField: "Authorization")
        let (data, response) = try await BooruWebTransport.data(for: request, server: server)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(json["reused"] as? Bool, true)
        XCTAssertEqual(json["authorized"] as? Bool, true)
        XCTAssertEqual(json["cookies"] as? String, "include")
        XCTAssertEqual(json["redirect"] as? String, "error")
        BooruWebTransport.reset(server)
        XCTAssertFalse(BooruWebTransport.hasSession(for: server))
    }

    @MainActor func testLiveSafebooruThroughBrowserTransport() async throws {
        guard ProcessInfo.processInfo.environment["NUMBER_MEMO_BOORU_LIVE_TESTS"] == "1" else { throw XCTSkip("Opt-in network test") }
        let server = BooruServer.presets[2]
        defer { BooruWebTransport.reset(server) }
        let request = try BooruClient.request(server: server, path: "index.php", items: [
            .init(name: "page", value: "dapi"), .init(name: "s", value: "post"), .init(name: "q", value: "index"),
            .init(name: "json", value: "1"), .init(name: "tags", value: "landscape"), .init(name: "limit", value: "2")])
        let (data, response) = try await BooruWebTransport.data(for: request, server: server)
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertFalse(try BooruDecoder.rows(data, key: "post").isEmpty)
    }

    @MainActor func testLiveLegacyVisibleBrowserListings() async throws {
        guard ProcessInfo.processInfo.environment["NUMBER_MEMO_BOORU_LIVE_TESTS"] == "1",
              let addresses = ProcessInfo.processInfo.environment["NUMBER_MEMO_LEGACY_SERVERS"], addresses.hasPrefix("https://") else {
            throw XCTSkip("Opt-in legacy server addresses required")
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = try XCTUnwrap(scene.windows.first)
        for (index, address) in addresses.split(separator: ",").enumerated() {
            let server = BooruServer(id: UUID().uuidString, name: "Legacy verification", baseURL: try BooruServer.validatedURL(String(address)), engine: .oldGelbooru)
            let model = BooruValidationModel(server: server)
            model.webView.frame = window.bounds; window.addSubview(model.webView)
            defer { model.webView.removeFromSuperview(); BooruWebTransport.reset(server) }
            model.load(server.browsingURL(query: ""))
            for _ in 0..<200 where model.loading { try await Task.sleep(for: .milliseconds(100)) }
            try await Task.sleep(for: .seconds(2))
            BooruWebTransport.adopt(model.webView, server: server)
            let request = URLRequest(url: server.browsingURL(query: ""))
            let (data, response) = try await BooruWebTransport.document(for: request, server: server)
            XCTAssertEqual(response.statusCode, 200, "Legacy server index \(index)")
            let posts = try BooruLegacyHTML.posts(data, server: server)
            XCTAssertFalse(posts.isEmpty, "Legacy server index \(index)")
            let first = try XCTUnwrap(posts.first)
            XCTAssertNotNil(first.previewURL)
            let detail = try await BooruClient.shared.details(server: server, post: first)
            XCTAssertNotNil(detail.fileURL)
            XCTAssertFalse(detail.tags.isEmpty)
        }
    }

    @MainActor func testLiveLegacyTagSearchOrInteractiveValidationRoute() async throws {
        guard ProcessInfo.processInfo.environment["NUMBER_MEMO_BOORU_LIVE_TESTS"] == "1",
              let address = ProcessInfo.processInfo.environment["NUMBER_MEMO_LEGACY_SERVERS"]?.split(separator: ",").first,
              address.hasPrefix("https://") else { throw XCTSkip("Opt-in legacy server address required") }
        let server = BooruServer(id: UUID().uuidString, name: "Legacy verification", baseURL: try BooruServer.validatedURL(String(address)), engine: .oldGelbooru)
        defer { BooruWebTransport.reset(server) }
        let batch = try await BooruClient.shared.posts(server: server, query: "", page: 0)
        let first = try XCTUnwrap(batch.posts.first)
        let detail = try await BooruClient.shared.details(server: server, post: first)
        let tag = try XCTUnwrap(detail.tags.first)
        do {
            let result = try await BooruClient.shared.posts(server: server, query: tag, page: 0)
            XCTAssertFalse(result.posts.isEmpty)
        } catch BooruError.validationRequired {
            let target = try XCTUnwrap(BooruBrowserSession.challengePage(for: server))
            XCTAssertTrue(URLComponents(url: target, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "tags" }?.value == tag)
            XCTAssertTrue(BooruValidationView(server: server).initialURL == target)
            throw XCTSkip("The site requires interactive verification for this tag search; verified that Validate Client opens the exact challenged search")
        }
    }

    func testLiveOldGelbooruServersWhenConfigured() async throws {
        guard ProcessInfo.processInfo.environment["NUMBER_MEMO_BOORU_LIVE_TESTS"] == "1",
              let value = ProcessInfo.processInfo.environment["NUMBER_MEMO_LEGACY_SERVERS"], value.hasPrefix("https://") else {
            throw XCTSkip("Opt-in legacy server addresses required")
        }
        for address in value.split(separator: ",") {
            let server = BooruServer(id: UUID().uuidString, name: "Legacy verification", baseURL: try BooruServer.validatedURL(String(address)), engine: .oldGelbooru)
            let batch: BooruBatch
            do { batch = try await BooruClient.shared.posts(server: server, query: "", page: 0) }
            catch BooruError.validationRequired {
                await BooruWebTransport.reset(server)
                throw XCTSkip("This legacy server requires interactive browser verification before its public gallery is available")
            } catch let error as URLError {
                await BooruWebTransport.reset(server)
                throw XCTSkip("The configured legacy server is unreachable on this device network (\(error.code.rawValue))")
            }
            XCTAssertFalse(batch.posts.isEmpty)
            let post = try XCTUnwrap(batch.posts.first)
            XCTAssertNotNil(post.previewURL)
            let detail = try await BooruClient.shared.details(server: server, post: post)
            XCTAssertNotNil(detail.fileURL)
            XCTAssertGreaterThan(detail.width, 0)
            XCTAssertFalse(detail.tags.isEmpty)
            if batch.hasMore {
                // Public sites may throttle a fresh profile's pagination separately.
                try await Task.sleep(for: .seconds(2))
                do {
                    let next = try await BooruClient.shared.posts(server: server, query: "", page: 1)
                    XCTAssertFalse(next.posts.isEmpty)
                    XCTAssertTrue(Set(batch.posts.map(\.postID)).isDisjoint(with: next.posts.map(\.postID)))
                } catch BooruError.rateLimited {
                    await BooruWebTransport.reset(server)
                    throw XCTSkip("Legacy pagination is rate-limited by the server; stop requests rather than retrying the limit")
                } catch BooruError.validationRequired {
                    await BooruWebTransport.reset(server)
                    throw XCTSkip("Legacy pagination requires interactive browser verification on the requested page")
                }
            }
            await BooruWebTransport.reset(server)
        }
    }
}

private final class BusyBooruTestWebView: WKWebView {
    var pretendSubresourcesAreLoading = false
    override var isLoading: Bool { pretendSubresourcesAreLoading || super.isLoading }
}
