import Foundation

enum AppMode: String, CaseIterable, Identifiable {
    case hitomi, booru
    var id: String { rawValue }
    var title: String { self == .hitomi ? "Hitomi" : "Booru" }
}

enum BooruEngine: String, Codable, CaseIterable, Identifiable, Sendable {
    case danbooru, gelbooru, oldGelbooru, moebooru
    var id: String { rawValue }
    var title: String { self == .oldGelbooru ? "Old Gelbooru (v0.1.11)" : rawValue.capitalized }
    var usesGelbooruPages: Bool { self == .gelbooru || self == .oldGelbooru }
}

struct BooruServer: Codable, Identifiable, Hashable, Sendable {
    var id: String = UUID().uuidString
    var name: String
    var baseURL: URL
    var engine: BooruEngine
    var isGelbooruWebsite: Bool { engine == .gelbooru && ["gelbooru.com", "www.gelbooru.com"].contains(baseURL.host?.lowercased() ?? "") }
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
    var usesModernRatings: Bool { engine == .danbooru || isGelbooruWebsite }

    static let presets: [BooruServer] = [
        .init(id: "danbooru", name: "Danbooru", baseURL: URL(string: "https://danbooru.donmai.us")!, engine: .danbooru),
        .init(id: "gelbooru", name: "Gelbooru", baseURL: URL(string: "https://gelbooru.com")!, engine: .gelbooru),
        .init(id: "safebooru", name: "Safebooru", baseURL: URL(string: "https://safebooru.org")!, engine: .gelbooru)
    ]

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

enum BooruRating: String, CaseIterable, Identifiable, Sendable {
    case all, general, sensitive, questionable, explicit
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return L10n.text("All Ratings")
        case .general: return L10n.text("General / Safe")
        case .sensitive: return L10n.text("Sensitive")
        case .questionable: return L10n.text("Questionable")
        case .explicit: return L10n.text("Explicit")
        }
    }
    static func options(for servers: [BooruServer]) -> [Self] {
        allCases.filter { $0 != .sensitive || servers.allSatisfy(\.usesModernRatings) }
    }
    func query(_ input: String, server: BooruServer) -> String {
        // All means no generated rating tags and no client-side rejection of unrated legacy posts.
        guard self != .all else { return input }
        let value = self == .general && !server.usesModernRatings ? "safe" : rawValue
        let terms = input.split(whereSeparator: \.isWhitespace).filter { !$0.hasPrefix("rating:") && !$0.hasPrefix("-rating:") }
        return (terms.map(String.init) + ["rating:" + value]).joined(separator: " ")
    }
}

enum BooruSort: String, CaseIterable, Identifiable {
    case latest, popular
    var id: String { rawValue }
    var title: String { L10n.text(self == .latest ? "Latest" : "Popular") }
    func query(_ query: String, engine: BooruEngine) -> String {
        guard self == .popular else { return query }
        let terms = query.split(whereSeparator: \.isWhitespace).filter { !$0.hasPrefix("order:") && !$0.hasPrefix("sort:") }
        return (terms.map(String.init) + [engine == .gelbooru ? "sort:score:desc" : "order:score"]).joined(separator: " ")
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
    var id: String { "\(serverID):\(postID)" }
    var isVideo: Bool { ["mp4", "webm", "mov", "m4v"].contains(fileExtension.lowercased()) }
    var isAnimated: Bool { ["gif", "webp", "apng"].contains(fileExtension.lowercased()) || tags.contains("animated") }
    var displayURL: URL? { sampleURL ?? fileURL ?? previewURL }
}

struct BooruTag: Identifiable, Hashable, Sendable {
    let name: String
    let count: Int
    let category: Int
    var id: String { name }
    var isArtist: Bool { category == 1 }
}

struct BooruPool: Identifiable, Hashable, Sendable {
    let id: Int64
    var name: String
    var count: Int
    var description: String = ""
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
        let tags = Set(post.tags.map { $0.lowercased() })
        return rules.contains { rule in
            rule.allSatisfy { term in
                let negative = term.hasPrefix("-")
                let value = negative ? String(term.dropFirst()) : term
                let matches: Bool
                if value.hasPrefix("rating:") {
                    matches = Self.rating(String(value.dropFirst(7))) == Self.rating(post.rating)
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
    var displayName: String { id == "unsorted" ? L10n.text("Uncategorized") : name }
}


extension BooruPost {
    func onServer(_ id: String) -> Self {
        Self(serverID: id, postID: postID, previewURL: previewURL, sampleURL: sampleURL, fileURL: fileURL, width: width, height: height, tags: tags, artists: artists, rating: rating, score: score, fileExtension: fileExtension, poolIDs: poolIDs)
    }
}
