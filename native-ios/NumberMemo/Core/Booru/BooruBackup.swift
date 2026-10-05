import Foundation
import GRDB

/// Portable library data only. Credentials, cookies, caches and device preferences stay local.
struct BooruBackup: Codable, Sendable {
    struct Folder: Codable, Sendable { var id: String; var name: String; var color: Int64 }
    struct Favorite: Codable, Sendable { var post: BooruPost; var folderID: String; var savedAt: Double }
    struct Search: Codable, Sendable { var serverID: String; var query: String; var usedAt: Double }
    struct Tag: Codable, Sendable { var serverID: String; var name: String; var kind: String }
    var format = "number-memo-image-library"
    var version = 1
    var exportedAt = Date()
    var servers: [BooruServer]
    var folders: [Folder]
    var favorites: [Favorite]
    var history: [Search]
    var savedTags: [Tag]
    var blacklist: [String: String]
    var selectedServerIDs: [String]

    static func read(_ url: URL) throws -> Self {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 64 * 1024 * 1024 else { throw BooruError.invalidResponse }
        return try decode(Data(contentsOf: url))
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 64 * 1024 * 1024 else { throw BooruError.invalidResponse }
        let value = try JSONDecoder().decode(Self.self, from: data)
        try value.validate()
        return value
    }

    func validate() throws {
        for server in servers { _ = try BooruServer.validatedURL(server.baseURL.absoluteString) }
        let serverIDs = Set(servers.map(\.id)), folderIDs = Set(folders.map(\.id))
        guard format == "number-memo-image-library", version == 1,
              serverIDs.count == servers.count, folderIDs.count == folders.count,
              folderIDs.contains("unsorted"), servers.allSatisfy({ !$0.id.isEmpty }),
              folders.allSatisfy({ !$0.id.isEmpty && (0...0xFFFFFFFF).contains($0.color) && ($0.id == "unsorted" || !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }),
              Set(servers.map(\.canonicalAddress)).count == servers.count,
              Set(favorites.map { $0.post.id }).count == favorites.count,
              favorites.allSatisfy({ serverIDs.contains($0.post.serverID) && folderIDs.contains($0.folderID) && $0.post.postID > 0 && $0.savedAt.isFinite }),
              history.allSatisfy({ serverIDs.contains($0.serverID) && !$0.query.isEmpty && $0.usedAt.isFinite }),
              savedTags.allSatisfy({ serverIDs.contains($0.serverID) && !$0.name.isEmpty && ["tag", "artist", "search"].contains($0.kind) }),
              Set(blacklist.keys).isSubset(of: serverIDs), Set(selectedServerIDs).isSubset(of: serverIDs)
        else { throw BooruError.invalidResponse }
        for server in servers { _ = try BooruServer.validatedURL(server.baseURL.absoluteString) }
        for favorite in favorites {
            for url in [favorite.post.previewURL, favorite.post.sampleURL, favorite.post.fileURL].compactMap({ $0 }) {
                guard ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil, url.user == nil, url.password == nil else { throw BooruError.invalidResponse }
            }
        }
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}

extension BooruStore {
    func exportBackup() throws -> BooruBackup {
        try database.read { db in
            let servers = try Row.fetchAll(db, sql: "SELECT payload FROM servers ORDER BY position").map { try JSONDecoder().decode(BooruServer.self, from: $0["payload"] as Data) }
            let folders = try Row.fetchAll(db, sql: "SELECT * FROM folders ORDER BY position, name").map { BooruBackup.Folder(id: $0["id"], name: $0["name"], color: $0["color"]) }
            let favorites = try Row.fetchAll(db, sql: "SELECT * FROM favorites ORDER BY saved_at DESC").map { BooruBackup.Favorite(post: try JSONDecoder().decode(BooruPost.self, from: $0["payload"] as Data), folderID: $0["folder_id"], savedAt: $0["saved_at"]) }
            let history = try Row.fetchAll(db, sql: "SELECT * FROM history WHERE used_at >= ? ORDER BY used_at DESC", arguments: [SearchRetention.cutoff(booru: true)]).map { BooruBackup.Search(serverID: $0["server_id"], query: $0["query"], usedAt: $0["used_at"]) }
            let tags = try Row.fetchAll(db, sql: "SELECT * FROM saved_tags ORDER BY server_id, kind, name").map { BooruBackup.Tag(serverID: $0["server_id"], name: $0["name"], kind: $0["kind"]) }
            var blacklist: [String: String] = [:]
            for server in servers { blacklist[server.id] = try String.fetchOne(db, sql: "SELECT value FROM settings WHERE key = ?", arguments: ["blacklist." + server.id]) ?? "" }
            return BooruBackup(servers: servers, folders: folders, favorites: favorites, history: history, savedTags: tags, blacklist: blacklist, selectedServerIDs: selectedServerIDs)
        }
    }

    /// Merge atomically; repeated imports never duplicate servers, folders or favorites.
    /// The backup restores colors, folder membership and ordering without deleting other items.
    func restoreBackup(_ backup: BooruBackup) throws {
        try backup.validate()
        try database.write { db in
            let existing = try Row.fetchAll(db, sql: "SELECT payload FROM servers ORDER BY position").map { try JSONDecoder().decode(BooruServer.self, from: $0["payload"] as Data) }
            var mapping: [String: String] = [:]
            for source in backup.servers {
                if let match = existing.first(where: { $0.canonicalAddress == source.canonicalAddress }) { mapping[source.id] = match.id }
                else {
                    var server = source
                    if existing.contains(where: { $0.id == server.id }) { server.id = UUID().uuidString }
                    mapping[source.id] = server.id
                    try db.execute(sql: "INSERT INTO servers VALUES (?, ?, (SELECT COUNT(*) FROM servers))", arguments: [server.id, try JSONEncoder().encode(server)])
                }
            }
            let incomingOrder = backup.folders.map(\.id)
            let remaining = try String.fetchAll(db, sql: "SELECT id FROM folders ORDER BY position, name").filter { !incomingOrder.contains($0) }
            for (position, folder) in backup.folders.enumerated() {
                try db.execute(sql: "INSERT INTO folders VALUES (?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET name = excluded.name, color = excluded.color, position = excluded.position", arguments: [folder.id, folder.id == "unsorted" ? "" : folder.name, folder.color, position])
            }
            for (position, id) in (incomingOrder + remaining).enumerated() {
                try db.execute(sql: "UPDATE folders SET position = ? WHERE id = ?", arguments: [position, id])
            }
            try db.execute(sql: "INSERT OR REPLACE INTO settings VALUES ('folder_order', ?)", arguments: [String(decoding: JSONEncoder().encode(incomingOrder + remaining), as: UTF8.self)])
            for value in backup.favorites {
                let post = value.post.onServer(mapping[value.post.serverID]!)
                try db.execute(sql: "INSERT INTO favorites VALUES (?, ?, ?, ?, ?) ON CONFLICT(server_id, post_id) DO UPDATE SET payload = excluded.payload, saved_at = excluded.saved_at, folder_id = excluded.folder_id", arguments: [post.serverID, post.postID, try JSONEncoder().encode(post), value.savedAt, value.folderID])
            }
            for value in backup.history {
                try db.execute(sql: "INSERT INTO history VALUES (?, ?, ?) ON CONFLICT(server_id, query) DO UPDATE SET used_at = MAX(used_at, excluded.used_at)", arguments: [mapping[value.serverID]!, value.query, value.usedAt])
            }
            for value in backup.savedTags {
                try db.execute(sql: "INSERT OR IGNORE INTO saved_tags VALUES (?, ?, ?)", arguments: [mapping[value.serverID]!, value.name, value.kind])
            }
            for (id, rules) in backup.blacklist {
                try db.execute(sql: "INSERT OR REPLACE INTO settings VALUES (?, ?)", arguments: ["blacklist." + mapping[id]!, rules])
            }
            if !backup.selectedServerIDs.isEmpty {
                try db.execute(sql: "INSERT OR REPLACE INTO settings VALUES ('selected_servers', ?)", arguments: [String(decoding: JSONEncoder().encode(backup.selectedServerIDs.compactMap { mapping[$0] }), as: UTF8.self)])
            }
        }
        try refresh()
    }
}
