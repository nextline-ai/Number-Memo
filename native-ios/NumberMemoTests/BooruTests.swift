import XCTest
@testable import NumberMemo

final class BooruTests: XCTestCase {
    func testMediaRedirectsDropCredentialsWhileAPIRedirectsStayScoped() throws {
        let original = URL(string: "https://example.com/image")!
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: original)
        let response = try XCTUnwrap(HTTPURLResponse(url: original, statusCode: 302, httpVersion: nil, headerFields: nil))
        var redirected = URLRequest(url: URL(string: "https://cdn.example.net/image")!)
        redirected.setValue("clearance=private", forHTTPHeaderField: "Cookie")
        redirected.setValue("Basic private", forHTTPHeaderField: "Authorization")
        BooruRedirectPolicy().urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: redirected) { XCTAssertNil($0) }
        BooruRedirectPolicy(publicMedia: true).urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: redirected) {
            XCTAssertEqual($0?.url, redirected.url)
            XCTAssertNil($0?.value(forHTTPHeaderField: "Cookie"))
            XCTAssertNil($0?.value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual($0?.httpShouldHandleCookies, false)
        }
        redirected.url = URL(string: "http://cdn.example.net/image")!
        BooruRedirectPolicy(publicMedia: true).urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: redirected) { XCTAssertNil($0) }
    }

    func testCookieScopeAndProfileIsolation() throws {
        let cookie = try XCTUnwrap(HTTPCookie(properties: [.name: "clearance", .value: "fixture", .domain: ".example.com", .path: "/api", .secure: "TRUE"]))
        XCTAssertTrue(BooruBrowserSession.matches(cookie, url: URL(string: "https://sub.example.com/api/posts")!))
        XCTAssertFalse(BooruBrowserSession.matches(cookie, url: URL(string: "https://example.com/apiculture")!))
        XCTAssertFalse(BooruBrowserSession.matches(cookie, url: URL(string: "https://notexample.com/api")!))
        XCTAssertFalse(BooruBrowserSession.matches(cookie, url: URL(string: "http://example.com/api")!))
        XCTAssertFalse(BooruBrowserSession.matches(cookie, url: URL(string: "https://example.com.evil.test/api")!))
        XCTAssertEqual(BooruBrowserSession.identifier("danbooru"), BooruBrowserSession.identifier("danbooru"))
        XCTAssertNotEqual(BooruBrowserSession.identifier("danbooru"), BooruBrowserSession.identifier("gelbooru"))
    }

    @MainActor func testValidationCookiesReachOnlyTheirServerAndReset() async throws {
        let a = BooruServer(id: UUID().uuidString, name: "A", baseURL: URL(string: "https://example.com")!, engine: .danbooru)
        let b = BooruServer(id: UUID().uuidString, name: "B", baseURL: a.baseURL, engine: .danbooru)
        let cookie = try XCTUnwrap(HTTPCookie(properties: [.name: "clearance", .value: "fixture", .domain: "example.com", .path: "/", .secure: "TRUE"]))
        await BooruBrowserSession.dataStore(for: a).httpCookieStore.setCookie(cookie)
        let request = URLRequest(url: a.baseURL.appendingPathComponent("posts.json"))
        let authorized = await BooruBrowserSession.prepare(request, server: a)
        let isolated = await BooruBrowserSession.prepare(request, server: b)
        XCTAssertEqual(authorized.value(forHTTPHeaderField: "Cookie"), "clearance=fixture")
        XCTAssertNil(isolated.value(forHTTPHeaderField: "Cookie"))
        let nativeAgent = await BooruBrowserSession.nativeUserAgent()
        XCTAssertEqual(authorized.value(forHTTPHeaderField: "User-Agent"), nativeAgent)
        await BooruBrowserSession.reset(a)
        let reset = await BooruBrowserSession.prepare(request, server: a)
        XCTAssertNil(reset.value(forHTTPHeaderField: "Cookie"))
    }

    private var dan: BooruServer { .init(id: "test-dan", name: "Test", baseURL: URL(string: "https://example.com/booru")!, engine: .danbooru) }
    private func sample(_ server: BooruServer? = nil, tags: [String] = ["scenery", "mountain"]) -> BooruPost {
        BooruFixtureSource.post(101, server: server ?? dan, tags: tags)
    }

    func testServerValidationNormalizesAndRejectsUnsafeURLs() throws {
        XCTAssertEqual(try BooruServer.validatedURL(" EXAMPLE.com/booru/ ").absoluteString, "https://example.com/booru")
        XCTAssertEqual(try BooruServer.validatedURL("https://example.com/index.php").absoluteString, "https://example.com")
        for value in ["http://example.com", "https://me:secret@example.com", "file:///private", "https://example.com?api_key=secret", "https://example.com/#x", ""] {
            XCTAssertThrowsError(try BooruServer.validatedURL(value), value)
        }
    }

    func testAuthenticationAndQueryEncodingStayScopedToServer() throws {
        let credentials = BooruCredentials(account: "user+name", apiKey: "key&?secret")
        var server = dan
        let request = try BooruClient.request(server: server, path: "posts.json", items: [.init(name: "tags", value: "a&b -rating:e")], credentials: credentials)
        XCTAssertEqual(request.url?.path, "/booru/posts.json")
        XCTAssertFalse(request.url!.absoluteString.contains("secret"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic " + Data("user+name:key&?secret".utf8).base64EncodedString())
        XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "a&b -rating:e")
        server.engine = .gelbooru
        let gel = try BooruClient.request(server: server, path: "index.php", items: [], credentials: credentials)
        let items = URLComponents(url: gel.url!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(items.first(where: { $0.name == "user_id" })?.value, "user+name")
        XCTAssertEqual(items.first(where: { $0.name == "api_key" })?.value, "key&?secret")
        XCTAssertNil(gel.value(forHTTPHeaderField: "Authorization"))
        XCTAssertFalse(server.pageURL(postID: 101).absoluteString.contains("secret"))
    }

    func testDanbooruAndLegacyMediaDecode() throws {
        let row: [String: Any] = ["id": 101, "tag_string": "scenery sample_artist", "tag_string_artist": "sample_artist", "image_width": 12000,
            "image_height": 9000, "file_url": "//cdn.example.com/movie.webm", "preview_file_url": "/preview.jpg", "large_file_url": "https://cdn.example.com/sample.jpg",
            "file_ext": "webm", "pool_ids": [77, 78], "score": 42, "rating": "s"]
        let post = try BooruDecoder.post(row, server: dan)
        XCTAssertTrue(post.isVideo)
        XCTAssertEqual(post.width, 12000)
        XCTAssertEqual(post.artists, ["sample_artist"])
        XCTAssertEqual(post.poolIDs, [77, 78])
        XCTAssertEqual(post.rating, "s")
        XCTAssertEqual(post.fileURL?.absoluteString, "https://cdn.example.com/movie.webm")
        var gel = dan; gel.engine = .gelbooru
        let old = try BooruDecoder.post(["id": "102", "file_url": "https://cdn.example.com/a.gif", "tags": "animated scenery", "score": NSNull(), "rating": "s"], server: gel)
        XCTAssertTrue(old.isAnimated)
        XCTAssertEqual(old.score, 0)
        XCTAssertEqual(old.rating, "g")
        XCTAssertNil(BooruDecoder.safeURL("javascript:alert(1)", base: dan.baseURL))
        XCTAssertNil(BooruDecoder.safeURL("https://user:password@example.com/a", base: dan.baseURL))
        XCTAssertNil(try BooruDecoder.post(["id": 111], server: dan).displayURL)
    }

    func testJSONEnvelopesXMLAndEmptyResponses() throws {
        let json = Data(#"{"@attributes":{"count":1},"post":[{"id":"9"}]}"#.utf8)
        XCTAssertEqual(try BooruDecoder.rows(json, key: "post").count, 1)
        XCTAssertEqual(try BooruDecoder.rows(Data(#"{"@attributes":{"count":0}}"#.utf8), key: "post").count, 0)
        let xml = Data(#"<?xml version="1.0"?><tags><tag name="landscape" count="123" type="0" id="1"/></tags>"#.utf8)
        let tags = try BooruDecoder.rows(xml, key: "tag")
        XCTAssertEqual(tags.first?["name"] as? String, "landscape")
        XCTAssertEqual(try BooruDecoder.rows(Data("<notes type='array'/>".utf8), key: "note").count, 0)
        for body in ["<html><body>Sign in</body></html>", "{\"success\":false}", "{\"error\":\"unauthorized\"}", "garbage"] {
            XCTAssertThrowsError(try BooruDecoder.rows(Data(body.utf8), key: "post"))
        }
    }

    func testNotesStripMarkupAndInactiveNotes() throws {
        let notes = try BooruDecoder.rows(Data("<notes><note id='1' x='10' y='20' width='300' height='90' is_active='true'><body>Hello &amp; &lt;b&gt;world&lt;/b&gt;</body></note></notes>".utf8), key: "note").compactMap(BooruDecoder.note)
        XCTAssertEqual(notes.first?.body, "Hello & world")
        XCTAssertEqual(notes.first?.width, 300)
        XCTAssertNil(BooruDecoder.note(["id": 2, "body": "old", "is_active": false]))
        XCTAssertNil(BooruDecoder.note(["id": 2, "body": "old", "is_active": "0"]))
        let html = Data("<html><section id='notes'><article data-x='20' data-y='30' data-width='40' data-height='50' data-body='&lt;b&gt;Hello&lt;/b&gt; &amp; world'></article></section></html>".utf8)
        XCTAssertEqual(try BooruHTML.notes(html).first?.body, "Hello & world")
    }

    func testGelbooruPoolParsingPreservesSequence() throws {
        let list = Data("<html><a href='index.php?page=pool&amp;s=show&amp;id=77'>Mountain &amp; sky</a><a href='index.php?page=pool&amp;s=show&amp;id=77'>duplicate</a></html>".utf8)
        XCTAssertEqual(try BooruHTML.pools(list), [.init(id: 77, name: "Mountain & sky", count: 0)])
        let detail = Data("<html><span id='p103'></span><article id=\"p101\"></article><span id='p103'></span></html>".utf8)
        XCTAssertEqual(try BooruHTML.postIDs(detail), [103, 101])
        XCTAssertThrowsError(try BooruHTML.postIDs(Data("<html>Just a moment...</html>".utf8)))
        let pagination = Data("<html><a href='?page=pool&amp;s=show&amp;id=77&amp;pid=90'>3</a><a href='?page=pool&amp;s=show&amp;id=77&amp;pid=45'>2</a></html>".utf8)
        XCTAssertEqual(try BooruHTML.nextPoolOffset(pagination, after: 0), 45)
        XCTAssertNil(try BooruHTML.nextPoolOffset(detail, after: 0))
        XCTAssertEqual(BooruHTML.attributes("data-body=\"It's a note\" data-x='4'")["data-body"], "It's a note")
    }

    func testAutocompletePreservesTermsAndNegation() throws {
        let completion = try XCTUnwrap(BooruCompletion("rating:g  -sC"))
        XCTAssertEqual(completion.token, "sc")
        XCTAssertEqual(completion.inserting("scenery"), "rating:g  -scenery ")
        XCTAssertNil(BooruCompletion("scenery "))
        XCTAssertNil(BooruCompletion("rating:g"))
    }

    func testBlacklistAndExceptionsWildcardsRatings() {
        let post = sample(tags: ["mountain", "scenery", "sample_artist"])
        XCTAssertTrue(BooruBlacklist("mountain\ncity").contains(post))
        XCTAssertFalse(BooruBlacklist("mountain city").contains(post))
        XCTAssertTrue(BooruBlacklist("mountain -city").contains(post))
        XCTAssertFalse(BooruBlacklist("mountain -scenery").contains(post))
        XCTAssertTrue(BooruBlacklist("sample_*").contains(post))
        XCTAssertTrue(BooruBlacklist("rating:general").contains(post))
        XCTAssertFalse(BooruBlacklist("rating:explicit").contains(post))
        XCTAssertTrue(BooruBlacklist("id:101").contains(post))
        XCTAssertFalse(BooruBlacklist("\n# comment\n").contains(post))
    }

    func testPersistentLibrarySeparatesSitesAndHitomi() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("booru.sqlite").path
        let store = try BooruStore(path: path)
        let first = BooruServer.presets[0], second = BooruServer.presets[1]
        try store.saveServer(first); try store.saveServer(second)
        try store.toggleFavorite(sample(first))
        try store.toggleFavorite(sample(second))
        try store.recordSearch("scenery", serverID: first.id)
        try store.toggleTag("artist_a", serverID: first.id, kind: "artist")
        try store.toggleTag("mountain", serverID: first.id)
        try store.setBlacklist("city", serverID: first.id)
        try store.select(second)
        let hitomi = try AppDatabase.inMemory()
        _ = try hitomi.upsertWork(galleryId: 101, title: "Hitomi only")
        let restored = try BooruStore(path: path)
        XCTAssertEqual(restored.selectedServerID, second.id)
        XCTAssertEqual(restored.favorites(serverID: first.id).count, 1)
        XCTAssertEqual(restored.favorites(serverID: second.id).count, 1)
        XCTAssertEqual(restored.savedTags(serverID: first.id, kind: "artist"), ["artist_a"])
        XCTAssertEqual(restored.savedTags(serverID: second.id, kind: "artist"), [])
        XCTAssertEqual(restored.history(serverID: second.id), [])
        XCTAssertEqual(restored.blacklist(serverID: second.id), "")
        try restored.toggleFavorite(sample(first))
        XCTAssertEqual(restored.favorites(serverID: first.id).count, 0)
        XCTAssertEqual(restored.favorites(serverID: second.id).count, 1)
        XCTAssertEqual(try hitomi.listWorks().first?.title, "Hitomi only")
        XCTAssertEqual(try hitomi.listArtists().count, 0)
    }

    func testHistoryDeduplicatesCapsAndClearsPerServer() throws {
        let store = try BooruStore()
        for n in 0..<505 { try store.recordSearch("tag_\(n)", serverID: "a") }
        try store.recordSearch("tag_20", serverID: "a")
        try store.recordSearch("other", serverID: "b")
        XCTAssertEqual(store.history(serverID: "a").count, 500)
        XCTAssertEqual(store.history(serverID: "a").first, "tag_20")
        try store.clearHistory(serverID: "a")
        XCTAssertEqual(store.history(serverID: "a"), [])
        XCTAssertEqual(store.history(serverID: "b"), ["other"])
    }

    func testDuplicateServerRejectedAndModePersistsSeparately() throws {
        let store = try BooruStore()
        let existing = BooruServer.presets[0]
        try store.saveServer(existing)
        XCTAssertThrowsError(try store.saveServer(.init(name: "Duplicate", baseURL: existing.baseURL, engine: existing.engine)))
        let suite = "booru-mode-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let db = try AppDatabase.inMemory()
        let env = AppEnvironment(database: db, browserPreferences: defaults, booru: store)
        XCTAssertEqual(env.mode, .booru)
        env.mode = .hitomi
        XCTAssertEqual(AppEnvironment(database: db, browserPreferences: defaults, booru: store).mode, .hitomi)
        XCTAssertFalse(env.useEmbeddedBrowser)
    }

    func testEngineRequestsPaginationAndPoolOrder() async throws {
        for engine in BooruEngine.allCases where engine != .oldGelbooru {
            var server = dan; server.id = UUID().uuidString; server.engine = engine
            let client = mocked { request in
                let url = request.url!
                let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
                if engine == .gelbooru {
                    XCTAssertEqual(items.first { $0.name == "pid" }?.value, "1")
                    XCTAssertEqual(items.first { $0.name == "s" }?.value, "post")
                } else { XCTAssertEqual(items.first { $0.name == "page" }?.value, "2") }
                XCTAssertEqual(items.first { $0.name == "tags" }?.value, "scenery")
                return (200, "[]")
            }
            let batch = try await client.posts(server: server, query: "scenery", page: 1)
            XCTAssertFalse(batch.hasMore)
        }
        let client = mocked { request in
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "tags" }?.value, "ordpool:77")
            return (200, "[]")
        }
        _ = try await client.poolPosts(server: dan, poolID: 77, page: 0)
    }

    func testScoreTimeoutRecoveryPreservesAllBandsAndPagination() async throws {
        let client = mocked { request in
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            let tags = items.first { $0.name == "tags" }!.value!
            let page = items.first { $0.name == "page" }!.value!
            XCTAssertTrue(tags.hasPrefix("landscape order:score"))
            if tags == "landscape order:score" { return (500, "{\"message\":\"QueryCanceled\"}") }
            if tags.contains("score:>=1000") {
                if page == "1" { return (200, "[" + (0..<40).map { "{\"id\":\($0 + 1),\"score\":\(2000 - $0)}" }.joined(separator: ",") + "]") }
                XCTAssertEqual(page, "2")
                return (200, "[]")
            }
            XCTAssertEqual(page, "1")
            if tags.contains("score:100..999") { return (200, "[{\"id\":41,\"score\":999}]") }
            if tags.contains("score:0..99") { return (200, "[{\"id\":42,\"score\":0}]") }
            XCTAssertTrue(tags.contains("score:<0"))
            return (200, "[{\"id\":43,\"score\":-1}]")
        }
        let first = try await client.posts(server: dan, query: "landscape order:score", page: 0)
        XCTAssertEqual(first.posts.count, 40); XCTAssertTrue(first.hasMore)
        let second = try await client.posts(server: dan, query: "landscape order:score", page: 1)
        XCTAssertEqual(second.posts.map(\.score), [999]); XCTAssertTrue(second.hasMore)
        let third = try await client.posts(server: dan, query: "landscape order:score", page: 2)
        XCTAssertEqual(third.posts.map(\.score), [0]); XCTAssertTrue(third.hasMore)
        let fourth = try await client.posts(server: dan, query: "landscape order:score", page: 3)
        XCTAssertEqual(fourth.posts.map(\.score), [-1]); XCTAssertFalse(fourth.hasMore)
    }

    func testOldGelbooruUsesHTMLAndTwentyPostOffsets() async throws {
        var server = dan; server.engine = .oldGelbooru
        let client = mocked { request in
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(items.first { $0.name == "pid" }?.value, "40")
            XCTAssertEqual(items.first { $0.name == "page" }?.value, "post")
            XCTAssertEqual(items.first { $0.name == "s" }?.value, "list")
            return (200, "<html><span class='thumb'><a id='p9'><img src='/thumb.jpg' title='scenery score:3 rating:safe'></a></span></html>")
        }
        let batch = try await client.posts(server: server, query: "scenery", page: 2)
        XCTAssertEqual(batch.posts.first?.postID, 9)
        XCTAssertFalse(batch.hasMore)
    }

    func testGelbooruPublicGalleryFallbackUsesActualNextOffset() async throws {
        var server = dan; server.engine = .gelbooru
        let client = mocked { request in
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            if items.first(where: { $0.name == "page" })?.value == "dapi" { return (401, "API key required") }
            let offset = items.first { $0.name == "pid" }?.value
            if offset == nil {
                return (200, "<html><article><a id='p11'><img src='/thumb.jpg' title='scenery score:3 rating:general'></a></article><a href='?page=post&amp;s=list&amp;pid=42'>Next</a></html>")
            }
            XCTAssertEqual(offset, "42")
            return (200, "<html><article><a id='p12'><img src='/thumb2.jpg' title='scenery score:2 rating:general'></a></article></html>")
        }
        let first = try await client.posts(server: server, query: "scenery", page: 0)
        XCTAssertEqual(first.posts.map(\.postID), [11]); XCTAssertTrue(first.hasMore)
        let second = try await client.posts(server: server, query: "scenery", page: 1)
        XCTAssertEqual(second.posts.map(\.postID), [12]); XCTAssertFalse(second.hasMore)
    }

    func testAuthRateLimitAndHTMLFailuresRemainActionable() async throws {
        for status in [401, 403, 429, 500] {
            let client = mocked { _ in (status, "{}") }
            do { _ = try await client.posts(server: dan, query: "", page: 0); XCTFail("Expected error") }
            catch let error as BooruError {
                switch (status, error) { case (401, .authentication), (403, .validationRequired), (429, .rateLimited), (500, .unavailable(500)): break
                default: XCTFail("Wrong error") }
            }
        }
        let client = mocked { _ in (200, "<html>Login required</html>") }
        do { _ = try await client.posts(server: dan, query: "", page: 0); XCTFail("Expected invalid response") }
        catch { XCTAssertTrue(error is BooruError) }
    }

    func testPoolListReadsKnownEmptyCountsAndPostLinksKeepOrder() throws {
        let html = Data("""
        <html><table><tr><td><a href='?page=pool&amp;s=show&amp;id=746'>Empty</a></td><td>Creator</td><td>0</td></tr>
        <tr><td><a href='?page=pool&amp;s=show&amp;id=685'>Pages</a></td><td>Creator</td><td>7</td></tr></table></html>
        """.utf8)
        let pools = try BooruHTML.pools(html)
        XCTAssertTrue(pools.allSatisfy(\.hasKnownCount))
        XCTAssertEqual(pools.filter { !$0.hasKnownCount || $0.count > 0 }.map(\.id), [685])
        let posts = Data("<html><span id='p30'><a href='?page=post&amp;s=view&amp;id=30'>one</a></span><a href='?page=post&amp;s=view&amp;id=10'>two</a><a href='?page=pool&amp;s=show&amp;id=9'>unrelated</a></html>".utf8)
        XCTAssertEqual(try BooruHTML.postIDs(posts), [30, 10])
    }

    func testDirectPoolLookupDoesNotExposeAnEmptyPool() async throws {
        var server = dan; server.engine = .gelbooru
        let client = mocked { _ in (200, "<html><div id='pool-show'>Empty pool</div></html>") }
        let pools = try await client.pools(server: server, query: "746", page: 0)
        XCTAssertTrue(pools.isEmpty)
    }

    func testPoolUsesPublicPostWhenAPIHasNoRow() async throws {
        var server = dan; server.engine = .gelbooru
        let client = mocked { request in
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            switch items.first(where: { $0.name == "page" })?.value {
            case "pool": return (200, "<html><a href='?page=post&amp;s=view&amp;id=17'>page</a></html>")
            case "dapi": return (200, "[]")
            default: return (200, "<html><img id='image' src='https://images.example/page.png'></html>")
            }
        }
        let batch = try await client.poolPosts(server: server, poolID: 5, page: 0)
        XCTAssertEqual(batch.posts.map(\.postID), [17])
        XCTAssertNotNil(batch.posts.first?.fileURL)
    }

    func testLiveSafebooruPoolLoadsAllSevenPagesInOrder() async throws {
        guard ProcessInfo.processInfo.environment["NUMBER_MEMO_BOORU_LIVE_TESTS"] == "1" else { throw XCTSkip("Opt-in network test") }
        let server = BooruServer.presets[2]
        let pools = try await BooruClient.shared.pools(server: server, query: "", page: 0)
        XCTAssertEqual(pools.first { $0.id == 685 }?.count, 7)
        let batch = try await BooruClient.shared.poolPosts(server: server, poolID: 685, page: 0)
        XCTAssertEqual(batch.posts.map(\.postID), [4455261, 4378770, 3776896, 416533, 4378768, 4583271, 3776895])
        XCTAssertTrue(batch.posts.allSatisfy { $0.fileURL != nil && $0.previewURL != nil })
        XCTAssertFalse(batch.hasMore)
    }

    func testLegacyWholePoolIsPagedLocallyWithoutDuplicates() async throws {
        var server = dan; server.engine = .gelbooru; server.id = UUID().uuidString
        let client = mocked { request in
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            if items.first(where: { $0.name == "page" })?.value == "pool" {
                XCTAssertNil(items.first(where: { $0.name == "api_key" }))
                return (200, "<html>" + (1...42).map { "<span id='p\($0)'></span>" }.joined() + "</html>")
            }
            let id = items.first(where: { $0.name == "id" })!.value!
            return (200, "[{\"id\":\(id)}]")
        }
        let first = try await client.poolPosts(server: server, poolID: 7, page: 0)
        XCTAssertEqual(first.posts.count, 40)
        XCTAssertTrue(first.hasMore)
        let second = try await client.poolPosts(server: server, poolID: 7, page: 1)
        XCTAssertEqual(second.posts.map(\.postID), [41, 42])
        XCTAssertFalse(second.hasMore)
    }

    @MainActor func testNewSearchRetainsPaginationWhenFirstPageMatchesPreviousFeed() async {
        let loader = BooruFeedLoader(), server = BooruServer.presets[0], source = BooruFixtureSource()
        await loader.load(server: server, source: source, query: "", reset: true)
        await loader.load(server: server, source: source, query: "scenery", reset: true)
        XCTAssertTrue(loader.hasMore)
        await loader.load(server: server, source: source, query: "scenery", reset: false)
        XCTAssertEqual(loader.posts.map(\.postID), [101, 102, 103])
        XCTAssertFalse(loader.hasMore)
    }
    @MainActor func testStaleSearchCannotReplaceNewerResults() async {
        let source = DelayedBooruSource()
        let loader = BooruFeedLoader()
        let server = dan
        let old = Task { await loader.load(server: server, source: source, query: "slow", reset: true) }
        try? await Task.sleep(for: .milliseconds(30))
        await loader.load(server: server, source: source, query: "fast", reset: true)
        await old.value
        XCTAssertEqual(loader.posts.map(\.postID), [2])
        XCTAssertFalse(loader.loading)
    }

    func testLiveSafebooruAPIAndAutocomplete() async throws {
        guard ProcessInfo.processInfo.environment["NUMBER_MEMO_BOORU_LIVE_TESTS"] == "1" else { throw XCTSkip("Opt-in network test") }
        let server = BooruServer.presets[2]
        let batch = try await BooruClient.shared.posts(server: server, query: "scenery", page: 0)
        XCTAssertFalse(batch.posts.isEmpty)
        XCTAssertNotNil(batch.posts.first?.previewURL)
        let tags = try await BooruClient.shared.suggestions(server: server, token: "landscape")
        XCTAssertFalse(tags.isEmpty)
    }

    func testLiveDanbooruEndpointWhenReachable() async throws {
        try await verifyPrimaryEndpoint(BooruServer.presets[0], query: "rating:g scenery")
    }

    func testLiveGelbooruEndpointWhenAuthorized() async throws {
        try await verifyPrimaryEndpoint(BooruServer.presets[1], query: "rating:general scenery")
    }

    private func verifyPrimaryEndpoint(_ server: BooruServer, query: String) async throws {
        guard ProcessInfo.processInfo.environment["NUMBER_MEMO_BOORU_LIVE_TESTS"] == "1" else { throw XCTSkip("Opt-in network test") }
        do {
            let batch = try await BooruClient.shared.posts(server: server, query: query, page: 0)
            XCTAssertFalse(batch.posts.isEmpty)
        } catch BooruError.authentication {
            throw XCTSkip("\(server.name) requires user-provided server credentials")
        } catch let error as URLError {
            throw XCTSkip("\(server.name) is unreachable from this device network (\(error.code.rawValue))")
        }
    }

    private func mocked(_ handler: @escaping (URLRequest) -> (Int, String)) -> BooruClient {
        BooruURLProtocol.handler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BooruURLProtocol.self]
        return BooruClient(session: URLSession(configuration: config))
    }
}

private final class BooruURLProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (Int, String))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, body) = Self.handler!(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private actor DelayedBooruSource: BooruProviding {
    func posts(server: BooruServer, query: String, page: Int) async throws -> BooruBatch {
        try await Task.sleep(for: .milliseconds(query == "slow" ? 180 : 10))
        return .init(posts: [BooruFixtureSource.post(query == "slow" ? 1 : 2, server: server)], hasMore: false)
    }
    func suggestions(server: BooruServer, token: String) async throws -> [BooruTag] { [] }
    func pools(server: BooruServer, query: String, page: Int) async throws -> [BooruPool] { [] }
    func poolPosts(server: BooruServer, poolID: Int64, page: Int) async throws -> BooruBatch { .init(posts: [], hasMore: false) }
    func notes(server: BooruServer, postID: Int64) async throws -> [BooruNote] { [] }
}
