import Foundation

enum AppMode: String, CaseIterable, Identifiable {
    case manga, booru
    var id: String { rawValue }
    var title: String { L10n.text(self == .manga ? "Comics Mode" : "Image Mode") }
}

enum BooruEngine: String, Codable, CaseIterable, Identifiable, Sendable {
    case danbooru, gelbooru, oldGelbooru, moebooru
    var id: String { rawValue }
    var title: String { self == .oldGelbooru ? "Old Gelbooru (v0.1.11)" : rawValue.capitalized }
    var usesGelbooruPages: Bool { self == .gelbooru || self == .oldGelbooru }
    /// Recognition only: never registers or contacts a site on the user's behalf.
    static func suggested(for url: URL) -> BooruEngine? {
        let host = url.host?.lowercased() ?? ""
        if host.hasSuffix(".booru.org") { return .oldGelbooru }
        switch host.hasPrefix("www.") ? String(host.dropFirst(4)) : host {
        case "safebooru.org", "gelbooru.com": return .gelbooru
        case "danbooru.donmai.us": return .danbooru
        case "yande.re", "konachan.com", "konachan.net": return .moebooru
        default: return nil
        }
    }

}

struct BooruServer: Codable, Identifiable, Hashable, Sendable {
    var id: String = UUID().uuidString
    var name: String
    var baseURL: URL
    var engine: BooruEngine
    var isGelbooruWebsite: Bool { engine == .gelbooru && ["gelbooru.com", "www.gelbooru.com"].contains(baseURL.host?.lowercased() ?? "") }
    var displayName: String { Self.displayName(name) }
    static func displayName(_ name: String) -> String {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://", "http://"] where value.lowercased().hasPrefix(prefix) {
            return String(value.dropFirst(prefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return value
    }
    var canonicalAddress: String { Self.canonicalAddress(baseURL) }
    static func canonicalAddress(_ url: URL) -> String {
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        parts.scheme = "https"
        var host = parts.host?.lowercased() ?? ""
        if ["www.gelbooru.com", "www.safebooru.org", "www.danbooru.donmai.us"].contains(host) { host = String(host.dropFirst(4)) }
        parts.host = host
        if parts.port == 443 { parts.port = nil }
        parts.query = nil; parts.fragment = nil
        if parts.path.hasSuffix("/index.php") { parts.path.removeLast(10) }
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        return parts.string ?? url.absoluteString
    }

    // Decoding legacy server metadata; never generates search tags.
    var usesModernRatings: Bool { engine == .danbooru || isGelbooruWebsite }

    #if DEBUG
    static let presets: [BooruServer] = [
        .init(id: "danbooru", name: "Danbooru", baseURL: URL(string: "https://danbooru.donmai.us")!, engine: .danbooru),
        .init(id: "gelbooru", name: "Gelbooru", baseURL: URL(string: "https://gelbooru.com")!, engine: .gelbooru),
        .init(id: "safebooru", name: "Safebooru", baseURL: URL(string: "https://safebooru.org")!, engine: .gelbooru)
    ]

    #endif

    static func validatedURL(_ input: String) throws -> URL {
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var parts = URLComponents(string: raw.contains("://") ? raw : "https://" + raw),
              parts.scheme?.lowercased() == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else {
            throw BooruError.invalidServer
        }
        parts.scheme = "https"
        parts.host = host.lowercased()
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        if parts.path.hasSuffix("/index.php") { parts.path = String(parts.path.dropLast(10)) }
        guard let url = parts.url else { throw BooruError.invalidServer }
        return url
    }

    func pageURL(postID: Int64) -> URL {
        switch engine {
        case .danbooru: return baseURL.appendingPathComponent("posts/\(postID)")
        case .moebooru: return baseURL.appendingPathComponent("post/show/\(postID)")
        case .gelbooru, .oldGelbooru:
            var c = URLComponents(url: baseURL.appendingPathComponent("index.php"), resolvingAgainstBaseURL: false)!
            c.queryItems = [URLQueryItem(name: "page", value: "post"), .init(name: "s", value: "view"), .init(name: "id", value: String(postID))]
            return c.url!
        }
    }

    func browsingURL(query: String, poolID: Int64? = nil) -> URL {
        var parts = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        switch engine {
        case .danbooru:
            parts.path += poolID.map { "/pools/\($0)" } ?? "/posts"
            if poolID == nil { parts.queryItems = [.init(name: "tags", value: query)] }
        case .moebooru:
            parts.path += poolID.map { "/pool/show/\($0)" } ?? "/post"
            if poolID == nil { parts.queryItems = [.init(name: "tags", value: query)] }
        case .gelbooru, .oldGelbooru:
            parts.path += "/index.php"
            parts.queryItems = [.init(name: "page", value: poolID == nil ? "post" : "pool"),
                                .init(name: "s", value: poolID == nil ? "list" : "show")]
            if let poolID { parts.queryItems?.append(.init(name: "id", value: String(poolID))) }
            else if !query.isEmpty { parts.queryItems?.append(.init(name: "tags", value: query)) }
        }
        return parts.url!
    }
}

enum BooruSort: String, Codable, CaseIterable, Identifiable, Sendable {
    case latest, popular, trending, mostFavorited, mostUpvoted, mostDiscussed, popularWeek, popularMonth
    var id: String { rawValue }
    var title: String {
        switch self {
        case .latest: L10n.text("Latest")
        case .popular: L10n.text("Popular · Score")
        case .trending: L10n.text("Popular · Trending")
        case .mostFavorited: L10n.text("Popular · Favorites")
        case .mostUpvoted: L10n.text("Popular · Upvotes")
        case .mostDiscussed: L10n.text("Popular · Comments")
        case .popularWeek: L10n.text("Popular · Past 7 Days")
        case .popularMonth: L10n.text("Popular · Past 30 Days")
        }
    }
    static func options(for engine: BooruEngine) -> [Self] {
        switch engine {
        case .danbooru: allCases
        case .moebooru: [.latest, .popular, .popularWeek, .popularMonth]
        case .gelbooru, .oldGelbooru: [.latest, .popular]
        }
    }
    static func options(for servers: [BooruServer], local: Bool = false) -> [Self] {
        guard !local, !servers.isEmpty else { return [.latest, .popular] }
        return allCases.filter { option in servers.allSatisfy { options(for: $0.engine).contains(option) } }
    }
    var restrictsPeriod: Bool { self == .trending || self == .popularWeek || self == .popularMonth }
    func metric(_ post: BooruPost) -> Int? {
        switch self {
        case .popular, .popularWeek, .popularMonth: post.score
        case .mostFavorited: post.favoriteCount
        case .mostUpvoted: post.upvoteCount
        case .mostDiscussed: post.commentCount
        default: nil
        }
    }
    func query(_ query: String, engine: BooruEngine, now: Date = .now) -> String {
        guard self != .latest, Self.options(for: engine).contains(self) else { return query }
        var terms = query.split(whereSeparator: \.isWhitespace).filter { !$0.lowercased().hasPrefix("order:") && !$0.lowercased().hasPrefix("sort:") }.map(String.init)
        if self == .popularWeek || self == .popularMonth {
            // This restriction is explicit in the selected menu label. Preserve
            // user date constraints instead of silently widening their query.
            if !terms.contains(where: { $0.hasPrefix("date:") || $0.hasPrefix("age:") }) {
                let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyy-MM-dd"
                let days = self == .popularWeek ? 7 : 30
                terms.append("date:>=" + formatter.string(from: now.addingTimeInterval(-Double(days) * 86400)))
            }
        }
        let order: String
        switch self {
        case .trending: order = "rank"
        case .mostFavorited: order = "favcount"
        case .mostUpvoted: order = "upvotes"
        case .mostDiscussed: order = "comment_count"
        default: order = "score"
        }
        terms.append(engine == .gelbooru ? "sort:score:desc" : "order:" + order)
        return terms.joined(separator: " ")
    }
}

struct BooruCredentials: Codable, Equatable, Sendable {
    var account = ""
    var apiKey = ""
    var isEmpty: Bool { account.isEmpty && apiKey.isEmpty }
}

struct BooruPost: Codable, Identifiable, Hashable, Sendable {
    let serverID: String
    let postID: Int64
    var previewURL: URL?
    var sampleURL: URL?
    var fileURL: URL?
    var width: Int
    var height: Int
    var tags: [String]
    var artists: [String]
    var rating: String
    var score: Int
    var fileExtension: String
    var poolIDs: [Int64] = []
    var metadataTags: [String]? = nil
    var favoriteCount: Int? = nil
    var upvoteCount: Int? = nil
    var commentCount: Int? = nil
    var id: String { "\(serverID):\(postID)" }
    var isVideo: Bool { ["mp4", "webm", "mov", "m4v"].contains(fileExtension.lowercased()) }
    var isAnimated: Bool { ["gif", "webp", "apng"].contains(fileExtension.lowercased()) || tags.contains("animated") }
    var displayURL: URL? { sampleURL ?? fileURL ?? previewURL }
    // A preview-only post must resolve its details before entering the viewer.
    func viewerURL(original: Bool) -> URL? {
        if isVideo || isAnimated || original { return fileURL ?? sampleURL }
        return sampleURL ?? fileURL
    }
}

struct BooruTag: Identifiable, Hashable, Sendable {
    let name: String
    let count: Int
    let category: Int
    var isMetadata = false
    var id: String { name }
    var isArtist: Bool { category == 1 }
}

struct BooruPool: Identifiable, Hashable, Sendable {
    let id: Int64
    var name: String
    var count: Int
    var description: String = ""
    var hasKnownCount = false
}

struct BooruNote: Identifiable, Equatable, Sendable {
    let id: Int64
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let body: String
}

struct BooruBatch: Sendable {
    let posts: [BooruPost]
    let hasMore: Bool
    var goldRestrictedIDs: [Int64] = []
    var sourcePostCount: Int { posts.count + goldRestrictedIDs.count }
}

/// Only an explicit server access notice may silently remove a post. Missing
/// media, a generic 403, removed posts and safe-mode restrictions are ambiguous.
enum BooruPostAccessError: Error, Equatable, Sendable {
    case goldRequired

    static func detect(_ data: Data, server: BooruServer) -> Self? {
        guard server.engine == .danbooru, data.count <= 12_000_000 else { return nil }
        let prefix = String(decoding: data.prefix(128), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard prefix.hasPrefix("{") || prefix.hasPrefix("<") || prefix.hasPrefix("you ") || prefix.hasPrefix("this ") else { return nil }
        if prefix.hasPrefix("{"), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return detect(object, server: server)
        }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        // Danbooru renders the gate in its image container. A comment, tag,
        // navigation link or upgrade advertisement must not hide a usable post.
        for match in BooruHTML.matches("<(section|div)\\b([^>]*\\bclass\\s*=\\s*[\"'][^\"']*\\bimage-container\\b[^\"']*[\"'][^>]*)>(.*?)</\\1\\s*>", text) {
            let attributes = BooruHTML.attributes(match[2])
            let classes = (attributes["class"] ?? "").split(whereSeparator: \.isWhitespace)
            if classes.contains("image-container"), BooruHTML.matches("<(?:img|video|picture)\\b", match[3]).isEmpty,
               isGoldNotice(BooruHTML.plainText(match[3])) { return .goldRequired }
        }
        // Some image endpoints return a bare text error instead of JSON/HTML.
        if !text.contains("<"), isGoldNotice(text) { return .goldRequired }
        return nil
    }

    static func detect(_ row: [String: Any], server: BooruServer) -> Self? {
        guard server.engine == .danbooru else { return nil }
        for key in ["message", "error", "reason"] {
            if let message = row[key] as? String, isGoldNotice(message) { return .goldRequired }
        }
        return nil
    }

    private static func isGoldNotice(_ text: String) -> Bool {
        let text = text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return text.range(of: #"\b(?:you (?:need|must have) (?:a )?gold account to (?:see|view) this (?:image|post)|this (?:image|post) requires (?:a )?gold account)\b"#, options: .regularExpression) != nil
    }
}

struct BooruCompletion: Equatable {
    let prefix: String
    let token: String
    let negative: Bool
    init?(_ text: String) {
        guard let last = text.last, !last.isWhitespace else { return nil }
        let start = text.lastIndex(where: \.isWhitespace).map { text.index(after: $0) } ?? text.startIndex
        prefix = String(text[..<start])
        let word = String(text[start...])
        negative = word.hasPrefix("-")
        token = String(negative ? word.dropFirst() : Substring(word)).lowercased()
        guard !token.isEmpty, !token.contains(":") else { return nil }
    }
    func inserting(_ name: String) -> String { prefix + (negative ? "-" : "") + name + " " }
}

/// Each line is an OR rule; space-separated terms within a line are ANDed.
/// A leading minus negates a term. Wildcards and rating: terms work offline too.
struct BooruBlacklist {
    let rules: [[String]]
    init(_ text: String) {
        rules = text.components(separatedBy: .newlines).map {
            $0.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        }.filter { !$0.isEmpty && !$0[0].hasPrefix("#") }
    }
    func contains(_ post: BooruPost) -> Bool {
        guard !rules.isEmpty else { return false }
        let tags = Set(post.tags.map { $0.lowercased() })
        return rules.contains { rule in
            rule.allSatisfy { term in
                let negative = term.hasPrefix("-")
                let value = negative ? String(term.dropFirst()) : term
                let matches: Bool
                if value.hasPrefix("rating:") {
                    matches = Self.rating(String(value.dropFirst(7))) == Self.rating(post.rating)
                } else if value.hasPrefix("artist:") {
                    matches = post.artists.contains { $0.lowercased() == String(value.dropFirst(7)) }
                } else if value.hasPrefix("id:") {
                    matches = String(post.postID) == String(value.dropFirst(3))
                } else if value.contains("*") {
                    let pattern = "^" + value.components(separatedBy: "*").map(NSRegularExpression.escapedPattern(for:)).joined(separator: ".*") + "$"
                    matches = tags.contains { $0.range(of: pattern, options: .regularExpression) != nil }
                } else { matches = tags.contains(value) }
                return negative ? !matches : matches
            }
        }
    }
    private static func rating(_ value: String) -> String {
        switch value {
        case "g", "general", "safe": return "g"
        case "s", "sensitive": return "s"
        case "q", "questionable": return "q"
        case "e", "explicit": return "e"
        default: return value
        }
    }
}

enum BooruError: LocalizedError {
    case validationRequired, invalidServer, invalidResponse, authentication, rateLimited, unavailable(Int), unsupported, duplicateServer, storage
    var errorDescription: String? {
        switch self {
        case .validationRequired: return L10n.text("The server requested browser verification. Use Validate Client and complete the check, then retry.")
        case .invalidServer: return L10n.text("Enter an HTTPS server address without a query or credentials.")
        case .invalidResponse: return L10n.text("The server returned an unsupported response. Check the server type and address.")
        case .authentication: return L10n.text("This server requires access. Check your account and API key in Servers.")
        case .rateLimited: return L10n.text("The server is busy. Wait a moment before trying again.")
        case .unavailable(let status): return L10n.text("Server error (%@). Please try again.", String(status))
        case .unsupported: return L10n.text("This server does not expose this feature.")
        case .duplicateServer: return L10n.text("This server address is already configured.")
        case .storage: return L10n.text("Unable to save. Please try again.")
        }
    }
}

struct BooruFolder: Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var color: Int64
    var displayName: String { id == "unsorted" ? L10n.text("Uncategorized") : BooruServer.displayName(name) }
}


extension BooruPost {
    func onServer(_ id: String) -> Self {
        Self(serverID: id, postID: postID, previewURL: previewURL, sampleURL: sampleURL, fileURL: fileURL, width: width, height: height, tags: tags, artists: artists, rating: rating, score: score, fileExtension: fileExtension, poolIDs: poolIDs, metadataTags: metadataTags, favoriteCount: favoriteCount, upvoteCount: upvoteCount, commentCount: commentCount)
    }
}

struct UnsupportedBooruSort: Error {}
enum BooruSortValidation {
    private static func isSortRejection(_ error: Error) -> Bool {
        guard let error = error as? BooruError else { return false }
        switch error { case .unsupported, .unavailable(400), .unavailable(422): return true; default: return false }
    }
    static func posts(source: any BooruProviding, server: BooruServer, query: String, page: Int, sort: BooruSort) async throws -> BooruBatch {
        guard BooruSort.options(for: server.engine).contains(sort) else { throw UnsupportedBooruSort() }
        guard sort != .latest else { return try await source.posts(server: server, query: query, page: page) }
        let sorted: BooruBatch
        do { sorted = try await source.posts(server: server, query: sort.query(query, engine: server.engine), page: page) }
        catch {
            try Task.checkCancellation()
            guard isSortRejection(error) else { throw error }
            // A successful identical query without the sort operator establishes
            // that the rejected condition was the sort, not an offline server.
            if let baseline = try? await source.posts(server: server, query: query, page: page), baseline.sourcePostCount > 0 { throw UnsupportedBooruSort() }
            throw error
        }
        if sorted.sourcePostCount == 0 && page == 0 && !sort.restrictsPeriod {
            let baseline = try await source.posts(server: server, query: query, page: page)
            if baseline.sourcePostCount > 0 { throw UnsupportedBooruSort() }
        }
        let scores = sorted.posts.compactMap { sort.metric($0) }
        if scores.count == sorted.posts.count && Set(scores).count > 1 && zip(scores, scores.dropFirst()).contains(where: { $0 < $1 }) { throw UnsupportedBooruSort() }
        return sorted
    }
}
