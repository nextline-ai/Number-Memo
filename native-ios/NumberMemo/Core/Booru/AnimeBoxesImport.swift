import Foundation
import GRDB

struct AnimeBoxesBackup: Sendable {
    struct Favorite: Sendable { let post: BooruPost; let savedAt: Double }
    struct Search: Sendable { let text: String; let date: Double; let starred: Bool }
    let servers: [BooruServer]
    let selectedIDs: [String]
    let favorites: [Favorite]
    let history: [Search]
    let blacklist: [String]
    let skippedServers: Int
    let skippedFavorites: Int
    let skippedHistory: Int
    let skippedRules: Int

    static func read(_ url: URL) throws -> Self {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 64 * 1024 * 1024 else { throw AnimeBoxesImportError.tooLarge }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try parse(data)
    }

    static func parse(_ data: Data) throws -> Self {
        guard data.count <= 64 * 1024 * 1024 else { throw AnimeBoxesImportError.tooLarge }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawServers = root["servers"] as? [[String: Any]],
              let rawFavorites = root["favorites"] as? [[String: Any]],
              let version = root["backupVersion"] as? String, version == "1.0" else { throw AnimeBoxesImportError.format }
        var servers: [BooruServer] = [], selected: [String] = [], favorites: [Favorite] = []
        var skippedServers = 0, skippedFavorites = 0
        for row in rawServers {
            guard let url = baseURL(row["url"] as? String ?? ""), let host = url.host else { skippedServers += 1; continue }
            let engine: BooruEngine
            switch integer(row["type"]) {
            case 1: engine = host.hasSuffix(".booru.org") ? .oldGelbooru : .gelbooru
            case 4: engine = .oldGelbooru
            case 3: engine = .danbooru
            default:
                if ["yande.re", "konachan.com", "konachan.net"].contains(host) { engine = .moebooru }
                else { skippedServers += 1; continue }
            }
            let existing = servers.first { $0.canonicalAddress == BooruServer.canonicalAddress(url) }
            let server = existing ?? BooruServer(name: (row["serverName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? host, baseURL: url, engine: engine)
            if existing == nil { servers.append(server) }
            if row["isSelected"] as? Bool == true { selected.append(server.id) }
        }
        let formatter = ISO8601DateFormatter()
        func date(_ raw: Any?) -> Double { (raw as? String).flatMap(formatter.date(from:))?.timeIntervalSince1970 ?? 0 }
        var seen = Set<String>()
        for row in rawFavorites {
            guard let postID = integer(row["ppostId"]), postID > 0,
                  let page = URL(string: row["ppostUrl"] as? String ?? ""),
                  let server = servers.filter({ BooruServer.canonicalAddress(page).hasPrefix($0.canonicalAddress + "/") || BooruServer.canonicalAddress(page) == $0.canonicalAddress }).max(by: { $0.baseURL.path.count < $1.baseURL.path.count }) else { skippedFavorites += 1; continue }
            let file = row["file"] as? [String: Any] ?? [:]
            let preview = row["preview"] as? [String: Any] ?? [:]
            let sample = row["sample"] as? [String: Any] ?? [:]
            let jpeg = row["jpeg"] as? [String: Any] ?? [:]
            let fileURL = mediaURL(file["url"], base: server.baseURL)
            let tags = tokens(row["tags"])
            let post = BooruPost(serverID: server.id, postID: postID,
                                 previewURL: mediaURL(preview["url"], base: server.baseURL),
                                 sampleURL: mediaURL(sample["url"], base: server.baseURL) ?? mediaURL(jpeg["url"], base: server.baseURL), fileURL: fileURL,
                                 width: max(0, Int(integer(file["width"]) ?? 0)), height: max(0, Int(integer(file["height"]) ?? 0)),
                                 tags: tags, artists: tokens(row["tag_artist"]), rating: !server.usesModernRatings && row["rating"] as? String == "s" ? "g" : row["rating"] as? String ?? "",
                                 score: Int(integer(row["score"]) ?? 0), fileExtension: (file["ext"] as? String ?? fileURL?.pathExtension ?? "").lowercased())
            if seen.insert(post.id).inserted { favorites.append(.init(post: post, savedAt: date(row["dateAdded"]))) }
        }
        let rawHistory = root["searchHistory"] as? [[String: Any]] ?? []
        let history: [Search] = rawHistory.compactMap {
            guard let text = $0["searchText"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return Search(text: text, date: date($0["searchDate"]), starred: $0["starred"] as? Bool ?? false)
        }
        let rawRules = root["bannedTags"] as? [Any] ?? []
        let blacklist: [String] = rawRules.compactMap {
            if let value = $0 as? String { return value.isEmpty ? nil : value }
            if let row = $0 as? [String: Any], let value = (row["tag"] ?? row["name"]) as? String { return value.isEmpty ? nil : value }
            return nil
        }
        return Self(servers: servers, selectedIDs: selected, favorites: favorites, history: history, blacklist: blacklist,
                    skippedServers: skippedServers, skippedFavorites: skippedFavorites, skippedHistory: rawHistory.count - history.count, skippedRules: rawRules.count - blacklist.count)
    }

    private static func integer(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber { return number.int64Value }
        return (value as? String).flatMap(Int64.init)
    }
    private static func tokens(_ value: Any?) -> [String] {
        if let values = value as? [String] { return values }
        return (value as? String ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
    }
    private static func baseURL(_ raw: String) -> URL? {
        guard !raw.isEmpty else { return nil }
        let secure = raw.hasPrefix("http://") ? "https://" + raw.dropFirst(7) : raw
        return try? BooruServer.validatedURL(secure)
    }
    private static func mediaURL(_ raw: Any?, base: URL) -> URL? {
        guard let raw = raw as? String, !raw.isEmpty,
              let url = URL(string: raw, relativeTo: base)?.absoluteURL,
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: true),
              ["https", "http"].contains(parts.scheme), parts.host != nil, parts.user == nil, parts.password == nil else { return nil }
        parts.scheme = "https"
        return parts.url
    }
}

enum AnimeBoxesImportError: LocalizedError {
    case format, tooLarge, noServers
    var errorDescription: String? {
        switch self {
        case .format: return L10n.text("Choose an Anime Boxes .abbj backup (version 1.0).")
        case .tooLarge: return L10n.text("This backup exceeds the 64 MB import limit.")
        case .noServers: return L10n.text("This backup contains no supported servers.")
        }
    }
}

struct AnimeBoxesImportOptions: Sendable {
    var history = true
    var blacklist = true
    var selection = true
    var folderID = "anime-boxes"
}
struct AnimeBoxesImportResult: Sendable {
    let added: Int
    let duplicates: Int
    let serversAdded: Int
}

extension BooruStore {
    /// The entire merge commits together. Existing favorites keep their folder and original saved date.
    func importAnimeBoxes(_ backup: AnimeBoxesBackup, options: AnimeBoxesImportOptions) throws -> AnimeBoxesImportResult {
        guard !backup.servers.isEmpty else { throw AnimeBoxesImportError.noServers }
        let result = try database.write { db in
            var existing = try Row.fetchAll(db, sql: "SELECT payload FROM servers ORDER BY position").map { try JSONDecoder().decode(BooruServer.self, from: $0["payload"] as Data) }
            var mapping: [String: String] = [:]
            var serverCount = 0
            for imported in backup.servers {
                if let match = existing.first(where: { $0.canonicalAddress == imported.canonicalAddress }) { mapping[imported.id] = match.id }
                else {
                    try db.execute(sql: "INSERT INTO servers VALUES (?, ?, ?)", arguments: [imported.id, try JSONEncoder().encode(imported), existing.count])
                    mapping[imported.id] = imported.id; existing.append(imported); serverCount += 1
                }
            }
            if options.folderID == "anime-boxes" {
                try db.execute(sql: "INSERT OR IGNORE INTO folders VALUES ('anime-boxes', 'Anime Boxes', 4287784115, (SELECT COUNT(*) FROM folders))")
            }
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM folders WHERE id = ?)", arguments: [options.folderID]) == true else { throw BooruError.invalidResponse }
            var added = 0, duplicates = 0
            for favorite in backup.favorites {
                let old = favorite.post
                guard let id = mapping[old.serverID] else { continue }
                let post = BooruPost(serverID: id, postID: old.postID, previewURL: old.previewURL, sampleURL: old.sampleURL, fileURL: old.fileURL, width: old.width, height: old.height, tags: old.tags, artists: old.artists, rating: old.rating, score: old.score, fileExtension: old.fileExtension, poolIDs: old.poolIDs)
                try db.execute(sql: "INSERT OR IGNORE INTO favorites (server_id, post_id, payload, saved_at, folder_id) VALUES (?, ?, ?, ?, ?)", arguments: [id, post.postID, try JSONEncoder().encode(post), favorite.savedAt, options.folderID])
                if db.changesCount > 0 { added += 1 } else { duplicates += 1 }
            }
            for id in Set(mapping.values) {
                if options.history {
                    for search in backup.history {
                        try db.execute(sql: "INSERT INTO history VALUES (?, ?, ?) ON CONFLICT(server_id, query) DO UPDATE SET used_at = MAX(used_at, excluded.used_at)", arguments: [id, search.text, search.date])
                        if search.starred { try db.execute(sql: "INSERT OR IGNORE INTO saved_tags VALUES (?, ?, 'search')", arguments: [id, search.text]) }
                    }
                }
                if options.blacklist, !backup.blacklist.isEmpty {
                    let old = try String.fetchOne(db, sql: "SELECT value FROM settings WHERE key = ?", arguments: ["blacklist." + id]) ?? ""
                    var seen = Set<String>()
                    let merged = (old.components(separatedBy: .newlines) + backup.blacklist).filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: "\n")
                    try db.execute(sql: "INSERT OR REPLACE INTO settings VALUES (?, ?)", arguments: ["blacklist." + id, merged])
                }
            }
            if options.selection {
                let ids = backup.selectedIDs.compactMap { mapping[$0] }
                if !ids.isEmpty { try db.execute(sql: "INSERT OR REPLACE INTO settings VALUES ('selected_servers', ?)", arguments: [String(decoding: JSONEncoder().encode(ids), as: UTF8.self)]) }
            }
            return AnimeBoxesImportResult(added: added, duplicates: duplicates, serversAdded: serverCount)
        }
        try refresh()
        return result
    }
}
