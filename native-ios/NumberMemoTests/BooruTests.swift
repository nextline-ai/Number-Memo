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

    func testPersistentLibrarySeparatesSitesAndManga() throws {
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
        let manga = try AppDatabase.inMemory()
        _ = try manga.upsertWork(galleryId: 101, title: "Manga only")
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
        XCTAssertEqual(try manga.listWorks().first?.title, "Manga only")
        XCTAssertEqual(try manga.listArtists().count, 0)
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
        env.mode = .manga
        XCTAssertEqual(AppEnvironment(database: db, browserPreferences: defaults, booru: store).mode, .manga)
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

    func testServer500RetryPreservesExactSearchAndOmitsOnlyProjection() async throws {
        var calls = 0
        let client = mocked { request in
            calls += 1
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(items.first { $0.name == "tags" }?.value, "landscape order:score rating:general")
            XCTAssertEqual(items.first { $0.name == "page" }?.value, "1")
            if calls == 1 {
                XCTAssertNotNil(items.first { $0.name == "only" })
                return (500, "{}")
            }
            XCTAssertNil(items.first { $0.name == "only" })
            return (200, "[{\"id\":41,\"score\":999,\"file_url\":\"https://cdn.example.com/a.jpg\"}]")
        }
        let batch = try await client.posts(server: dan, query: "landscape order:score rating:general", page: 0)
        XCTAssertEqual(calls, 2); XCTAssertEqual(batch.posts.map(\.postID), [41])
    }
    func testPersistent500DoesNotAddHiddenScoreOrRatingTags() async throws {
        var calls = 0
        let client = mocked { request in
            calls += 1
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(items.first { $0.name == "tags" }?.value, "scenery order:score")
            return (500, "{}")
        }
        do {
            _ = try await client.posts(server: dan, query: "scenery order:score", page: 0)
            XCTFail("Expected the server failure to remain visible")
        } catch BooruError.unavailable(500) { } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(calls, 2, "Bounded retry; never append hidden filters or repeat indefinitely")
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

    @MainActor func testFeedProjectionTracksPaginationAndBlacklistEdits() async {
        let loader = BooruFeedLoader(), server = BooruServer.presets[0], source = BooruFixtureSource()
        loader.setBlacklists([server.id: "id:101"])
        await loader.load(server: server, source: source, query: "", reset: true)
        XCTAssertEqual(loader.visiblePosts, loader.posts.filter { $0.postID != 101 })
        await loader.load(server: server, source: source, query: "", reset: false)
        XCTAssertEqual(loader.visiblePosts.map(\.postID), [102, 103])
        loader.setBlacklists([server.id: "id:102\nid:103"])
        XCTAssertEqual(loader.visiblePosts.map(\.postID), [101])
        loader.setBlacklists([:])
        XCTAssertEqual(loader.visiblePosts, loader.posts)
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

    func testDanbooruProjectionIncludesMediaAndFilteringFields() async throws {
        let client = mocked { request in
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            let fields = Set((items.first { $0.name == "only" }?.value ?? "").split(separator: ",").map(String.init))
            XCTAssertEqual(fields, Set(["id", "file_url", "large_file_url", "preview_file_url", "image_width", "image_height", "tag_string", "tag_string_artist", "tag_string_meta", "rating", "score", "file_ext", "pool_ids", "fav_count", "up_score", "comment_count", "is_banned"]))
            return (200, #"[{"id":101,"file_url":"https://cdn.example.com/a.jpg","preview_file_url":"https://cdn.example.com/p.jpg","tag_string":"scenery","tag_string_artist":"artist","rating":"g","file_ext":"jpg"}]"#)
        }
        let result = try await client.posts(server: dan, query: "scenery", page: 0)
        XCTAssertEqual(result.posts.first?.tags, ["scenery"])
        XCTAssertEqual(result.posts.first?.artists, ["artist"])
        XCTAssertNotNil(result.posts.first?.fileURL)
    }

    func testGoldAccessDetectionRequiresAnExplicitPostGate() {
        let gate = "<html><div id='content'><section class='image-container note-container'><p><a href='/user_upgrades/new'>You need a gold account to see this image</a>.</p></section></div></html>"
        XCTAssertEqual(BooruPostAccessError.detect(Data(gate.utf8), server: dan), .goldRequired)
        XCTAssertEqual(BooruPostAccessError.detect(Data(#"{"success":false,"message":"You need a Gold account to see this image."}"#.utf8), server: dan), .goldRequired)
        XCTAssertEqual(BooruPostAccessError.detect(Data("This post requires a Gold account.".utf8), server: dan), .goldRequired)
        for text in [
            "<html><div id='comments'>You need a gold account to see this image</div><section class='image-container'><img src='/image.jpg'></section></html>",
            "<section class='image-container'><img src='/image.jpg'><p>You need a gold account to see this image</p></section>",
            "<section class='image-container'><p>This page has been removed because of a takedown request or rule violation.</p></section>",
            "<section class='image-container'><p>This image is unavailable in safe mode.</p></section>",
            #"{"success":false,"message":"Gold members can search more tags."}"#,
            #"{"id":12403879,"is_banned":true,"is_visible":false,"tag_string":"restricted_tag"}"#,
            "Forbidden", "<html>Just a moment...</html>"
        ] { XCTAssertNil(BooruPostAccessError.detect(Data(text.utf8), server: dan), text) }
        var other = dan; other.engine = .gelbooru
        XCTAssertNil(BooruPostAccessError.detect(Data(gate.utf8), server: other))
    }

    func testDanbooruGoldRowsAreFilteredWithoutChangingNativePageSizeOrRepeatingChecks() async throws {
        let rows: [[String: Any]] = (1...39).map { ["id": $0, "file_url": "https://cdn.example.com/\($0).jpg"] }
            + [["id": 12_403_879, "is_banned": false]]
        let json = String(data: try JSONSerialization.data(withJSONObject: rows), encoding: .utf8)!
        var documentCalls = 0
        let client = mocked { request in
            if request.url!.path.hasSuffix("posts.json") { return (200, json) }
            documentCalls += 1
            XCTAssertTrue(request.url!.path.hasSuffix("posts/12403879"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/html", "The access gate exists in HTML, not Danbooru's projected JSON")
            return (200, "<section class='image-container'><p>You need a gold account to see this image.</p></section>")
        }
        let first = try await client.posts(server: dan, query: "", page: 0)
        XCTAssertEqual(first.posts.count, 39)
        XCTAssertEqual(first.goldRestrictedIDs, [12_403_879])
        XCTAssertEqual(first.sourcePostCount, 40)
        XCTAssertTrue(first.hasMore)
        _ = try await client.posts(server: dan, query: "", page: 0)
        do {
            _ = try await client.details(server: dan, post: BooruDecoder.post(["id": 12_403_879], server: dan))
            XCTFail("A saved preview-only post must use the same confirmed restriction")
        } catch { XCTAssertEqual(error as? BooruPostAccessError, .goldRequired) }
        XCTAssertEqual(documentCalls, 1, "Feed refreshes and opening the same missing-media post share a short access result cache")
    }

    func testDanbooruAccessFailuresAndRemovedPostsRemainInFeed() async throws {
        var checks = 0
        let client = mocked { request in
            if request.url!.path.hasSuffix("posts.json") {
                return (200, #"[{"id":101,"is_banned":false},{"id":102,"is_banned":true}]"#)
            }
            checks += 1
            XCTAssertTrue(request.url!.path.hasSuffix("posts/101"))
            return (403, "<html>Forbidden</html>")
        }
        for _ in 0..<2 {
            let batch = try await client.posts(server: dan, query: "", page: 0)
            XCTAssertEqual(batch.posts.map(\.postID), [101, 102])
            XCTAssertTrue(batch.goldRestrictedIDs.isEmpty)
        }
        XCTAssertEqual(checks, 2, "An inconclusive access failure must not become a cached hidden post")
    }

    @MainActor func testGoldAccessCacheRetriesAfterBrowserValidationChanges() async throws {
        var server = dan; server.id = UUID().uuidString
        var restricted = true, calls = 0
        let client = mocked { _ in
            calls += 1
            return (200, restricted
                ? "<section class='image-container'>You need a gold account to see this image.</section>"
                : "<section class='image-container'><img src='https://cdn.example.com/a.jpg'></section>")
        }
        let post = try BooruDecoder.post(["id": 101], server: server)
        do { _ = try await client.details(server: server, post: post); XCTFail("Expected Gold restriction") }
        catch { XCTAssertEqual(error as? BooruPostAccessError, .goldRequired) }
        restricted = false
        BooruBrowserSession.clearChallenge(for: server)
        _ = try await client.details(server: server, post: post)
        XCTAssertEqual(calls, 2)
    }

    func testExplicitGoldHTTPErrorIsTypedButGenericForbiddenIsNot() async throws {
        let client = mocked { _ in (403, #"{"success":false,"message":"You need a gold account to see this image."}"#) }
        do { _ = try await client.posts(server: dan, query: "id:12403879", page: 0); XCTFail("Expected typed access error") }
        catch { XCTAssertEqual(error as? BooruPostAccessError, .goldRequired) }
        let generic = mocked { _ in (403, #"{"success":false,"message":"Forbidden"}"#) }
        do { _ = try await generic.posts(server: dan, query: "", page: 0); XCTFail("Expected verification error") }
        catch BooruError.validationRequired { }
        catch { XCTFail("Unexpected error: \(error)") }
    }

    @MainActor func testGoldOnlyFeedPageAdvancesAndReportsRestrictedIDs() async {
        let source = GoldPageSource(), loader = BooruFeedLoader(), server = dan
        var blocked: [(String, [Int64])] = []
        await loader.load(servers: [server], source: source, query: "", reset: true, onGoldRestricted: { blocked.append(($0, $1)) })
        XCTAssertTrue(loader.posts.isEmpty)
        XCTAssertTrue(loader.hasMore)
        XCTAssertEqual(blocked.first?.0, server.id)
        XCTAssertEqual(blocked.first?.1, [12_403_879])
        await loader.load(servers: [server], source: source, query: "", reset: false)
        XCTAssertEqual(loader.posts.map(\.postID), [101])
        XCTAssertFalse(loader.hasMore)
        let pages = await source.pages
        XCTAssertEqual(pages, [0, 1])
    }

    @MainActor func testRepeatingGoldOnlyPageStopsInsteadOfDrainingForever() async {
        let source = GoldPageSource(repeating: true), loader = BooruFeedLoader(), server = dan
        await loader.load(servers: [server], source: source, query: "", reset: true)
        XCTAssertTrue(loader.hasMore)
        await loader.load(servers: [server], source: source, query: "", reset: false)
        XCTAssertFalse(loader.hasMore)
        await loader.load(servers: [server], source: source, query: "", reset: false)
        let pages = await source.pages
        XCTAssertEqual(pages, [0, 1])
    }

    func testGoldOnlySortedPageDoesNotTriggerUnsupportedSortFallback() async throws {
        let source = GoldPageSource()
        let result = try await BooruSortValidation.posts(source: source, server: dan, query: "", page: 0, sort: .popular)
        XCTAssertEqual(result.goldRestrictedIDs, [12_403_879])
        let pages = await source.pages
        XCTAssertEqual(pages, [0], "A filtered result is still a valid nonempty native page")
    }

    func testGelbooruDetailsAndNotesShareOneDocumentButMediaRefreshStaysFresh() async throws {
        var calls = 0
        let client = mocked { _ in
            calls += 1
            return (200, "<html><img id='image' src='https://cdn.example.com/sample.jpg'><a href='https://cdn.example.com/original.jpg'>Original image</a><section id='notes'><article data-x='20' data-y='30' data-width='40' data-height='50' data-body='Hello'></article></section></html>")
        }
        let server = BooruServer(id: "document-reuse", name: "Gelbooru", baseURL: URL(string: "https://gelbooru.com")!, engine: .gelbooru)
        let post = try BooruDecoder.post(["id": 101], server: server)
        let resolved = try await client.details(server: server, post: post)
        XCTAssertNotNil(resolved.viewerURL(original: false))
        let notes = try await client.notes(server: server, postID: 101)
        XCTAssertEqual(notes.first?.body, "Hello")
        XCTAssertEqual(calls, 1, "Details and notes used to navigate to the same page twice")
        _ = try await client.details(server: server, post: resolved)
        XCTAssertEqual(calls, 2, "A failed-media refresh must not reuse an expired URL")
    }

    @MainActor func testCancelledPartialRefreshDoesNotErasePreviousImages() async throws {
        let source = GatedBooruSource(), loader = BooruFeedLoader()
        var fast = dan; fast.id = "fast"
        var slow = dan; slow.id = "slow"
        await loader.load(servers: [fast], source: source, query: "", reset: true, contentID: "previous")
        let previous = loader.posts
        let task = Task { await loader.load(servers: [fast, slow], source: source, query: "empty", reset: true, contentID: "cancelled") }
        for _ in 0..<200 {
            if await source.emptyDelivered { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()
        await task.value
        XCTAssertEqual(loader.posts, previous)
        XCTAssertEqual(loader.contentID, "previous")
        XCTAssertFalse(loader.loading)
    }

    @MainActor func testFastServerPublishesBeforeSlowServerAndKeepsPagination() async throws {
        let source = GatedBooruSource(), loader = BooruFeedLoader()
        var fast = dan; fast.id = "fast"
        var slow = dan; slow.id = "slow"
        let task = Task { await loader.load(servers: [fast, slow], source: source, query: "", reset: true, contentID: "current") }
        for _ in 0..<200 {
            if !loader.posts.isEmpty { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(loader.posts.map(\.serverID), ["fast"])
        XCTAssertTrue(loader.loading)
        XCTAssertEqual(loader.contentID, "current")
        await source.release()
        await task.value
        XCTAssertEqual(Set(loader.posts.map(\.serverID)), Set(["fast", "slow"]))
        XCTAssertFalse(loader.loading)
        await loader.load(servers: [fast, slow], source: source, query: "", reset: false, contentID: "current")
        XCTAssertEqual(loader.posts.count, 4)
        XCTAssertFalse(loader.hasMore)
    }

    @MainActor func testLaunchWarmupKeepsNativeServerPagesAndCapsAllBooruThumbnailsAtTwenty() async throws {
        let first = BooruServer(id: "warm-dan", name: "Dan", baseURL: URL(string: "https://dan.example")!, engine: .danbooru)
        let second = BooruServer(id: "warm-legacy", name: "Legacy", baseURL: URL(string: "https://legacy.example")!, engine: .oldGelbooru)
        let probe = LaunchBooruWorkProbe()
        let source = LaunchBooruSource(nativeCounts: [first.id: 40, second.id: 20], probe: probe)
        let warmup = LaunchFeedWarmup(manga: ContentUITestSupport.source, booru: source, thumbnail: { url, server in
            try await probe.perform(stage: "thumbnail", key: server.id + ":" + url.absoluteString)
        })
        let task = Task { await warmup.run(mangaQuery: nil, site: "manga.la", servers: [first, second], rating: .all) }
        for _ in 0..<200 {
            if await probe.started("page").count == 2 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let firstRequests = await source.requests
        XCTAssertEqual(firstRequests.count, 2)
        XCTAssertEqual(Set(firstRequests.map(\.serverID)), Set([first.id, second.id]))
        XCTAssertTrue(firstRequests.allSatisfy { $0.page == 0 })
        await probe.release("page")
        for _ in 0..<200 {
            if await probe.started("thumbnail").count == 2 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let inFlightThumbnails = await probe.started("thumbnail")
        XCTAssertEqual(inFlightThumbnails.count, 2, "Only two thumbnail workers may start while their results are held")
        let peak = await probe.peak
        XCTAssertLessThanOrEqual(peak, 2, "List and thumbnail work share the same concurrency budget")
        await probe.release("thumbnail")
        await task.value
        let thumbnailKeys = await probe.started("thumbnail")
        XCTAssertEqual(thumbnailKeys.count, 20, "The cap applies across all servers, not once per server")
        XCTAssertEqual(Set(thumbnailKeys).count, 20)
        XCTAssertTrue(thumbnailKeys.allSatisfy { $0.contains("/preview/") })
        XCTAssertTrue(thumbnailKeys.contains { $0.hasPrefix(first.id + ":") })
        XCTAssertTrue(thumbnailKeys.contains { $0.hasPrefix(second.id + ":") })
        await warmup.run(mangaQuery: nil, site: "manga.la", servers: [first, second], rating: .all)
        let repeatedRequests = await source.requests
        let repeatedThumbnails = await probe.started("thumbnail")
        XCTAssertEqual(repeatedRequests, firstRequests)
        XCTAssertEqual(repeatedThumbnails, thumbnailKeys)
        let firstPage = try await warmup.booruPage(server: first, query: "", rating: .all, sort: .latest)
        let secondPage = try await warmup.booruPage(server: second, query: "", rating: .all, sort: .latest)
        XCTAssertEqual(firstPage.posts.count, 40, "Preview limits must not truncate the native page consumed by the feed")
        XCTAssertEqual(secondPage.posts.count, 20)
        let finalRequests = await source.requests
        XCTAssertEqual(finalRequests, firstRequests, "Warmup and cached consumers must never advance to page one")
    }

    @MainActor func testLaunchBooruPageFeedsInitialLoadButRefreshAndPaginationStayFresh() async {
        let server = BooruServer(id: "warm-refresh", name: "Refresh", baseURL: URL(string: "https://refresh.example")!, engine: .danbooru)
        let source = LaunchBooruSource(nativeCounts: [server.id: 40])
        let warmup = LaunchFeedWarmup(manga: ContentUITestSupport.source, booru: source, thumbnail: { _, _ in })
        await warmup.run(mangaQuery: nil, site: "manga.la", servers: [server], rating: .all)
        let loader = BooruFeedLoader()
        await loader.load(servers: [server], source: source, query: "", reset: true, startup: warmup, useLaunchPage: true)
        let initialRequests = await source.requests
        XCTAssertEqual(initialRequests.map(\.page), [0])
        XCTAssertEqual(loader.posts.count, 40)
        XCTAssertEqual(loader.posts.first?.postID, 10_040)
        XCTAssertTrue(loader.hasMore)
        await loader.load(servers: [server], source: source, query: "", reset: false, startup: warmup)
        let pagedRequests = await source.requests
        XCTAssertEqual(pagedRequests.map(\.page), [0, 1], "Consuming the warmed page must advance the loader cursor exactly once")
        XCTAssertEqual(loader.posts.count, 80)
        XCTAssertFalse(loader.hasMore)
        await source.setVersion(2)
        await loader.load(servers: [server], source: source, query: "", reset: true, startup: warmup)
        XCTAssertEqual(loader.posts.count, 40)
        XCTAssertEqual(loader.posts.first?.postID, 20_040, "Pull-to-refresh must not restore the old launch snapshot")
        XCTAssertTrue(loader.hasMore)
        await loader.load(servers: [server], source: source, query: "", reset: false, startup: warmup)
        let refreshedRequests = await source.requests
        XCTAssertEqual(refreshedRequests.map(\.page), [0, 1, 0, 1])
        XCTAssertEqual(loader.posts.count, 80)
        XCTAssertTrue(loader.posts.allSatisfy { $0.postID >= 20_000 })
        XCTAssertFalse(loader.hasMore)
        let reopened = BooruFeedLoader()
        await reopened.load(servers: [server], source: source, query: "", reset: true, startup: warmup, useLaunchPage: true)
        XCTAssertEqual(reopened.posts.first?.postID, 20_040)
        let reopenedRequests = await source.requests
        XCTAssertEqual(reopenedRequests.map(\.page), [0, 1, 0, 1, 0], "A later feed instance must not reuse an already-consumed launch snapshot")
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

private actor GatedBooruSource: BooruProviding {
    private var released = false
    private(set) var emptyDelivered = false
    func release() { released = true }
    func posts(server: BooruServer, query: String, page: Int) async throws -> BooruBatch {
        if server.id == "slow" { while !released { try await Task.sleep(for: .milliseconds(5)) } }
        if query == "empty" { emptyDelivered = true; return .init(posts: [], hasMore: false) }
        return .init(posts: [BooruFixtureSource.post(Int64(page + 1), server: server)], hasMore: page == 0)
    }
    func suggestions(server: BooruServer, token: String) async throws -> [BooruTag] { [] }
    func pools(server: BooruServer, query: String, page: Int) async throws -> [BooruPool] { [] }
    func poolPosts(server: BooruServer, poolID: Int64, page: Int) async throws -> BooruBatch { .init(posts: [], hasMore: false) }
    func notes(server: BooruServer, postID: Int64) async throws -> [BooruNote] { [] }
}

private actor LaunchBooruWorkProbe {
    private var released = Set<String>()
    private var waiting: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var starts: [String: [String]] = [:]
    private var active = 0
    private(set) var peak = 0
    func perform(stage: String, key: String) async throws {
        active += 1; peak = max(peak, active)
        starts[stage, default: []].append(key)
        defer { active -= 1 }
        if !released.contains(stage) {
            await withCheckedContinuation { waiting[stage, default: []].append($0) }
        }
        try Task.checkCancellation()
    }
    func started(_ stage: String) -> [String] { starts[stage] ?? [] }
    func release(_ stage: String) {
        released.insert(stage)
        for continuation in waiting.removeValue(forKey: stage) ?? [] { continuation.resume() }
    }
}

private actor LaunchBooruSource: BooruProviding {
    struct Request: Equatable, Sendable { let serverID: String; let query: String; let page: Int }
    private let nativeCounts: [String: Int]
    private let probe: LaunchBooruWorkProbe?
    private var version: Int64 = 1
    private(set) var requests: [Request] = []
    init(nativeCounts: [String: Int], probe: LaunchBooruWorkProbe? = nil) {
        self.nativeCounts = nativeCounts; self.probe = probe
    }
    func setVersion(_ value: Int64) { version = value }
    func posts(server: BooruServer, query: String, page: Int) async throws -> BooruBatch {
        requests.append(Request(serverID: server.id, query: query, page: page))
        let version = version, count = nativeCounts[server.id] ?? 40
        if let probe { try await probe.perform(stage: "page", key: server.id + ":" + String(page)) }
        let posts = (0..<count).map { index -> BooruPost in
            let id = version * 10_000 + Int64(page * 1_000 + 40 - index)
            var post = BooruFixtureSource.post(id, server: server)
            post.previewURL = URL(string: "https://warm.example/preview/" + server.id + "/" + String(id) + ".jpg")!
            return post
        }
        return .init(posts: posts, hasMore: page == 0)
    }
    func suggestions(server: BooruServer, token: String) async throws -> [BooruTag] { [] }
    func pools(server: BooruServer, query: String, page: Int) async throws -> [BooruPool] { [] }
    func poolPosts(server: BooruServer, poolID: Int64, page: Int) async throws -> BooruBatch { .init(posts: [], hasMore: false) }
    func notes(server: BooruServer, postID: Int64) async throws -> [BooruNote] { [] }
}

private actor GoldPageSource: BooruProviding {
    let repeating: Bool
    private(set) var pages: [Int] = []
    init(repeating: Bool = false) { self.repeating = repeating }
    func posts(server: BooruServer, query: String, page: Int) async throws -> BooruBatch {
        pages.append(page)
        if page == 0 || repeating { return .init(posts: [], hasMore: true, goldRestrictedIDs: [12_403_879]) }
        return .init(posts: [BooruFixtureSource.post(101, server: server)], hasMore: false)
    }
    func suggestions(server: BooruServer, token: String) async throws -> [BooruTag] { [] }
    func pools(server: BooruServer, query: String, page: Int) async throws -> [BooruPool] { [] }
    func poolPosts(server: BooruServer, poolID: Int64, page: Int) async throws -> BooruBatch { try await posts(server: server, query: "", page: page) }
    func notes(server: BooruServer, postID: Int64) async throws -> [BooruNote] { [] }
}
