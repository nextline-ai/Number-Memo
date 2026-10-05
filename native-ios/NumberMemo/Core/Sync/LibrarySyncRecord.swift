import Foundation
import GRDB

/// Portable values: local row IDs, cache paths and credentials never leave the device.
enum SyncValue: Codable, Equatable, Sendable {
    case text(String), integer(Int64), real(Double), blob(Data), null
    init(_ value: DatabaseValue) {
        switch value.storage {
        case .null: self = .null
        case .int64(let value): self = .integer(value)
        case .double(let value): self = .real(value)
        case .string(let value): self = .text(value)
        case .blob(let value): self = .blob(value)
        }
    }
    var databaseValue: DatabaseValue {
        switch self {
        case .text(let value): return value.databaseValue
        case .integer(let value): return value.databaseValue
        case .real(let value): return value.databaseValue
        case .blob(let value): return value.databaseValue
        case .null: return .null
        }
    }
    var string: String? { if case .text(let value) = self { return value }; return nil }
    var data: Data? { if case .blob(let value) = self { return value }; return nil }
    var integer: Int64? { if case .integer(let value) = self { return value }; return nil }
}

struct LibrarySyncRow: Codable, Equatable, Sendable {
    let table: String
    var values: [String: SyncValue]
    var key: String {
        let keys = Self.keys[table] ?? []
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return table + ":" + ((try? encoder.encode(keys.map { values[$0] ?? .null })) ?? Data()).base64EncodedString()
    }
    var isFactoryDefault: Bool {
        if table == "booru.folders" { return values["id"]?.string == "unsorted" && values["color"]?.integer == 4284922736 && values["position"]?.integer == 0 }
        if table == "hitomi.folders" { return values["sync_id"]?.string == "unsorted" && values["color"]?.integer == 4280391411 && values["sort_order"]?.integer == 1 }
        return false
    }
    static let keys: [String: [String]] = [
        "hitomi.library_order": ["key"], "hitomi.folders": ["sync_id"], "hitomi.works": ["gallery_id"], "hitomi.folder_works": ["folder_id", "work_id"],
        "hitomi.artists": ["name", "kind"], "hitomi.search_history": ["query"], "hitomi.saved_searches": ["query"],
        "booru.servers": ["id"], "booru.folders": ["id"], "booru.favorites": ["server_id", "post_id"],
        "booru.saved_tags": ["server_id", "name", "kind"], "booru.history": ["server_id", "query"],
        "booru.settings": ["key"], "preferences.hitomi": ["key"], "preferences.booru": ["key"]
    ]
}

struct LibrarySyncChange: Codable, Equatable, Sendable {
    let row: LibrarySyncRow
    let timestamp: Double
    let device: String
    let deleted: Bool
    func isNewer(than other: Self) -> Bool {
        timestamp == other.timestamp ? device > other.device : timestamp > other.timestamp
    }
}

struct LibrarySyncLedger: Codable, Sendable {
    var version = 1
    var changes: [String: LibrarySyncChange] = [:]
    var baseline: [String: LibrarySyncRow] = [:]

    mutating func capture(_ snapshot: [String: LibrarySyncRow], device: String, now: Double = Date().timeIntervalSince1970) {
        let timestamp = max(now, (changes.values.map(\.timestamp).max() ?? 0) + 0.000001)
        for (key, row) in snapshot where baseline[key] != row {
            changes[key] = .init(row: row, timestamp: baseline[key] == nil && changes[key] == nil && row.isFactoryDefault ? 0 : timestamp, device: device, deleted: false)
        }
        for (key, row) in baseline where snapshot[key] == nil {
            let tombstone = LibrarySyncRow(table: row.table, values: row.values.filter { (LibrarySyncRow.keys[row.table] ?? []).contains($0.key) })
            changes[key] = .init(row: tombstone, timestamp: timestamp, device: device, deleted: true)
        }
        baseline = snapshot
    }
    mutating func merge(_ remote: [String: LibrarySyncChange]) {
        for (key, change) in remote where key == change.row.key && LibrarySyncRow.keys[change.row.table] != nil {
            if changes[key].map({ change.isNewer(than: $0) }) ?? true { changes[key] = change }
        }
    }
}

struct LibrarySyncDocument: Codable, Sendable {
    var version = 1
    let changes: [String: LibrarySyncChange]
}
