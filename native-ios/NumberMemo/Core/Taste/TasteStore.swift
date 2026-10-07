import Foundation
import GRDB

/// Analysis tables live beside each mode's library, so a save and its evidence commit together.
struct TasteStore: Sendable {
    let database: any DatabaseWriter
    let mode: TasteMode
    static func migrate(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE taste_events (id TEXT PRIMARY KEY, epoch TEXT NOT NULL, generation TEXT NOT NULL, at DOUBLE NOT NULL, kind TEXT NOT NULL, work_key TEXT NOT NULL, payload BLOB NOT NULL, uploaded INTEGER NOT NULL DEFAULT 0);
            CREATE INDEX taste_events_period ON taste_events(epoch, at);
            CREATE INDEX taste_events_work ON taste_events(work_key, at);
            CREATE INDEX taste_events_pending ON taste_events(uploaded, at);
            CREATE TABLE taste_meta (key TEXT PRIMARY KEY, value BLOB NOT NULL);
            CREATE TABLE taste_reports (id TEXT PRIMARY KEY, payload BLOB NOT NULL, uploaded INTEGER NOT NULL DEFAULT 0);
            """)
        let device = UUID().uuidString
        var control = TasteControl(); control.author = device
        try put(control, key: "control", db: db)
        try put(device, key: "device", db: db)
    }
    static func get<T: Decodable>(_ type: T.Type, key: String, db: Database) throws -> T? {
        try Data.fetchOne(db, sql: "SELECT value FROM taste_meta WHERE key = ?", arguments: [key]).map { try JSONDecoder().decode(type, from: $0) }
    }
    static func put<T: Encodable>(_ value: T, key: String, db: Database) throws {
        try db.execute(sql: "INSERT OR REPLACE INTO taste_meta VALUES (?, ?)", arguments: [key, try JSONEncoder().encode(value)])
    }
    static func control(_ db: Database) throws -> TasteControl { try get(TasteControl.self, key: "control", db: db) ?? .init() }
    func savedKeys() throws -> Set<String> {
        try database.read { db in
            if mode == .comics { return Set(try Int64.fetchAll(db, sql: "SELECT gallery_id FROM works").map { TasteItem.comic($0).key }) }
            let servers = try Data.fetchAll(db, sql: "SELECT payload FROM servers").map { try JSONDecoder().decode(BooruServer.self, from: $0) }
            let addresses = Dictionary(servers.map { ($0.id, $0.canonicalAddress) }, uniquingKeysWith: { first, _ in first })
            return Set(try Row.fetchAll(db, sql: "SELECT server_id, post_id FROM favorites").compactMap { row in
                guard let source = addresses[row["server_id"] as String] else { return nil }
                return source + "#" + String(row["post_id"] as Int64)
            })
        }
    }
    func control() throws -> TasteControl { try database.read { try Self.control($0) } }
    func setControl(_ value: TasteControl, remote: Bool = false) throws {
        try database.write { db in
            let old = try Self.control(db)
            if old.epoch != value.epoch {
                try db.execute(sql: "DELETE FROM taste_events; DELETE FROM taste_reports;")
                try Self.put(true, key: "bootstrapped", db: db)
            } else if remote && old.generation != value.generation {
                // A peer that missed a pause must not upload activity collected under the old permission.
                try db.execute(sql: "DELETE FROM taste_events WHERE uploaded = 0")
            }
            try Self.put(value, key: "control", db: db)
        }
    }
    static func record(_ kind: TasteEvent.Kind, item: TasteItem, context: DiscoveryContext = .unknown, db: Database, at: Date = Date()) throws {
        let control = try control(db)
        guard control.enabled else { return }
        if kind == .metadata {
            if let data = try Data.fetchOne(db, sql: "SELECT payload FROM taste_events WHERE work_key = ? AND kind IN ('save','seed','imported','metadata') ORDER BY at DESC, id DESC LIMIT 1", arguments: [item.key]),
               let last = try? JSONDecoder().decode(TasteEvent.self, from: data), last.item == item { return }
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM taste_events WHERE work_key = ? AND kind IN ('save','seed','imported'))", arguments: [item.key]) == true else { return }
        }
        var event = TasteEvent(kind: kind, item: item, context: context)
        event.at = at.timeIntervalSince1970; event.epoch = control.epoch; event.generation = control.generation
        event.device = try get(String.self, key: "device", db: db) ?? ""
        if kind == .seed { event.id = "seed-" + tasteDigest(Data((control.epoch + item.key).utf8)); event.at = 0 }
        if kind == .taxonomy { event.id = "taxonomy-" + tasteDigest(Data((control.epoch + item.source + item.metadata.sorted().joined(separator: "\n")).utf8)) }
        if kind == .open { event.id = "open-" + tasteDigest(Data((control.epoch + item.key + context.session).utf8)) }
        try insert(event, db: db, uploaded: false)
    }
    static func insert(_ event: TasteEvent, db: Database, uploaded: Bool) throws {
        try db.execute(sql: "INSERT OR IGNORE INTO taste_events VALUES (?, ?, ?, ?, ?, ?, ?, ?)", arguments: [event.id, event.epoch, event.generation, event.at, event.kind.rawValue, event.item.key, try JSONEncoder().encode(event), uploaded])
    }
    func record(_ kind: TasteEvent.Kind, item: TasteItem, context: DiscoveryContext) throws {
        try database.write { try Self.record(kind, item: item, context: context, db: $0) }
    }
    func events(period: DateInterval? = nil) throws -> [TasteEvent] {
        try database.read { db in
            let control = try Self.control(db)
            let sql = "SELECT payload FROM taste_events WHERE epoch = ?" + (period == nil ? "" : " AND at >= ? AND at < ?") + " ORDER BY at, id"
            var args: StatementArguments = [control.epoch]
            if let period { args += [period.start.timeIntervalSince1970, period.end.timeIntervalSince1970] }
            return try Data.fetchAll(db, sql: sql, arguments: args).map { try JSONDecoder().decode(TasteEvent.self, from: $0) }
        }
    }
    func bootstrap(_ items: [TasteItem]) throws {
        try database.write { db in
            guard try Self.control(db).enabled, try Self.get(Bool.self, key: "bootstrapped", db: db) != true else { return }
            for item in items {
                if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM taste_events WHERE work_key = ? AND kind IN ('save','seed','imported','remove'))", arguments: [item.key]) != true { try Self.record(.seed, item: item, db: db) }
            }
            try Self.put(true, key: "bootstrapped", db: db)
        }
    }
    func pending(limit: Int = 250) throws -> [TasteEvent] {
        try database.read { db in
            try Data.fetchAll(db, sql: "SELECT payload FROM taste_events WHERE uploaded = 0 ORDER BY at DESC, id LIMIT ?", arguments: [limit]).map { try JSONDecoder().decode(TasteEvent.self, from: $0) }
        }
    }
    func acknowledge(_ ids: [String]) throws {
        try database.write { db in for id in ids { try db.execute(sql: "UPDATE taste_events SET uploaded = 1 WHERE id = ?", arguments: [id]) } }
    }
    func merge(_ events: [TasteEvent]) throws {
        try database.write { db in
            let control = try Self.control(db)
            for event in events where event.epoch == control.epoch { try Self.insert(event, db: db, uploaded: true) }
        }
    }
    func metadata<T: Decodable>(_ type: T.Type, key: String) throws -> T? { try database.read { try Self.get(type, key: key, db: $0) } }
    func metadata<T: Encodable>(_ value: T, key: String) throws { try database.write { try Self.put(value, key: key, db: $0) } }
}
