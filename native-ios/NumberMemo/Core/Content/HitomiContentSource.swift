import Foundation
import CryptoKit

actor HitomiContentSource: ContentProviding {
    static let shared = HitomiContentSource()
    private let transport: ContentTransport
    private let base = "https://ltn.gold-usergeneratedcontent.net/"
    private var documents: [Int64: (NativeGallery, Date)] = [:]
    private var routing: (CDNRouting, Date)?
    private var routingTask: Task<CDNRouting, Error>?
    private var suggestionCache: [String: ([TagSuggestion], Date)] = [:]
    private var searchCache: (GalleryQuery, [Int64], Date)?

    init(transport: ContentTransport = .shared) { self.transport = transport }

    func suggestions(for token: String) async throws -> [TagSuggestion] {
        guard let context = TagCompletionContext(token) else { return [] }
        let key = context.token
        if let cached = suggestionCache[key], Date().timeIntervalSince(cached.1) < 900 { return cached.0 }
        let target = try Self.suggestionURL(key)
        let items: [TagSuggestion]
        do {
            let (data, response) = try await transport.get(target, limit: 64_000)
            guard response.statusCode == 200 else { throw ContentError.invalidResponse }
            items = try TagSuggestion.parse(data)
        } catch ContentError.unavailable(404) { items = [] }
        try Task.checkCancellation()
        if suggestionCache.count >= 64, let oldest = suggestionCache.min(by: { $0.value.1 < $1.value.1 })?.key {
            suggestionCache.removeValue(forKey: oldest)
        }
        suggestionCache[key] = (items, Date())
        return items
    }

    static func suggestionURL(_ token: String) throws -> URL {
        guard let context = TagCompletionContext(token) else { throw ContentError.invalidQuery }
        let parts = context.token.split(separator: ":", maxSplits: 1).map(String.init)
        let field = parts.count == 2 ? parts[0] : "global"
        let term = parts.last!.replacingOccurrences(of: "_", with: " ")
        let chars = term.map { character -> String in
            let value = character == " " ? "_" : character == "." ? "dot" : String(character)
            return value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        }.joined(separator: "/")
        guard let url = URL(string: "https://tagindex.hitomi.la/" + field + "/" + chars + ".json") else { throw ContentError.invalidQuery }
        return url
    }

    func gallery(_ id: Int64) async throws -> NativeGallery {
        guard id > 0 else { throw ContentError.invalidQuery }
        if let (value, date) = documents[id], Date().timeIntervalSince(date) < 600 { return value }
        let (data, _) = try await transport.get(url("galleries/\(id).js"), limit: 4_000_000, galleryID: id)
        let document = try NativeGallery.parse(data, id: id)
        if documents.count >= 64, let oldest = documents.min(by: { $0.value.1 < $1.value.1 })?.key {
            documents.removeValue(forKey: oldest)
        }
        documents[id] = (document, Date())
        return document
    }

    func list(_ query: GalleryQuery, offset: Int, count: Int) async throws -> GalleryBatch {
        guard query.language.range(of: #"^[a-z]{2,24}$"#, options: .regularExpression) != nil,
              offset >= 0, offset < 10_000_000, (1...100).contains(count) else { throw ContentError.invalidQuery }
        if !query.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (query.artist != nil && query.sort != .latest) {
            let ids: [Int64]
            if let cached = searchCache, cached.0 == query, Date().timeIntervalSince(cached.2) < 300 {
                ids = cached.1
            } else {
                var ranked = try await search(query)
                if query.sort != .latest {
                    let matches = Set(ranked)
                    ranked = try await fullList("popular/\(query.sort.rawValue)-\(query.language).nozomi").filter { matches.contains($0) }
                }
                ids = ranked
                try Task.checkCancellation()
                searchCache = (query, ids, Date())
            }
            return GalleryBatch(ids: Array(ids.dropFirst(offset).prefix(count)), hasMore: ids.count > offset + count)
        }
        let path = query.sort != .latest ? "popular/\(query.sort.rawValue)-\(query.language).nozomi" : query.artist.map { "artist/\(segment($0))-\(query.language).nozomi" } ?? "index-\(query.language).nozomi"
        let range = (offset * 4)..<((offset + count) * 4)
        let (data, response) = try await transport.get(url(path), limit: count * 4, range: range)
        if response.statusCode == 416 { return GalleryBatch(ids: [], hasMore: false) }
        let total = try Self.validateRange(response, start: range.lowerBound, received: data.count)
        return GalleryBatch(ids: try BinaryCursor.ids(data), hasMore: range.lowerBound + data.count < total)
    }

    func image(_ page: GalleryPage, galleryID: Int64, thumbnail: Bool) async throws -> Data {
        let formats = page.hasAVIF ? ["webp", "avif"] : ["webp"]
        var lastError: Error = ContentError.unsupportedFormat
        for refresh in [false, true] {
            let configuration = try await currentRouting(force: refresh)
            for format in formats {
                do {
                    let imageURL = try configuration.url(hash: page.hash, format: format, thumbnail: thumbnail)
                    let (data, response) = try await transport.get(imageURL, limit: thumbnail ? 2_000_000 : 24_000_000, galleryID: galleryID)
                    guard response.statusCode == 200,
                          response.mimeType == "image/\(format)", data.count > 32 else { throw ContentError.unsupportedFormat }
                    return data
                } catch {
                    try Task.checkCancellation()
                    lastError = error
                    // Only stale routing / missing representation merits a format or routing retry.
                    guard case ContentError.unavailable(let status) = error, [403, 404].contains(status) else { throw error }
                }
            }
        }
        throw lastError
    }

    private func currentRouting(force: Bool) async throws -> CDNRouting {
        if !force, let (value, date) = routing, Date().timeIntervalSince(date) < 300 { return value }
        if let task = routingTask { return try await task.value }
        let transport = transport
        let target = url("gg.js")
        let task = Task {
            let (data, _) = try await transport.get(target, limit: 100_000)
            guard let text = String(data: data, encoding: .utf8) else { throw ContentError.invalidResponse }
            return try CDNRouting(text)
        }
        routingTask = task
        do {
            let value = try await task.value
            routing = (value, Date())
            routingTask = nil
            return value
        } catch { routingTask = nil; throw error }
    }

    private func search(_ query: GalleryQuery) async throws -> [Int64] {
        let tokens = query.text.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard (!tokens.isEmpty || query.artist != nil), tokens.count <= 8, tokens.allSatisfy({ $0.count <= 120 && !$0.contains("\"") }) else {
            throw ContentError.invalidQuery
        }
        let (versionData, _) = try await transport.get(url("galleriesindex/version"), limit: 64)
        let version = String(decoding: versionData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard version.range(of: #"^[0-9]{1,20}$"#, options: .regularExpression) != nil else { throw ContentError.unsupportedFormat }
        var included: Set<Int64>?
        var excluded = Set<Int64>()
        for token in tokens {
            try Task.checkCancellation()
            let isExcluded = token.hasPrefix("-")
            let term = String(isExcluded ? token.dropFirst() : token[...]).replacingOccurrences(of: "_", with: " ")
            guard !term.isEmpty else { throw ContentError.invalidQuery }
            let ids: [Int64]
            if let colon = term.firstIndex(of: ":") {
                let field = String(term[..<colon])
                let value = String(term[term.index(after: colon)...])
                guard ["artist", "group", "series", "character", "tag", "type", "female", "male", "language"].contains(field), !value.isEmpty else {
                    throw ContentError.invalidQuery
                }
                let path: String
                if field == "language" { path = "index-\(segment(value)).nozomi" }
                else if ["female", "male"].contains(field) { path = "tag/\(segment(term))-all.nozomi" }
                else { path = "\(field)/\(segment(value))-all.nozomi" }
                ids = try await fullList(path)
            } else { ids = try await keyword(term, version: version) }
            let matches = Set(ids)
            if isExcluded { excluded.formUnion(matches) }
            else { included = included.map { $0.intersection(matches) } ?? matches }
        }
        if let artist = query.artist {
            let matches = Set(try await fullList("artist/\(segment(artist))-\(query.language).nozomi"))
            included = included.map { $0.intersection(matches) } ?? matches
        } else if query.language != "all" || included == nil {
            let matches = Set(try await fullList("index-\(query.language).nozomi"))
            included = included.map { $0.intersection(matches) } ?? matches
        }
        return (included ?? []).subtracting(excluded).sorted(by: >)
    }

    private func fullList(_ path: String) async throws -> [Int64] {
        do {
            let (data, response) = try await transport.get(url(path), limit: 8_000_000)
            guard response.statusCode == 200 else { throw ContentError.invalidResponse }
            return try BinaryCursor.ids(data)
        } catch ContentError.unavailable(404) { return [] }
    }

    private func keyword(_ term: String, version: String) async throws -> [Int64] {
        let key = Array(SHA256.hash(data: Data(term.utf8)).prefix(4))
        var address = 0
        var visited = Set<Int>()
        for _ in 0..<32 {
            guard visited.insert(address).inserted, address <= Int.max - 464 else { throw ContentError.invalidResponse }
            let nodeData = try await readRange("galleriesindex/galleries.\(version).index", range: address..<(address + 464))
            let node = try SearchIndexNode(nodeData)
            if node.keys.isEmpty { return [] }
            var position = 0
            while position < node.keys.count && node.keys[position].lexicographicallyPrecedes(key) { position += 1 }
            if position < node.keys.count && node.keys[position] == key {
                let location = node.locations[position]
                guard location.length >= 4, location.length <= 8_000_000,
                      location.offset <= Int.max - location.length else { throw ContentError.tooLarge }
                let data = try await readRange("galleriesindex/galleries.\(version).data", range: location.offset..<(location.offset + location.length))
                var reader = BinaryCursor(data)
                let count = try reader.u32()
                guard count <= 2_000_000, data.count == 4 + count * 4 else { throw ContentError.invalidResponse }
                return try BinaryCursor.ids(Data(data.dropFirst(4)))
            }
            guard position < node.children.count else { throw ContentError.invalidResponse }
            address = node.children[position]
            if address == 0 { return [] }
        }
        throw ContentError.invalidResponse
    }

    private func readRange(_ path: String, range: Range<Int>) async throws -> Data {
        let (data, response) = try await transport.get(url(path), limit: range.count, range: range)
        _ = try Self.validateRange(response, start: range.lowerBound, received: data.count)
        guard data.count == range.count else { throw ContentError.invalidResponse }
        return data
    }

    static func validateRange(_ response: HTTPURLResponse, start: Int, received: Int) throws -> Int {
        guard response.statusCode == 206, received > 0,
              let header = response.value(forHTTPHeaderField: "Content-Range"),
              let match = header.range(of: #"^bytes [0-9]+-[0-9]+/[0-9]+$"#, options: .regularExpression), match == header.startIndex..<header.endIndex else {
            throw ContentError.invalidResponse
        }
        let parts = header.dropFirst(6).split(whereSeparator: { $0 == "-" || $0 == "/" }).compactMap { Int($0) }
        guard parts.count == 3, parts[0] == start, parts[1] >= start, parts[1] < parts[2],
              parts[1] - start + 1 == received else { throw ContentError.invalidResponse }
        return parts[2]
    }

    private func url(_ path: String) -> URL { URL(string: base + path)! }
    private func segment(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_"))) ?? ""
    }
}

struct BinaryCursor {
    let data: Data
    var offset = 0
    init(_ data: Data) { self.data = data }
    mutating func bytes(_ count: Int) throws -> [UInt8] {
        guard count >= 0, offset <= data.count, count <= data.count - offset else { throw ContentError.invalidResponse }
        defer { offset += count }
        return Array(data[offset..<(offset + count)])
    }
    mutating func u32() throws -> Int { try bytes(4).reduce(0) { ($0 << 8) | Int($1) } }
    mutating func u64() throws -> Int {
        let value = try bytes(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        guard value <= UInt64(Int.max) else { throw ContentError.invalidResponse }
        return Int(value)
    }
    static func ids(_ data: Data) throws -> [Int64] {
        guard data.count % 4 == 0 else { throw ContentError.invalidResponse }
        var reader = BinaryCursor(data)
        return try (0..<(data.count / 4)).map { _ in
            let value = try reader.u32()
            guard value > 0 else { throw ContentError.invalidResponse }
            return Int64(value)
        }
    }
}

struct SearchIndexNode {
    let keys: [[UInt8]]
    let locations: [(offset: Int, length: Int)]
    let children: [Int]
    init(_ data: Data) throws {
        var reader = BinaryCursor(data)
        let count = try reader.u32()
        guard count <= 16 else { throw ContentError.invalidResponse }
        keys = try (0..<count).map { _ in
            let length = try reader.u32()
            guard length == 4 else { throw ContentError.unsupportedFormat }
            return try reader.bytes(length)
        }
        guard try reader.u32() == count else { throw ContentError.invalidResponse }
        locations = try (0..<count).map { _ in (try reader.u64(), try reader.u32()) }
        children = try (0..<17).map { _ in try reader.u64() }
    }
}
