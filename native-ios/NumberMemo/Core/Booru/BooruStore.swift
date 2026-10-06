import Foundation
import GRDB
import Observation
import Security

/// A separate database, unrelated to Hitomi's migrations, imports and backups.
@Observable
final class BooruStore: @unchecked Sendable {
    let database: DatabaseQueue
    private(set) var servers: [BooruServer] = []
    private(set) var selectedServerID = ""
    private(set) var selectedServerIDs: [String] = []
    var selectedServers: [BooruServer] { servers.filter { selectedServerIDs.contains($0.id) } }
    private(set) var revision = 0
    var error: String?
    var selectedServer: BooruServer? { servers.first { $0.id == selectedServerID } ?? servers.first }

    init(path: String? = nil) throws {
        database = try path.map { try DatabaseQueue(path: $0) } ?? DatabaseQueue()
        var migrations = DatabaseMigrator()
        migrations.registerMigration("booru_v1") { db in
            try db.execute(sql: """
                CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                CREATE TABLE servers (id TEXT PRIMARY KEY, payload BLOB NOT NULL, position INTEGER NOT NULL);
                CREATE TABLE favorites (server_id TEXT NOT NULL, post_id INTEGER NOT NULL, payload BLOB NOT NULL, saved_at DOUBLE NOT NULL, PRIMARY KEY(server_id, post_id));
                CREATE TABLE history (server_id TEXT NOT NULL, query TEXT NOT NULL, used_at DOUBLE NOT NULL, PRIMARY KEY(server_id, query));
                CREATE TABLE saved_tags (server_id TEXT NOT NULL, name TEXT NOT NULL, kind TEXT NOT NULL, PRIMARY KEY(server_id, name, kind));
                CREATE INDEX favorite_date ON favorites(server_id, saved_at DESC);
                """)
            // Servers are added only by explicit address entry, import, or library sync.
        }
        migrations.registerMigration("booru_v2_folders") { db in
            try db.execute(sql: """
                CREATE TABLE folders (id TEXT PRIMARY KEY, name TEXT NOT NULL, color INTEGER NOT NULL, position INTEGER NOT NULL);
                INSERT INTO folders VALUES ('unsorted', '', 4284922736, 0);
                ALTER TABLE favorites ADD COLUMN folder_id TEXT NOT NULL DEFAULT 'unsorted';
                CREATE INDEX favorite_folder ON favorites(folder_id, saved_at DESC);
                """)
        }
        migrations.registerMigration("booru_v3_legacy_engine") { db in
            for row in try Row.fetchAll(db, sql: "SELECT id, payload FROM servers") {
                var server = try JSONDecoder().decode(BooruServer.self, from: row["payload"] as Data)
                if server.engine == .gelbooru, server.baseURL.host?.hasSuffix(".booru.org") == true {
                    server.engine = .oldGelbooru
                    try db.execute(sql: "UPDATE servers SET payload = ? WHERE id = ?", arguments: [try JSONEncoder().encode(server), server.id])
                }
            }
        }
        migrations.registerMigration("booru_v4_canonical_servers") { db in
            let servers = try Row.fetchAll(db, sql: "SELECT payload FROM servers ORDER BY position").map { try JSONDecoder().decode(BooruServer.self, from: $0["payload"] as Data) }
            var identities: [String: String] = [:]
            for server in servers {
                guard let target = identities[server.canonicalAddress] else { identities[server.canonicalAddress] = server.id; continue }
                for row in try Row.fetchAll(db, sql: "SELECT * FROM favorites WHERE server_id = ?", arguments: [server.id]) {
                    let post = try JSONDecoder().decode(BooruPost.self, from: row["payload"] as Data).onServer(target)
                    try db.execute(sql: "INSERT OR IGNORE INTO favorites VALUES (?, ?, ?, ?, ?)", arguments: [target, post.postID, try JSONEncoder().encode(post), row["saved_at"] as Double, row["folder_id"] as String])
                }
                try db.execute(sql: "INSERT OR IGNORE INTO history SELECT ?, query, used_at FROM history WHERE server_id = ?", arguments: [target, server.id])
                try db.execute(sql: "INSERT OR IGNORE INTO saved_tags SELECT ?, name, kind FROM saved_tags WHERE server_id = ?", arguments: [target, server.id])
                let oldKey = "blacklist." + server.id, newKey = "blacklist." + target
                if let rules = try String.fetchOne(db, sql: "SELECT value FROM settings WHERE key = ?", arguments: [oldKey]) {
                    let existing = try String.fetchOne(db, sql: "SELECT value FROM settings WHERE key = ?", arguments: [newKey]) ?? ""
                    try db.execute(sql: "INSERT OR REPLACE INTO settings VALUES (?, ?)", arguments: [newKey, [existing, rules].filter { !$0.isEmpty }.joined(separator: "\n")])
                }
                for table in ["favorites", "history", "saved_tags"] { try db.execute(sql: "DELETE FROM \(table) WHERE server_id = ?", arguments: [server.id]) }
                try db.execute(sql: "DELETE FROM settings WHERE key = ?", arguments: [oldKey])
                try db.execute(sql: "DELETE FROM servers WHERE id = ?", arguments: [server.id])
                if let raw = try String.fetchOne(db, sql: "SELECT value FROM settings WHERE key = 'selected_servers'"), let data = raw.data(using: .utf8), let ids = try? JSONDecoder().decode([String].self, from: data) {
                    let mapped = Array(Set(ids.map { $0 == server.id ? target : $0 }))
                    try db.execute(sql: "UPDATE settings SET value = ? WHERE key = 'selected_servers'", arguments: [String(decoding: try JSONEncoder().encode(mapped), as: UTF8.self)])
                }
            }
        }
        migrations.registerMigration("booru_v5_site_folders") { db in
            for row in try Row.fetchAll(db, sql: "SELECT payload FROM servers") {
                let server = try JSONDecoder().decode(BooruServer.self, from: row["payload"] as Data)
                let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM favorites WHERE server_id = ? AND folder_id = 'unsorted'", arguments: [server.id]) ?? 0
                if count > 0 {
                    let folder = try Self.defaultFolder(for: server.id, db: db)
                    try db.execute(sql: "UPDATE favorites SET folder_id = ? WHERE server_id = ? AND folder_id = 'unsorted'", arguments: [folder, server.id])
                }
            }
        }
        try migrations.migrate(database)
        try reload()
    }

    static func open() throws -> BooruStore {
        try BooruStore(path: AppStorage.sharedContainerURL.appendingPathComponent("booru.sqlite").path)
    }

    func reload() throws {
        servers = try database.read { db in
            try Row.fetchAll(db, sql: "SELECT payload FROM servers ORDER BY position").map {
                try JSONDecoder().decode(BooruServer.self, from: $0["payload"] as Data)
            }
        }
        let legacy = try setting("selected_server") ?? servers.first?.id ?? ""
        let saved = try setting("selected_servers").flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? [legacy]
        selectedServerIDs = servers.map(\.id).filter(saved.contains)
        if selectedServerIDs.isEmpty, let first = servers.first { selectedServerIDs = [first.id] }
        selectedServerID = selectedServerIDs.first ?? ""
    }

    func refresh() throws { try reload(); revision += 1 }

    func perform(_ operation: () throws -> Void) {
        do { try operation() } catch { self.error = error.localizedDescription }
    }

    /// Explicit single-server selection is used for links/setup; toolbar selection is additive.
    func select(_ server: BooruServer) throws { try setSelectedServers([server.id]) }

    func toggleServer(_ server: BooruServer) throws {
        var ids = selectedServerIDs
        if ids.contains(server.id) { ids.removeAll { $0 == server.id } }
        else { ids.append(server.id) }
        guard !ids.isEmpty else { return }
        try setSelectedServers(ids)
    }

    func setSelectedServers(_ ids: [String]) throws {
        let valid = servers.map(\.id).filter(ids.contains)
        guard !valid.isEmpty || servers.isEmpty else { return }
        try setSetting("selected_servers", value: String(decoding: JSONEncoder().encode(valid), as: UTF8.self))
        selectedServerIDs = valid
        selectedServerID = valid.first ?? ""
    }

    func saveServer(_ server: BooruServer) throws {
        guard !servers.contains(where: { $0.id != server.id && $0.canonicalAddress == server.canonicalAddress }) else { throw BooruError.duplicateServer }
        let position = servers.firstIndex(where: { $0.id == server.id }) ?? servers.count
        try database.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO servers VALUES (?, ?, ?)", arguments: [server.id, try JSONEncoder().encode(server), position])
        }
        try reload()
        revision += 1
    }

    func deleteServer(_ server: BooruServer) throws {
        try BooruKeychain.save(.init(), serverID: server.id)
        try database.write { db in
            try db.execute(sql: "DELETE FROM servers WHERE id = ?", arguments: [server.id])
            for table in ["favorites", "history", "saved_tags"] {
                try db.execute(sql: "DELETE FROM \(table) WHERE server_id = ?", arguments: [server.id])
            }
            try db.execute(sql: "DELETE FROM settings WHERE key = ?", arguments: ["blacklist." + server.id])
        }
        try reload()
        if !servers.contains(where: { $0.id == selectedServerID }) { selectedServerID = servers.first?.id ?? "" }
        revision += 1
    }

    func favorites(serverID: String) -> [BooruPost] {
        _ = revision
        do {
            return try database.read { db in
                try Row.fetchAll(db, sql: "SELECT payload FROM favorites WHERE server_id = ? ORDER BY saved_at DESC", arguments: [serverID]).map {
                    try JSONDecoder().decode(BooruPost.self, from: $0["payload"] as Data)
                }
            }
        } catch { return [] }
    }

    /// Read once by the grid's body so lazy cells observe imports and restored data.
    var favoriteIDs: Set<String> {
        _ = revision
        return (try? database.read { db in
            Set(try Row.fetchAll(db, sql: "SELECT server_id, post_id FROM favorites").map { row in
                let serverID: String = row["server_id"]
                let postID: Int64 = row["post_id"]
                return "\(serverID):\(postID)"
            })
        }) ?? []
    }

    func isFavorite(_ post: BooruPost) -> Bool {
        _ = revision
        return (try? database.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM favorites WHERE server_id = ? AND post_id = ?)", arguments: [post.serverID, post.postID]) ?? false
        }) ?? false
    }

    func toggleFavorite(_ post: BooruPost) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM favorites WHERE server_id = ? AND post_id = ?", arguments: [post.serverID, post.postID])
            if db.changesCount == 0 {
                let folder = try Self.defaultFolder(for: post.serverID, db: db)
                try db.execute(sql: "INSERT INTO favorites (server_id, post_id, payload, saved_at, folder_id) VALUES (?, ?, ?, ?, ?)", arguments: [post.serverID, post.postID, try JSONEncoder().encode(post), Date().timeIntervalSince1970, folder])
            }
        }
        revision += 1
    }

    func favorites(serverIDs: [String], folderID: String? = nil) -> [BooruPost] {
        _ = revision
        guard !serverIDs.isEmpty else { return [] }
        return (try? database.read { db in
            let placeholders = serverIDs.map { _ in "?" }.joined(separator: ",")
            let sql = "SELECT payload FROM favorites WHERE server_id IN (\(placeholders))" + (folderID == nil ? "" : " AND folder_id = ?") + " ORDER BY saved_at DESC"
            let args = StatementArguments(serverIDs + (folderID.map { [$0] } ?? []))
            return try Row.fetchAll(db, sql: sql, arguments: args).map { try JSONDecoder().decode(BooruPost.self, from: $0["payload"] as Data) }
        }) ?? []
    }

    func folders() -> [BooruFolder] {
        _ = revision
        return (try? database.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM folders ORDER BY position, name").map {
                BooruFolder(id: $0["id"], name: $0["name"], color: $0["color"])
            }
        }) ?? []
    }

    @discardableResult func saveFolder(id: String = UUID().uuidString, name: String, color: Int64? = nil) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, id != "unsorted" else { throw BooruError.invalidResponse }
        try database.write { db in
            let existing = try Int64.fetchOne(db, sql: "SELECT color FROM folders WHERE id = ?", arguments: [id])
            let resolved = try color ?? existing ?? AppDatabase.nextFolderColor(existingColors: Int64.fetchAll(db, sql: "SELECT color FROM folders"))
            try db.execute(sql: "INSERT INTO folders VALUES (?, ?, ?, (SELECT COUNT(*) FROM folders)) ON CONFLICT(id) DO UPDATE SET name = excluded.name, color = excluded.color", arguments: [id, name, resolved])
        }
        revision += 1
        return id
    }

    func deleteFolder(_ id: String) throws {
        guard id != "unsorted" else { return }
        try database.write { db in
            try db.execute(sql: "UPDATE favorites SET folder_id = 'unsorted' WHERE folder_id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM folders WHERE id = ?", arguments: [id])
        }
        revision += 1
    }

    func folderID(for post: BooruPost) -> String? {
        _ = revision
        return try? database.read { try String.fetchOne($0, sql: "SELECT folder_id FROM favorites WHERE server_id = ? AND post_id = ?", arguments: [post.serverID, post.postID]) }
    }

    func saveFavorite(_ post: BooruPost, folderID: String? = nil) throws {
        try database.write { db in
            let existing = try String.fetchOne(db, sql: "SELECT folder_id FROM favorites WHERE server_id = ? AND post_id = ?", arguments: [post.serverID, post.postID])
            let folderID = try folderID ?? existing ?? Self.defaultFolder(for: post.serverID, db: db)
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM folders WHERE id = ?)", arguments: [folderID]) == true else { throw BooruError.invalidResponse }
            try db.execute(sql: "INSERT INTO favorites (server_id, post_id, payload, saved_at, folder_id) VALUES (?, ?, ?, ?, ?) ON CONFLICT(server_id, post_id) DO UPDATE SET payload = excluded.payload, folder_id = excluded.folder_id", arguments: [post.serverID, post.postID, try JSONEncoder().encode(post), Date().timeIntervalSince1970, folderID])
        }
        revision += 1
    }

    static func defaultFolder(for serverID: String, db: Database) throws -> String {
        guard let data = try Data.fetchOne(db, sql: "SELECT payload FROM servers WHERE id = ?", arguments: [serverID]) else { throw BooruError.invalidServer }
        let server = try JSONDecoder().decode(BooruServer.self, from: data)
        // Canonical address is stable across devices and server ID remapping.
        let id = "site:" + server.canonicalAddress
        if try String.fetchOne(db, sql: "SELECT id FROM folders WHERE id = ?", arguments: [id]) == nil {
            let color = try AppDatabase.nextFolderColor(existingColors: Int64.fetchAll(db, sql: "SELECT color FROM folders"))
            try db.execute(sql: "INSERT INTO folders VALUES (?, ?, ?, (SELECT COUNT(*) FROM folders))", arguments: [id, server.name, color])
        }
        return id
    }

    func history(serverID: String) -> [String] {
        _ = revision
        return (try? database.read { db in
            try String.fetchAll(db, sql: "SELECT query FROM history WHERE server_id = ? AND used_at >= ? ORDER BY used_at DESC LIMIT 500", arguments: [serverID, SearchRetention.cutoff(booru: true)])
        }) ?? []
    }

    func recordSearch(_ query: String, serverID: String) throws {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        try database.write { db in
            try db.execute(sql: "DELETE FROM history WHERE used_at < ?", arguments: [SearchRetention.cutoff(booru: true)])
            try db.execute(sql: "INSERT OR REPLACE INTO history VALUES (?, ?, ?)", arguments: [serverID, value, Date().timeIntervalSince1970])
            try db.execute(sql: "DELETE FROM history WHERE server_id = ? AND query NOT IN (SELECT query FROM history WHERE server_id = ? ORDER BY used_at DESC LIMIT 500)", arguments: [serverID, serverID])
        }
        revision += 1
    }

    func clearHistory(serverID: String) throws {
        try database.write { try $0.execute(sql: "DELETE FROM history WHERE server_id = ?", arguments: [serverID]) }
        revision += 1
    }

    func savedTags(serverID: String, kind: String = "tag") -> [String] {
        _ = revision
        return (try? database.read { try String.fetchAll($0, sql: "SELECT name FROM saved_tags WHERE server_id = ? AND kind = ? ORDER BY name", arguments: [serverID, kind]) }) ?? []
    }

    func toggleTag(_ name: String, serverID: String, kind: String = "tag") throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM saved_tags WHERE server_id = ? AND name = ? AND kind = ?", arguments: [serverID, name, kind])
            if db.changesCount == 0 { try db.execute(sql: "INSERT INTO saved_tags VALUES (?, ?, ?)", arguments: [serverID, name, kind]) }
        }
        revision += 1
    }

    func blacklist(serverID: String) -> String {
        _ = revision
        return (try? setting("blacklist." + serverID)) ?? ""
    }
    func setBlacklist(_ text: String, serverID: String) throws { try setSetting("blacklist." + serverID, value: text) }
    func setting(_ key: String) throws -> String? {
        try database.read { try String.fetchOne($0, sql: "SELECT value FROM settings WHERE key = ?", arguments: [key]) }
    }
    func setSetting(_ key: String, value: String) throws {
        try database.write { try $0.execute(sql: "INSERT OR REPLACE INTO settings VALUES (?, ?)", arguments: [key, value]) }
        revision += 1
    }
}

/// API keys never enter SQLite, preferences, media requests, exports or logs.
enum BooruKeychain {
    private static let service = "com.deaum.numbermemo.booru"
    static func read(serverID: String) throws -> BooruCredentials {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: serverID, kSecReturnData as String: true]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return .init() }
        guard status == errSecSuccess, let data = result as? Data else { throw BooruError.storage }
        return try JSONDecoder().decode(BooruCredentials.self, from: data)
    }
    static func save(_ credentials: BooruCredentials, serverID: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: serverID]
        if credentials.isEmpty {
            let result = SecItemDelete(query as CFDictionary)
            guard result == errSecSuccess || result == errSecItemNotFound else { throw BooruError.storage }
            return
        }
        let data = try JSONEncoder().encode(credentials)
        let result = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if result == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw BooruError.storage }
        } else if result != errSecSuccess { throw BooruError.storage }
    }
}
