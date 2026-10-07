import Foundation

enum ContentError: LocalizedError {
    case invalidResponse, unsupportedFormat, tooLarge, unavailable(Int), invalidQuery

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return L10n.text("Unable to read the response. Please try again shortly.")
        case .unsupportedFormat: return L10n.text("The service format has changed or this image is unsupported.")
        case .tooLarge: return L10n.text("The requested data is too large. Narrow your search.")
        case .unavailable(404): return L10n.text("This work was removed or could not be found.")
        case .unavailable(403): return L10n.text("The image server declined the request. Try again shortly.")
        case .unavailable: return L10n.text("Unable to connect to the server. Try again shortly.")
        case .invalidQuery: return L10n.text("Check your search. Separate terms with spaces and join words within a tag with underscores.")
        }
    }

    static func message(_ error: Error) -> String {
        if let error = error as? ContentError { return error.localizedDescription }
        if let error = error as? URLError, error.code == .notConnectedToInternet {
            return L10n.text("Check your internet connection.")
        }
        return L10n.text("Unable to load. Check your connection and try again.")
    }
}

struct GalleryPage: Sendable, Hashable {
    let hash: String
    let name: String
    let width: Int
    let height: Int
    let hasAVIF: Bool
}

struct NativeGallery: Identifiable, Sendable {
    let id: Int64
    let title: String
    let artists: [String]
    let language: String
    let type: String
    let tags: [String]
    let pages: [GalleryPage]

    static func parse(_ data: Data, id: Int64) throws -> NativeGallery {
        guard id > 0, data.count <= 4_000_000, var text = String(data: data, encoding: .utf8) else {
            throw ContentError.invalidResponse
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = #"^var\s+galleryinfo\s*=\s*"#
        guard let match = text.range(of: prefix, options: .regularExpression) else { throw ContentError.unsupportedFormat }
        text.removeSubrange(match)
        if text.hasSuffix(";") { text.removeLast() }
        guard let jsonData = text.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let files = json["files"] as? [[String: Any]], !files.isEmpty, files.count <= 10_000 else {
            throw ContentError.invalidResponse
        }
        let pages = try files.map { file -> GalleryPage in
            guard let hash = file["hash"] as? String,
                  hash.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil,
                  let name = file["name"] as? String, !name.isEmpty else { throw ContentError.unsupportedFormat }
            return GalleryPage(hash: hash, name: name,
                               width: (file["width"] as? NSNumber)?.intValue ?? 0,
                               height: (file["height"] as? NSNumber)?.intValue ?? 0,
                               hasAVIF: (file["hasavif"] as? NSNumber)?.boolValue ?? false)
        }
        let japanese = (json["japanese_title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = japanese?.isEmpty == false ? japanese! : (json["title"] as? String ?? L10n.text("Work %@", String(describing: id)))
        return NativeGallery(id: id, title: decodeEntities(title),
                             artists: (json["artists"] as? [[String: Any]] ?? []).compactMap { $0["artist"] as? String },
                             language: json["language"] as? String ?? "", type: json["type"] as? String ?? "",
                             tags: Self.parseTags(json["tags"]), pages: pages)
    }

    static func parseTags(_ value: Any?) -> [String] {
        (value as? [[String: Any]] ?? []).flatMap { item -> [String] in
            guard let tag = item["tag"] as? String else { return [] }
            let namespaces = ["female", "male"].filter { flag(item[$0]) }
            return (namespaces.isEmpty ? ["tag"] : namespaces).map { $0 + ":" + tag }
        }
    }

    private static func flag(_ value: Any?) -> Bool {
        if let number = value as? NSNumber { return number.boolValue }
        return ["1", "true"].contains((value as? String ?? "").lowercased())
    }

    static func decodeEntities(_ input: String) -> String {
        let named = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " "]
        let regex = try! NSRegularExpression(pattern: #"&(#x[0-9a-fA-F]+|#[0-9]+|[a-z]+);"#)
        let source = input as NSString
        var result = input
        for match in regex.matches(in: input, range: NSRange(location: 0, length: source.length)).reversed() {
            let token = source.substring(with: match.range(at: 1))
            var replacement = named[token]
            if token.hasPrefix("#") {
                let hex = token.hasPrefix("#x")
                if let code = UInt32(token.dropFirst(hex ? 2 : 1), radix: hex ? 16 : 10), let scalar = UnicodeScalar(code) {
                    replacement = String(scalar)
                }
            }
            if let replacement, let range = Range(match.range, in: result) { result.replaceSubrange(range, with: replacement) }
        }
        return result
    }
}

struct GalleryQuery: Hashable, Sendable {
    var language = "korean"
    var artist: String? = nil
    var text = ""
    var sort = GallerySort.latest

    func applyingDefaults(tags: String, excluded: String) -> Self {
        var result = self
        let explicit = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let includes = tags.split(whereSeparator: \.isWhitespace).map(String.init)
        let excludes = excluded.split(whereSeparator: \.isWhitespace).map { "-" + $0.drop(while: { $0 == "-" }) }
        var seen = Set<String>()
        result.text = (explicit + includes + excludes).filter { seen.insert($0).inserted }.joined(separator: " ")
        return result
    }
}

enum GallerySort: String, CaseIterable, Identifiable, Sendable {
    case latest, today, week, month, year
    var id: String { rawValue }
    var title: String {
        switch self {
        case .latest: return L10n.text("Latest")
        case .today: return L10n.text("Popular Today")
        case .week: return L10n.text("Popular This Week")
        case .month: return L10n.text("Popular This Month")
        case .year: return L10n.text("Popular This Year")
        }
    }
}

struct GalleryBatch: Sendable {
    let ids: [Int64]
    let hasMore: Bool
}

protocol ContentProviding: Sendable {
    func suggestions(for token: String) async throws -> [TagSuggestion]
    func gallery(_ id: Int64) async throws -> NativeGallery
    func list(_ query: GalleryQuery, offset: Int, count: Int) async throws -> GalleryBatch
    func image(_ page: GalleryPage, galleryID: Int64, thumbnail: Bool) async throws -> Data
}

enum ContentRoute: Hashable {
    case discoveredGallery(Int64, DiscoveryContext)
    case discoveredReader(Int64, Int, DiscoveryContext)
    case gallery(Int64)
    case reader(Int64, Int)
    case artist(String)
    case query(String)

    static func initial(_ raw: String) -> ContentRoute? {
        guard let url = URL(string: raw), url.scheme == "https", url.host?.lowercased() == "hitomi.la" else { return nil }
        if let id = GalleryIDParser.parse(raw).first {
            if url.path.hasPrefix("/reader/") { return .reader(id, max(1, Int(url.fragment ?? "1") ?? 1)) }
            return .gallery(id)
        }
        if url.path.hasPrefix("/artist/"), url.lastPathComponent.hasSuffix("-all.html") {
            return .artist(String(url.lastPathComponent.dropLast("-all.html".count)))
        }
        return nil
    }
}


extension ContentProviding {
    func suggestions(for token: String) async throws -> [TagSuggestion] { [] }
}

struct TagSuggestion: Identifiable, Equatable, Sendable {
    let namespace: String
    let name: String
    let count: Int
    var id: String { token }
    var token: String { namespace + ":" + name.replacingOccurrences(of: " ", with: "_") }
    static let namespaces: Set<String> = ["female", "male", "tag", "artist", "group", "series", "character", "language", "type"]
    static func parse(_ data: Data) throws -> [Self] {
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[Any]], rows.count <= 100 else { throw ContentError.invalidResponse }
        var seen = Set<String>()
        return rows.compactMap { row in
            guard row.count == 3, let name = row[0] as? String, !name.isEmpty, name.count <= 120,
                  name.rangeOfCharacter(from: .newlines) == nil,
                  let count = row[1] as? Int, count >= 0, let namespace = row[2] as? String,
                  namespaces.contains(namespace) else { return nil }
            let item = Self(namespace: namespace, name: name, count: count)
            return seen.insert(item.id).inserted ? item : nil
        }
    }
}

struct TagCompletionContext: Equatable {
    let prefix: String
    let excluded: Bool
    let token: String
    init?(_ input: String) {
        guard !input.isEmpty, input.last?.isWhitespace == false,
              let tail = input.split(whereSeparator: \.isWhitespace).last else { return nil }
        prefix = String(input.dropLast(tail.count))
        excluded = tail.hasPrefix("-")
        token = String(excluded ? tail.dropFirst() : tail[...]).lowercased()
        let pieces = token.split(separator: ":", omittingEmptySubsequences: false)
        guard pieces.count <= 2, token.count <= 120,
              pieces.count == 1 || TagSuggestion.namespaces.contains(String(pieces[0])),
              let term = pieces.last, term.count >= 2, term.count <= 64,
              !term.allSatisfy({ $0.isNumber }), !term.contains("/"), !term.contains("\"") else { return nil }
    }
    func inserting(_ suggestion: TagSuggestion) -> String { prefix + (excluded ? "-" : "") + suggestion.token + " " }
}
