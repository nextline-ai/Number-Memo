import Foundation

protocol BooruProviding: Sendable {
    func posts(server: BooruServer, query: String, page: Int) async throws -> BooruBatch
    func suggestions(server: BooruServer, token: String) async throws -> [BooruTag]
    func pools(server: BooruServer, query: String, page: Int) async throws -> [BooruPool]
    func poolPosts(server: BooruServer, poolID: Int64, page: Int) async throws -> BooruBatch
    func notes(server: BooruServer, postID: Int64) async throws -> [BooruNote]
    func details(server: BooruServer, post: BooruPost) async throws -> BooruPost
}

extension BooruProviding {
    func details(server: BooruServer, post: BooruPost) async throws -> BooruPost { post }
}

/// Reject API redirects across origins so credentials cannot follow a server redirect.
final class BooruRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let publicMedia: Bool
    init(publicMedia: Bool = false) { self.publicMedia = publicMedia }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let original = task.originalRequest?.url
        let next = request.url
        guard next?.scheme == "https", next?.user == nil, next?.password == nil else { completionHandler(nil); return }
        if original?.host == next?.host && original?.port == next?.port { completionHandler(request) }
        else if publicMedia {
            var redirected = request
            redirected.setValue(nil, forHTTPHeaderField: "Cookie")
            redirected.setValue(nil, forHTTPHeaderField: "Authorization")
            redirected.httpShouldHandleCookies = false
            completionHandler(redirected)
        } else { completionHandler(nil) }
    }
}

actor BooruClient: BooruProviding {
    static let shared = BooruClient()
    static let pageSize = 40
    private let session: URLSession
    private let browserFallback: Bool
    private var wholePools: [String: [Int64]] = [:]
    private var poolOffsets: [String: [Int: Int]] = [:]
    private var publicOffsets: [String: [Int: Int]] = [:]
    private var publicPages: [String: [Int: URL]] = [:]
    private struct ScoreCursor {
        var band = 0
        var page = 1
        var nextPage = 1
    }
    private var scoreCursors: [String: ScoreCursor] = [:]
    private static let scoreBands = ["score:>=1000", "score:100..999", "score:0..99", "score:<0"]
    init(session: URLSession? = nil) {
        browserFallback = session == nil
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 30
        config.httpMaximumConnectionsPerHost = 4
        self.session = session ?? URLSession(configuration: config, delegate: BooruRedirectPolicy(), delegateQueue: nil)
    }

    /// Credentials are only attached to API calls on the configured server.
    nonisolated static func request(server: BooruServer, path: String, items: [URLQueryItem], credentials: BooruCredentials = .init()) throws -> URLRequest {
        var components = URLComponents(url: server.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        var query = items
        if !credentials.isEmpty {
            switch server.engine {
            case .danbooru, .oldGelbooru: break // Old Gelbooru uses browser login; Danbooru uses HTTP Basic below.
            case .gelbooru:
                query += [.init(name: "user_id", value: credentials.account), .init(name: "api_key", value: credentials.apiKey)]
            case .moebooru:
                query += [.init(name: "login", value: credentials.account), .init(name: "password_hash", value: credentials.apiKey)]
            }
        }
        components.queryItems = query
        guard let url = components.url else { throw BooruError.invalidServer }
        var request = URLRequest(url: url)
        request.setValue(BooruBrowserSession.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json, application/xml;q=0.9, text/html;q=0.8", forHTTPHeaderField: "Accept")
        if server.engine == .danbooru && !credentials.isEmpty {
            let basic = Data((credentials.account + ":" + credentials.apiKey).utf8).base64EncodedString()
            request.setValue("Basic " + basic, forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func data(_ server: BooruServer, _ path: String, _ values: [(String, String)], authenticated: Bool = true, publicURL: URL? = nil) async throws -> Data {
        let credentials = authenticated ? try BooruKeychain.read(serverID: server.id) : BooruCredentials()
        var request = try Self.request(server: server, path: path, items: values.map { .init(name: $0.0, value: $0.1) }, credentials: credentials)
        if let publicURL {
            guard !authenticated, BooruWebTransport.sameOrigin(publicURL, server.baseURL) else { throw BooruError.invalidServer }
            request.url = publicURL
        }
        let prepared = await BooruBrowserSession.prepare(request, server: server)
        let data: Data
        let response: URLResponse
        let isDocument = (server.engine == .danbooru && path == "pools" && !authenticated)
            || values.contains { $0.0 == "page" && ["post", "pool"].contains($0.1) }
        if browserFallback && isDocument {
            (data, response) = try await BooruWebTransport.document(for: request, server: server)
        } else if browserFallback, await BooruWebTransport.hasSession(for: server) {
            (data, response) = try await BooruWebTransport.data(for: request, server: server)
        } else {
            do {
                let native = try await session.data(for: prepared)
                if browserFallback, Self.needsBrowser(native.0, response: native.1) {
                    (data, response) = try await BooruWebTransport.data(for: request, server: server)
                } else { (data, response) = native }
            } catch {
                guard browserFallback, let network = error as? URLError,
                      [.secureConnectionFailed, .networkConnectionLost].contains(network.code) else { throw error }
                (data, response) = try await BooruWebTransport.data(for: request, server: server)
            }
        }
        await BooruBrowserSession.receive(response, server: server)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw BooruError.invalidResponse }
        if isDocument && Self.needsBrowser(data, response: response), let url = request.url {
            await BooruBrowserSession.recordChallenge(url, server: server)
        }
        switch http.statusCode {
        case 200..<300: break
        case 401: throw BooruError.authentication
        case 403: throw BooruError.validationRequired
        case 429: throw BooruError.rateLimited
        default: throw BooruError.unavailable(http.statusCode)
        }
        if Self.needsBrowser(data, response: response) { throw BooruError.validationRequired }
        if path.hasSuffix(".json") || values.contains(where: { $0.0 == "page" && $0.1 == "dapi" }) {
            let prefix = String(decoding: data.prefix(256), as: UTF8.self).lowercased()
            if prefix.contains("<html") || prefix.contains("<!doctype html") { throw BooruError.validationRequired }
        }
        guard data.count < 12_000_000 else { throw BooruError.invalidResponse }
        return data
    }

    nonisolated static func needsBrowser(_ data: Data, response: URLResponse) -> Bool {
        if (response as? HTTPURLResponse)?.statusCode == 403 { return true }
        let prefix = String(decoding: data.prefix(4096), as: UTF8.self).lowercased()
        return prefix.contains("cf-chl-") || prefix.contains("just a moment") || prefix.contains("checking your browser")
    }

    func posts(server: BooruServer, query: String, page: Int) async throws -> BooruBatch {
        let raw: Data
        switch server.engine {
        case .oldGelbooru:
            return try await publicPosts(server: server, query: query, page: page)
        case .danbooru:
            let key = server.id + ":" + query
            if page == 0 { scoreCursors.removeValue(forKey: key) }
            if let cursor = scoreCursors[key], cursor.nextPage == page {
                return try await scorePosts(server: server, query: query, page: page, cursor: cursor)
            }
            do {
                raw = try await data(server, "posts.json", [("tags", query), ("limit", "40"), ("page", String(page + 1))])
            } catch BooruError.unavailable(500) where page == 0 && query.split(whereSeparator: \.isWhitespace).contains("order:score") {
                // Cover the full score domain in descending, disjoint bands. No hidden
                // minimum score or date cutoff: subsequent pages continue into lower bands.
                return try await scorePosts(server: server, query: query, page: page, cursor: .init())
            }
        case .gelbooru:
            if browserFallback && server.isGelbooruWebsite, try BooruKeychain.read(serverID: server.id).isEmpty {
                return try await publicPosts(server: server, query: query, page: page)
            }
            do {
                raw = try await data(server, "index.php", [("page", "dapi"), ("s", "post"), ("q", "index"), ("json", "1"), ("tags", query), ("limit", "40"), ("pid", String(page))])
            } catch BooruError.authentication {
                // Gelbooru can require an API key while its public gallery remains available.
                // Read that gallery through the verified browser instead of repeating validation.
                return try await publicPosts(server: server, query: query, page: page)
            }
        case .moebooru:
            raw = try await data(server, "post.json", [("tags", query), ("limit", "40"), ("page", String(page + 1))])
        }
        let rows = try BooruDecoder.rows(raw, key: "post")
        return BooruBatch(posts: try rows.map { try BooruDecoder.post($0, server: server) }, hasMore: rows.count >= Self.pageSize)
    }

    private func scorePosts(server: BooruServer, query: String, page: Int, cursor initial: ScoreCursor) async throws -> BooruBatch {
        var cursor = initial
        while cursor.band < Self.scoreBands.count {
            let raw = try await data(server, "posts.json", [("tags", query + " " + Self.scoreBands[cursor.band]), ("limit", "40"), ("page", String(cursor.page))])
            let rows = try BooruDecoder.rows(raw, key: "post")
            if rows.count < Self.pageSize { cursor.band += 1; cursor.page = 1 }
            else { cursor.page += 1 }
            if !rows.isEmpty || cursor.band == Self.scoreBands.count {
                cursor.nextPage = page + 1
                if scoreCursors.count > 32 { scoreCursors.removeAll() }
                scoreCursors[server.id + ":" + query] = cursor
                return .init(posts: try rows.map { try BooruDecoder.post($0, server: server) }, hasMore: cursor.band < Self.scoreBands.count)
            }
        }
        return .init(posts: [], hasMore: false)
    }

    func suggestions(server: BooruServer, token: String) async throws -> [BooruTag] {
        let raw: Data
        switch server.engine {
        case .oldGelbooru:
            // Old instances have no tag API. Read matching tags from the search sidebar.
            raw = try await data(server, "index.php", [("page", "post"), ("s", "list"), ("tags", token + "*")], authenticated: false)
            return try BooruLegacyHTML.tags(raw).filter { $0.name.hasPrefix(token) }.prefix(12).map { $0 }
        case .danbooru:
            raw = try await data(server, "tags.json", [("search[name_matches]", token + "*"), ("search[order]", "count"), ("limit", "12")])
        case .gelbooru:
            if browserFallback && server.isGelbooruWebsite, try BooruKeychain.read(serverID: server.id).isEmpty {
                let html = try await data(server, "index.php", [("page", "post"), ("s", "list"), ("tags", token + "*")], authenticated: false)
                return Array(try BooruLegacyHTML.tags(html).filter { $0.name.hasPrefix(token) }.prefix(12))
            }
            do {
                raw = try await data(server, "index.php", [("page", "dapi"), ("s", "tag"), ("q", "index"), ("json", "1"), ("name_pattern", token + "%"), ("orderby", "count"), ("order", "DESC"), ("limit", "12")])
            } catch BooruError.authentication {
                let html = try await data(server, "index.php", [("page", "post"), ("s", "list"), ("tags", token + "*")], authenticated: false)
                return Array(try BooruLegacyHTML.tags(html).filter { $0.name.hasPrefix(token) }.prefix(12))
            }
        case .moebooru:
            raw = try await data(server, "tag.json", [("name", token + "*"), ("order", "count"), ("limit", "12")])
        }
        return try BooruDecoder.rows(raw, key: "tag").compactMap { row in
            guard let name = row["name"] as? String else { return nil }
            return BooruTag(name: name, count: BooruDecoder.integer(row["post_count"] ?? row["count"]), category: BooruDecoder.integer(row["category"] ?? row["type"]), isMetadata: server.engine == .danbooru && BooruDecoder.integer(row["category"]) == 5)
        }
    }

    func pools(server: BooruServer, query: String, page: Int) async throws -> [BooruPool] {
        if server.engine.usesGelbooruPages {
            if let id = Int64(query), id > 0 {
                let raw = try await data(server, "index.php", [("page", "pool"), ("s", "show"), ("id", String(id))], authenticated: false)
                let ids = try BooruHTML.postIDs(raw)
                guard !ids.isEmpty else { return [] }
                return [.init(id: id, name: "Pool #\(id)", count: ids.count, hasKnownCount: false)]
            }
            let raw = try await data(server, "index.php", [("page", "pool"), ("s", "list"), ("pid", String(page * 25))], authenticated: false)
            return try BooruHTML.pools(raw)
        }
        let path = server.engine == .danbooru ? "pools.json" : "pool.json"
        let key = server.engine == .danbooru ? "search[name_matches]" : "query"
        let value = server.engine == .danbooru && !query.isEmpty ? "*\(query)*" : query
        var parameters = [("page", String(page + 1)), ("limit", "20")]
        if !value.isEmpty { parameters.append((key, value)) }
        if server.engine == .danbooru {
            // A pool can contain thousands of post IDs. The list needs only its summary.
            parameters.append(("only", "id,name,post_count,description"))
        }
        let raw: Data
        do { raw = try await data(server, path, parameters) }
        catch {
            try Task.checkCancellation()
            let domain = (error as NSError).domain
            guard browserFallback, server.engine == .danbooru,
                  domain == "WKErrorDomain" || domain == NSURLErrorDomain else { throw error }
            // Some protection layers allow navigation but reject browser fetch.
            // Read the public list in the same validated browser, without API credentials.
            let publicParameters = parameters.filter { $0.0 != "only" }
            let html = try await data(server, "pools", publicParameters, authenticated: false)
            return try BooruHTML.danbooruPools(html)
        }
        return try BooruDecoder.rows(raw, key: "pool").compactMap { row in
            guard let name = row["name"] as? String else { return nil }
            return BooruPool(id: Int64(BooruDecoder.integer(row["id"])), name: name, count: BooruDecoder.integer(row["post_count"]), description: row["description"] as? String ?? "", hasKnownCount: row["post_count"] != nil)
        }
    }

    func poolPosts(server: BooruServer, poolID: Int64, page: Int) async throws -> BooruBatch {
        if server.engine.usesGelbooruPages {
            let key = server.id + ":" + String(poolID)
            let ids: [Int64]
            let hasMore: Bool
            if page > 0, let all = wholePools[key] {
                ids = Array(all.dropFirst(page * Self.pageSize).prefix(Self.pageSize))
                hasMore = (page + 1) * Self.pageSize < all.count
            } else {
                let offset = page == 0 ? 0 : poolOffsets[key]?[page] ?? page * 45
                let raw = try await data(server, "index.php", [("page", "pool"), ("s", "show"), ("id", String(poolID)), ("pid", String(offset))], authenticated: false)
                let all = try BooruHTML.postIDs(raw)
                let next = try BooruHTML.nextPoolOffset(raw, after: offset)
                if page == 0 {
                    wholePools.removeValue(forKey: key)
                    poolOffsets[key] = [:]
                }
                if page == 0 && next == nil {
                    // Legacy Gelbooru returns the entire pool regardless of pid.
                    // Page this ID list locally instead of repeatedly loading the same pool.
                    if wholePools.count >= 16 { wholePools.removeAll() }
                    wholePools[key] = all
                    ids = Array(all.prefix(Self.pageSize))
                    hasMore = all.count > Self.pageSize
                } else {
                    ids = all
                    hasMore = next != nil
                    if let next { poolOffsets[key, default: [:]][page + 1] = next }
                }
            }
            // Preserve the pool's order; individual requests are serialized to respect rate limits.
            var posts: [BooruPost] = []
            for id in ids {
                try Task.checkCancellation()
                if server.engine == .oldGelbooru {
                    let response = try await data(server, "index.php", [("page", "post"), ("s", "view"), ("id", String(id))], authenticated: false)
                    posts.append(try BooruLegacyHTML.post(response, server: server, id: id))
                    continue
                }
                do {
                    let response = try await data(server, "index.php", [("page", "dapi"), ("s", "post"), ("q", "index"), ("json", "1"), ("id", String(id))])
                    let decoded = try BooruDecoder.rows(response, key: "post").map { try BooruDecoder.post($0, server: server) }
                    if decoded.isEmpty {
                        let html = try await data(server, "index.php", [("page", "post"), ("s", "view"), ("id", String(id))], authenticated: false)
                        posts.append(try BooruLegacyHTML.post(html, server: server, id: id))
                    } else { posts += decoded }
                } catch BooruError.authentication {
                    let response = try await data(server, "index.php", [("page", "post"), ("s", "view"), ("id", String(id))], authenticated: false)
                    posts.append(try BooruLegacyHTML.post(response, server: server, id: id))
                }
                if id != ids.last { try await Task.sleep(for: .milliseconds(150)) }
            }
            return .init(posts: posts, hasMore: hasMore)
        }
        // Danbooru needs ordpool to preserve the authored sequence.
        let term = server.engine == .danbooru ? "ordpool" : "pool"
        return try await posts(server: server, query: "\(term):\(poolID)", page: page)
    }

    func notes(server: BooruServer, postID: Int64) async throws -> [BooruNote] {
        let raw: Data
        switch server.engine {
        case .oldGelbooru:
            raw = try await data(server, "index.php", [("page", "post"), ("s", "view"), ("id", String(postID))], authenticated: false)
            return try BooruLegacyHTML.notes(raw)
        case .danbooru:
            // Notes may exceed the default page size. Fetch every active page.
            var result: [BooruNote] = []
            var page = 1
            while true {
                let pageData = try await data(server, "notes.json", [("search[post_id]", String(postID)), ("search[is_active]", "true"), ("limit", "200"), ("page", String(page))])
                let rows = try BooruDecoder.rows(pageData, key: "note")
                result += rows.compactMap(BooruDecoder.note)
                if rows.count < 200 { return result }
                page += 1
                try Task.checkCancellation()
            }
        case .moebooru:
            raw = try await data(server, "note.json", [("post_id", String(postID))])
        case .gelbooru:
            // Gelbooru's current public notes live in data-* attributes on the post page.
            // Legacy DAPI instances still expose XML notes.
            if server.baseURL.host == "gelbooru.com" || server.baseURL.host == "www.gelbooru.com" {
                raw = try await data(server, "index.php", [("page", "post"), ("s", "view"), ("id", String(postID))], authenticated: false)
                return try BooruHTML.notes(raw)
            }
            raw = try await data(server, "index.php", [("page", "dapi"), ("s", "note"), ("q", "index"), ("json", "1"), ("post_id", String(postID))])
        }
        return try BooruDecoder.rows(raw, key: "note").compactMap(BooruDecoder.note)
    }

    func details(server: BooruServer, post: BooruPost) async throws -> BooruPost {
        guard server.engine.usesGelbooruPages else { return post }
        let raw = try await data(server, "index.php", [("page", "post"), ("s", "view"), ("id", String(post.postID))], authenticated: false)
        return try BooruLegacyHTML.post(raw, server: server, id: post.postID, preview: post.previewURL)
    }

    private func publicPosts(server: BooruServer, query: String, page: Int) async throws -> BooruBatch {
        let key = server.id + ":" + query
        let size = server.engine == .oldGelbooru ? 20 : 42
        let offset = page == 0 ? 0 : publicOffsets[key]?[page] ?? page * size
        var parameters = [("page", "post"), ("s", "list")]
        if !query.isEmpty { parameters.append(("tags", query)) }
        if offset > 0 { parameters.append(("pid", String(offset))) }
        let html = try await data(server, "index.php", parameters, authenticated: false, publicURL: page == 0 ? nil : publicPages[key]?[page])
        let posts = try BooruLegacyHTML.posts(html, server: server)
        let next = try BooruLegacyHTML.nextOffset(html, after: offset)
        let nextPage = try BooruLegacyHTML.nextPageURL(html, server: server, after: offset)
        if page == 0 {
            if publicOffsets.count > 32 { publicOffsets.removeAll(); publicPages.removeAll() }
            publicOffsets[key] = [:]
            publicPages[key] = [:]
        }
        if let next, let nextPage {
            publicOffsets[key, default: [:]][page + 1] = next
            publicPages[key, default: [:]][page + 1] = nextPage
        }
        return .init(posts: posts, hasMore: nextPage != nil)
    }
}

enum BooruDecoder {
    static func integer(_ value: Any?) -> Int {
        if let n = value as? NSNumber { return n.intValue }
        return Int(value as? String ?? "") ?? 0
    }
    static func rows(_ data: Data, key: String) throws -> [[String: Any]] {
        if let json = try? JSONSerialization.jsonObject(with: data) {
            if let rows = json as? [[String: Any]] { return rows }
            if let object = json as? [String: Any] {
                if object["success"] as? Bool == false || object["error"] != nil { throw BooruError.invalidResponse }
                if let rows = object[key] as? [[String: Any]] { return rows }
                if let row = object[key] as? [String: Any] { return [row] }
                if let attributes = object["@attributes"] as? [String: Any], integer(attributes["count"]) == 0 { return [] }
            }
            throw BooruError.invalidResponse
        }
        let parser = XMLParser(data: data)
        let delegate = BooruXMLRows(element: key)
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), delegate.validRoot else { throw BooruError.invalidResponse }
        return delegate.rows
    }
    static func safeURL(_ value: Any?, base: URL) -> URL? {
        guard let string = value as? String, !string.isEmpty,
              let url = URL(string: string, relativeTo: base.appendingPathComponent("/"))?.absoluteURL,
              url.scheme == "https", url.host != nil, url.user == nil, url.password == nil else { return nil }
        return url
    }
    static func post(_ row: [String: Any], server: BooruServer) throws -> BooruPost {
        let id = integer(row["id"])
        guard id > 0 else { throw BooruError.invalidResponse }
        let file = safeURL(row["file_url"], base: server.baseURL)
        let preview = safeURL(row["preview_file_url"] ?? row["preview_url"], base: server.baseURL)
        let sample = safeURL(row["large_file_url"] ?? row["sample_url"] ?? row["jpeg_url"], base: server.baseURL)
        let tags = (row["tag_string"] as? String ?? row["tags"] as? String ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
        let artists = (row["tag_string_artist"] as? String ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
        var rating = row["rating"] as? String ?? ""
        if !server.usesModernRatings && rating == "s" { rating = "g" } // Legacy s means safe, not sensitive.
        return .init(serverID: server.id, postID: Int64(id), previewURL: preview, sampleURL: sample, fileURL: file,
                     width: integer(row["image_width"] ?? row["width"]), height: integer(row["image_height"] ?? row["height"]),
                     tags: tags, artists: artists, rating: rating, score: integer(row["score"]),
                     fileExtension: row["file_ext"] as? String ?? file?.pathExtension ?? "",
                     poolIDs: (row["pool_ids"] as? [Any] ?? []).map { Int64(integer($0)) }.filter { $0 > 0 },
                     metadataTags: (row["tag_string_meta"] as? String).map { $0.split(whereSeparator: \.isWhitespace).map(String.init) })
    }
    static func note(_ row: [String: Any]) -> BooruNote? {
        if let active = row["is_active"], ["false", "0"].contains(String(describing: active).lowercased()) { return nil }
        guard let body = row["body"] as? String else { return nil }
        return .init(id: Int64(integer(row["id"])), x: Double(integer(row["x"])), y: Double(integer(row["y"])),
                     width: Double(integer(row["width"])), height: Double(integer(row["height"])), body: BooruHTML.plainText(body))
    }
}

private final class BooruXMLRows: NSObject, XMLParserDelegate {
    let element: String
    var rows: [[String: Any]] = []
    var validRoot = false
    private var current: [String: Any]?
    private var field: String?
    private var text = ""
    init(element: String) { self.element = element }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        if name == element + "s" { validRoot = true }
        if name == element { current = attributes }
        else if current != nil { field = name; text = "" }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == element, let row = current { rows.append(row); current = nil; field = nil }
        else if name == field { current?[name] = text; field = nil }
    }
}

/// Only extracts inert metadata; no remote markup or JavaScript is executed.
enum BooruHTML {
    static func matches(_ pattern: String, _ string: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        return regex.matches(in: string, range: NSRange(string.startIndex..., in: string)).map { match in
            (0..<match.numberOfRanges).map { Range(match.range(at: $0), in: string).map { String(string[$0]) } ?? "" }
        }
    }
    static func decode(_ value: String) -> String {
        var value = value
        for match in matches("&#(x[0-9a-f]+|[0-9]+);", value).reversed() {
            let token = match[1]
            let number = token.lowercased().hasPrefix("x") ? UInt32(token.dropFirst(), radix: 16) : UInt32(token)
            if let number, let scalar = UnicodeScalar(number) { value = value.replacingOccurrences(of: match[0], with: String(scalar)) }
        }
        for (key, replacement) in [("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " "), ("&rsquo;", "’"), ("&lsquo;", "‘"), ("&rdquo;", "”"), ("&ldquo;", "“"), ("&amp;", "&")] {
            value = value.replacingOccurrences(of: key, with: replacement)
        }
        return value
    }
    static func plainText(_ text: String) -> String {
        decode(text.replacingOccurrences(of: "(?i)<br\\s*/?>|</p>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func attributes(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for m in matches("([a-z0-9_-]+)\\s*=\\s*([\"'])(.*?)\\2", text) { result[m[1].lowercased()] = decode(m[3]) }
        return result
    }
    static func html(_ data: Data) throws -> String {
        guard let html = String(data: data, encoding: .utf8), html.contains("<html"),
              !html.contains("Just a moment..."), !html.contains("cf-chl-") else { throw BooruError.invalidResponse }
        return html
    }
    static func pools(_ data: Data) throws -> [BooruPool] {
        let document = try html(data)
        var counts: [Int64: Int] = [:]
        for row in matches("<tr\\b[^>]*>(.*?)</tr>", document) {
            let cells = matches("<td\\b[^>]*>(.*?)</td>", row[1])
            guard cells.count >= 3, let link = matches("<a\\b([^>]*)>", cells[0][1]).first,
                  let id = poolID(attributes(link[1])["href"]),
                  let count = Int(plainText(cells[2][1]).replacingOccurrences(of: ",", with: "")) else { continue }
            counts[id] = count
        }
        var seen = Set<Int64>()
        return matches("<a\\b([^>]*)>(.*?)</a>", document).compactMap { m in
            guard let id = poolID(attributes(m[1])["href"]), seen.insert(id).inserted else { return nil }
            return BooruPool(id: id, name: plainText(m[2]), count: counts[id] ?? 0, hasKnownCount: counts[id] != nil)
        }
    }
    private static func poolID(_ href: String?) -> Int64? {
        guard let href, let c = URLComponents(string: href),
              c.queryItems?.contains(where: { $0.name == "page" && $0.value == "pool" }) == true,
              c.queryItems?.contains(where: { $0.name == "s" && $0.value == "show" }) == true,
              let raw = c.queryItems?.first(where: { $0.name == "id" })?.value else { return nil }
        return Int64(raw)
    }
    static func danbooruPools(_ data: Data) throws -> [BooruPool] {
        let document = try html(data)
        guard matches("\\bid=[\"']c-pools[\"']", document).isEmpty == false else { throw BooruError.invalidResponse }
        var seen = Set<Int64>()
        return matches("<tr\\b[^>]*>(.*?)</tr>", document).compactMap { row in
            let cells = matches("<td\\b[^>]*>(.*?)</td>", row[1])
            guard let nameCell = cells.first else { return nil }
            for link in matches("<a\\b([^>]*)>(.*?)</a>", nameCell[1]) {
                guard let href = attributes(link[1])["href"],
                      let raw = matches("(?:^|/)pools/([0-9]+)$", href).first?[1],
                      let id = Int64(raw), seen.insert(id).inserted else { continue }
                let count = cells.count > 1 ? Int(plainText(cells[1][1]).replacingOccurrences(of: ",", with: "")) ?? 0 : 0
                return BooruPool(id: id, name: plainText(link[2]), count: count, hasKnownCount: cells.count > 1)
            }
            return nil
        }
    }

    static func postIDs(_ data: Data) throws -> [Int64] {
        var seen = Set<Int64>()
        return matches("<(?:a|span|article)\\b([^>]*)>", try html(data)).compactMap { match in
            let attrs = attributes(match[1])
            let markedID = attrs["id"].flatMap { matches("^p([0-9]+)$", $0).first?[1] }.flatMap(Int64.init)
            let components = attrs["href"].flatMap(URLComponents.init(string:))
            let isPost = components?.queryItems?.contains { $0.name == "page" && $0.value == "post" } == true
                && components?.queryItems?.contains { $0.name == "s" && $0.value == "view" } == true
            let linkedID = isPost ? components?.queryItems?.first { $0.name == "id" }?.value.flatMap(Int64.init) : nil
            guard let id = markedID ?? linkedID, seen.insert(id).inserted else { return nil }
            return id
        }
    }
    static func nextPoolOffset(_ data: Data, after offset: Int) throws -> Int? {
        try matches("<a\\b([^>]*)>", html(data)).compactMap { match -> Int? in
            guard let href = attributes(match[1])["href"], let components = URLComponents(string: href),
                  components.queryItems?.contains(where: { $0.name == "page" && $0.value == "pool" }) == true,
                  let value = components.queryItems?.first(where: { $0.name == "pid" })?.value,
                  let number = Int(value), number > offset else { return nil }
            return number
        }.min()
    }
    static func notes(_ data: Data) throws -> [BooruNote] {
        let html = try html(data)
        return matches("<article\\b([^>]*)>", html).enumerated().compactMap { index, match in
            let attrs = attributes(match[1])
            guard let body = attrs["data-body"], let x = Double(attrs["data-x"] ?? ""), let y = Double(attrs["data-y"] ?? ""),
                  let w = Double(attrs["data-width"] ?? ""), let h = Double(attrs["data-height"] ?? "") else { return nil }
            return .init(id: Int64(index + 1), x: x, y: y, width: w, height: h, body: plainText(body))
        }
    }
}
