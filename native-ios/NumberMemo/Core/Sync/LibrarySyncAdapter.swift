import Foundation
import GRDB

/// Explicit allowlists keep caches, API keys, cookies, onboarding and device layout local.
struct LibrarySyncAdapter {
    let hitomi: AppDatabase
    let booru: BooruStore
    let hitomiDefaults: UserDefaults
    let booruDefaults: UserDefaults
    static let commonPreferences = ["app.language", "app_theme", "booru.app_theme", "hitomi.defaultTags", "hitomi.defaultExcludedTags", "search.retentionDays", "reader.translationLanguage"]
    static let booruPreferences = ["search.retentionDays", "reader.translationLanguage", "booru.rememberHistory", "booru.rating", "booru.showNotes"]
    static let columns: [String: [String]] = [
        "hitomi.library_order": ["key", "value"],
        "hitomi.folders": ["sync_id", "name", "description", "color", "sort_order", "created_at", "violet_group_id"],
        "hitomi.works": ["gallery_id", "title", "artists", "language", "type", "series", "groups", "tags", "note", "bookmarked_at", "published_at", "metadata_source", "catalog_matched", "thumb_page"],
        "hitomi.folder_works": ["folder_id", "work_id", "added_at"],
        "hitomi.artists": ["name", "kind", "note", "bookmarked_at"],
        "hitomi.search_history": ["query", "used_at"], "hitomi.saved_searches": ["query"],
        "booru.servers": ["id", "payload", "position"], "booru.folders": ["id", "name", "color", "position"],
        "booru.favorites": ["server_id", "post_id", "payload", "saved_at", "folder_id"],
        "booru.history": ["server_id", "query", "used_at"], "booru.saved_tags": ["server_id", "name", "kind"],
        "booru.settings": ["key", "value"]
    ]

    func snapshot() throws -> [String: LibrarySyncRow] {
        // Also assigns identities to legacy imports and share-extension-created folders.
        try hitomi.dbWriter.write { db in
            for row in try Row.fetchAll(db, sql: "SELECT id, name FROM folders WHERE sync_id IS NULL") {
                let name: String = row["name"]
                try db.execute(sql: "UPDATE folders SET sync_id = ? WHERE id = ?", arguments: [name == "미분류" ? "unsorted" : UUID().uuidString, row["id"] as Int64])
            }
        }
        var rows = try hitomi.dbWriter.read { db -> [LibrarySyncRow] in
            var result: [LibrarySyncRow] = []
            for (table, columns) in Self.columns where table.hasPrefix("hitomi.") {
                let local = String(table.dropFirst(7))
                let sql = local == "folder_works"
                    ? "SELECT f.sync_id AS folder_id, w.gallery_id AS work_id, fw.added_at FROM folder_works fw JOIN folders f ON f.id = fw.folder_id JOIN works w ON w.id = fw.work_id"
                    : "SELECT \(columns.joined(separator: ",")) FROM \(local)"
                result += try Row.fetchAll(db, sql: sql).map { row in
                    LibrarySyncRow(table: table, values: Dictionary(uniqueKeysWithValues: columns.map { ($0, SyncValue(row[$0] as DatabaseValue)) }))
                }
            }
            return result
        }
        rows += try booru.database.read { db -> [LibrarySyncRow] in
            let servers = try Row.fetchAll(db, sql: "SELECT payload FROM servers").map { try JSONDecoder().decode(BooruServer.self, from: $0["payload"] as Data) }
            let addresses = Dictionary(uniqueKeysWithValues: servers.map { ($0.id, $0.canonicalAddress) })
            var result: [LibrarySyncRow] = []
            for (table, columns) in Self.columns where table.hasPrefix("booru.") {
                let local = String(table.dropFirst(6))
                for row in try Row.fetchAll(db, sql: "SELECT \(columns.joined(separator: ",")) FROM \(local)") {
                    var values = Dictionary(uniqueKeysWithValues: columns.map { ($0, SyncValue(row[$0] as DatabaseValue)) })
                    if local == "servers", let raw = values["payload"]?.data {
                        var server = try JSONDecoder().decode(BooruServer.self, from: raw)
                        server.id = server.canonicalAddress
                        values["id"] = .text(server.id); values["payload"] = .blob(try Self.encode(server))
                    }
                    if let id = values["server_id"]?.string, let address = addresses[id] {
                        values["server_id"] = .text(address)
                        if let raw = values["payload"]?.data {
                            let post = try JSONDecoder().decode(BooruPost.self, from: raw).onServer(address)
                            values["payload"] = .blob(try Self.encode(post))
                        }
                    }
                    if local == "settings", values["key"]?.string != "folder_order" {
                        guard let key = values["key"]?.string, key.hasPrefix("blacklist."), let address = addresses[String(key.dropFirst(10))] else { continue }
                        values["key"] = .text("blacklist." + address)
                    }
                    result.append(.init(table: table, values: values))
                }
            }
            return result
        }
        for (mode, defaults, keys) in [("hitomi", hitomiDefaults, Self.commonPreferences), ("booru", booruDefaults, Self.booruPreferences)] {
            for key in keys {
                if let value = defaults.object(forKey: key) {
                    let data = try PropertyListSerialization.data(fromPropertyList: ["value": value], format: .binary, options: 0)
                    rows.append(.init(table: "preferences." + mode, values: ["key": .text(key), "value": .blob(data)]))
                }
            }
        }
        return Dictionary(rows.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func apply(_ changes: [String: LibrarySyncChange]) throws {
        let values = Array(changes.values)
        try hitomi.dbWriter.write { db in
            // Remove dependent links before parents; never replace a whole database.
            for table in ["folder_works", "artists", "works", "folders", "search_history", "saved_searches", "library_order"] {
                for change in values where change.deleted && change.row.table == "hitomi." + table {
                    var row = change.row
                    if table == "folders", row.values["sync_id"]?.string == "unsorted" { continue }
                    if table == "folder_works" {
                        guard let folder = try localFolder(row.values["folder_id"], db), let work = try localWork(row.values["work_id"], db) else { continue }
                        row.values["folder_id"] = .integer(folder); row.values["work_id"] = .integer(work)
                    }
                    try Self.delete(row, db: db)
                }
            }
            for table in ["folders", "works", "artists", "folder_works", "search_history", "saved_searches", "library_order"] {
                for change in values.sorted(by: { $0.row.key < $1.row.key }) where !change.deleted && change.row.table == "hitomi." + table {
                    var row = change.row
                    if table == "folders", let uid = row.values["sync_id"]?.string, let name = row.values["name"]?.string {
                        if let conflict = try String.fetchOne(db, sql: "SELECT sync_id FROM folders WHERE name = ?", arguments: [name]), conflict != uid {
                            row.values["name"] = .text(name + " (" + String(uid.prefix(8)) + ")")
                        }
                    }
                    if table == "folder_works" {
                        guard let folder = try localFolder(row.values["folder_id"], db), let work = try localWork(row.values["work_id"], db) else { continue }
                        row.values["folder_id"] = .integer(folder); row.values["work_id"] = .integer(work)
                    }
                    try Self.upsert(row, db: db)
                }
            }
            if let data = try Data.fetchOne(db, sql: "SELECT value FROM library_order WHERE key = 'folders'"), let order = try? JSONDecoder().decode([String].self, from: data) {
                let others = try String.fetchAll(db, sql: "SELECT sync_id FROM folders ORDER BY sort_order, id").filter { !order.contains($0) }
                for (position, uid) in (order + others).enumerated() { try db.execute(sql: "UPDATE folders SET sort_order = ? WHERE sync_id = ?", arguments: [position, uid]) }
            }
            // Concurrent folder deletion cannot orphan an independently saved work.
            if let unfiled = try Int64.fetchOne(db, sql: "SELECT id FROM folders WHERE sync_id = 'unsorted'") {
                try db.execute(sql: "INSERT OR IGNORE INTO folder_works SELECT ?, id, bookmarked_at FROM works WHERE id NOT IN (SELECT work_id FROM folder_works)", arguments: [unfiled])
            }
        }
        try booru.database.write { db in
            var servers = try Row.fetchAll(db, sql: "SELECT payload FROM servers").map { try JSONDecoder().decode(BooruServer.self, from: $0["payload"] as Data) }
            var mapping = Dictionary(servers.map { ($0.canonicalAddress, $0.id) }, uniquingKeysWith: { a, _ in a })
            for change in values where change.row.table == "booru.servers" {
                guard let address = change.row.values["id"]?.string else { continue }
                if change.deleted {
                    if let id = mapping[address] {
                        for table in ["favorites", "history", "saved_tags"] { try db.execute(sql: "DELETE FROM \(table) WHERE server_id = ?", arguments: [id]) }
                        try db.execute(sql: "DELETE FROM servers WHERE id = ?", arguments: [id])
                        mapping.removeValue(forKey: address)
                    }
                } else if let data = change.row.values["payload"]?.data {
                    var server = try JSONDecoder().decode(BooruServer.self, from: data)
                    _ = try BooruServer.validatedURL(server.baseURL.absoluteString)
                    guard server.canonicalAddress == address else { throw BooruError.invalidServer }
                    server.id = mapping[address] ?? UUID().uuidString
                    mapping[address] = server.id
                    var row = change.row; row.values["id"] = .text(server.id); row.values["payload"] = .blob(try Self.encode(server))
                    try Self.upsert(row, db: db)
                }
            }
            servers.removeAll()
            for table in ["folders", "favorites", "history", "saved_tags", "settings"] {
                for change in values where change.row.table == "booru." + table {
                    var row = change.row
                    if table == "folders", row.values["id"]?.string == "unsorted", change.deleted { continue }
                    if let address = row.values["server_id"]?.string {
                        guard let id = mapping[address] else { continue }
                        row.values["server_id"] = .text(id)
                        if let data = row.values["payload"]?.data {
                            row.values["payload"] = .blob(try Self.encode(JSONDecoder().decode(BooruPost.self, from: data).onServer(id)))
                        }
                    }
                    if table == "settings", row.values["key"]?.string != "folder_order" {
                        guard let key = row.values["key"]?.string, key.hasPrefix("blacklist."), let id = mapping[String(key.dropFirst(10))] else { continue }
                        row.values["key"] = .text("blacklist." + id)
                    }
                    if change.deleted {
                        if table == "folders", let id = row.values["id"]?.string {
                            try db.execute(sql: "UPDATE favorites SET folder_id = 'unsorted' WHERE folder_id = ?", arguments: [id])
                        }
                        try Self.delete(row, db: db)
                    } else {
                        if table == "favorites", let id = row.values["folder_id"]?.string, try String.fetchOne(db, sql: "SELECT id FROM folders WHERE id = ?", arguments: [id]) == nil { row.values["folder_id"] = .text("unsorted") }
                        try Self.upsert(row, db: db)
                    }
                }
            }
            if let text = try String.fetchOne(db, sql: "SELECT value FROM settings WHERE key = 'folder_order'"), let order = try? JSONDecoder().decode([String].self, from: Data(text.utf8)) {
                let others = try String.fetchAll(db, sql: "SELECT id FROM folders ORDER BY position, name").filter { !order.contains($0) }
                for (position, id) in (order + others).enumerated() { try db.execute(sql: "UPDATE folders SET position = ? WHERE id = ?", arguments: [position, id]) }
            }
        }
        for change in values where change.row.table.hasPrefix("preferences.") {
            let isBooru = change.row.table == "preferences.booru"
            guard let key = change.row.values["key"]?.string, (isBooru ? Self.booruPreferences : Self.commonPreferences).contains(key) else { continue }
            let defaults = isBooru ? booruDefaults : hitomiDefaults
            if change.deleted { defaults.removeObject(forKey: key) }
            else if let data = change.row.values["value"]?.data, let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] { defaults.set(plist["value"], forKey: key) }
        }
    }
    private func localFolder(_ value: SyncValue?, _ db: Database) throws -> Int64? {
        guard let uid = value?.string else { return nil }
        return try Int64.fetchOne(db, sql: "SELECT id FROM folders WHERE sync_id = ?", arguments: [uid])
    }
    private func localWork(_ value: SyncValue?, _ db: Database) throws -> Int64? {
        guard let id = value?.integer else { return nil }
        return try Int64.fetchOne(db, sql: "SELECT id FROM works WHERE gallery_id = ?", arguments: [id])
    }
    private static func upsert(_ row: LibrarySyncRow, db: Database) throws {
        guard let allowed = columns[row.table], let keys = LibrarySyncRow.keys[row.table], Set(row.values.keys).isSubset(of: Set(allowed)), keys.allSatisfy({ row.values[$0] != nil }) else { throw BooruError.invalidResponse }
        let fields = allowed.filter { row.values[$0] != nil }
        let updates = fields.filter { !keys.contains($0) }.map { "\($0) = excluded.\($0)" }.joined(separator: ",")
        let sql = "INSERT INTO \(row.table.split(separator: ".")[1]) (\(fields.joined(separator: ","))) VALUES (\(fields.map { _ in "?" }.joined(separator: ","))) ON CONFLICT(\(keys.joined(separator: ","))) DO " + (updates.isEmpty ? "NOTHING" : "UPDATE SET " + updates)
        try db.execute(sql: sql, arguments: StatementArguments(fields.map { row.values[$0]!.databaseValue }))
    }
    private static func delete(_ row: LibrarySyncRow, db: Database) throws {
        guard let keys = LibrarySyncRow.keys[row.table], columns[row.table] != nil else { throw BooruError.invalidResponse }
        try db.execute(sql: "DELETE FROM \(row.table.split(separator: ".")[1]) WHERE \(keys.map { $0 + " = ?" }.joined(separator: " AND "))", arguments: StatementArguments(keys.map { row.values[$0]?.databaseValue ?? .null }))
    }
    private static func encode<T: Encodable>(_ value: T) throws -> Data { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(value) }
}
