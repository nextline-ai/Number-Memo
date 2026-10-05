import Foundation
import GRDB

enum SearchRetention {
    static func days(booru: Bool) -> Int {
        let defaults = booru ? ReaderPreferences.booruDefaults : ReaderPreferences.defaults
        return defaults.object(forKey: "search.retentionDays") as? Int ?? 3
    }
    static func cutoff(booru: Bool) -> Double {
        let days = days(booru: booru)
        return days == 0 ? 0 : Date().addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970
    }
}

extension AppDatabase {
    func searchHistory() throws -> [String] {
        try dbWriter.read { try String.fetchAll($0, sql: "SELECT query FROM search_history WHERE used_at >= ? ORDER BY used_at DESC LIMIT 500", arguments: [SearchRetention.cutoff(booru: false)]) }
    }
    func savedSearches() throws -> [String] {
        try dbWriter.read { try String.fetchAll($0, sql: "SELECT query FROM saved_searches ORDER BY query") }
    }
    func recordSearch(_ query: String) throws {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        try dbWriter.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO search_history VALUES (?, ?)", arguments: [value, Date().timeIntervalSince1970])
            try db.execute(sql: "DELETE FROM search_history WHERE used_at < ? OR query NOT IN (SELECT query FROM search_history ORDER BY used_at DESC LIMIT 500)", arguments: [SearchRetention.cutoff(booru: false)])
        }
    }
    func deleteSearch(_ query: String) throws { try dbWriter.write { try $0.execute(sql: "DELETE FROM search_history WHERE query = ?", arguments: [query]) } }
    func clearSearchHistory() throws { try dbWriter.write { try $0.execute(sql: "DELETE FROM search_history") } }
    func toggleSavedSearch(_ query: String) throws {
        try dbWriter.write { db in
            try db.execute(sql: "DELETE FROM saved_searches WHERE query = ?", arguments: [query])
            if db.changesCount == 0 { try db.execute(sql: "INSERT INTO saved_searches VALUES (?)", arguments: [query]) }
        }
    }
    func reorderFolders(_ ids: [Int64]) throws {
        try dbWriter.write { db in
            for (position, id) in ids.enumerated() {
                try db.execute(sql: "UPDATE folders SET sort_order = ?, sync_id = COALESCE(sync_id, CASE WHEN name = '미분류' THEN 'unsorted' ELSE ? END) WHERE id = ?", arguments: [position, UUID().uuidString, id])
            }
            let order = try String.fetchAll(db, sql: "SELECT sync_id FROM folders ORDER BY sort_order, id")
            try db.execute(sql: "INSERT OR REPLACE INTO library_order VALUES ('folders', ?)", arguments: [try JSONEncoder().encode(order)])
        }
        syncFoldersToAppGroup()
    }
}

extension BooruStore {
    func deleteSearch(_ query: String, serverID: String) throws {
        try database.write { try $0.execute(sql: "DELETE FROM history WHERE server_id = ? AND query = ?", arguments: [serverID, query]) }
        try refresh()
    }
    func reorderFolders(_ ids: [String]) throws {
        try database.write { db in
            for (position, id) in ids.enumerated() { try db.execute(sql: "UPDATE folders SET position = ? WHERE id = ?", arguments: [position, id]) }
            try db.execute(sql: "INSERT OR REPLACE INTO settings VALUES ('folder_order', ?)", arguments: [String(decoding: try JSONEncoder().encode(ids), as: UTF8.self)])
        }
        try refresh()
    }
    func setFolderColor(_ id: String, color: Int64) throws {
        try database.write { try $0.execute(sql: "UPDATE folders SET color = ? WHERE id = ?", arguments: [color, id]) }
        try refresh()
    }
    func removeFavorites(_ posts: [BooruPost]) throws {
        try database.write { db in
            for post in posts { try db.execute(sql: "DELETE FROM favorites WHERE server_id = ? AND post_id = ?", arguments: [post.serverID, post.postID]) }
        }
        try refresh()
    }
    func moveFavorites(_ posts: [BooruPost], folderID: String) throws {
        try database.write { db in
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM folders WHERE id = ?)", arguments: [folderID]) == true else { throw BooruError.invalidResponse }
            for post in posts { try db.execute(sql: "UPDATE favorites SET folder_id = ? WHERE server_id = ? AND post_id = ?", arguments: [folderID, post.serverID, post.postID]) }
        }
        try refresh()
    }
    func savedDate(for post: BooruPost) -> Date? {
        (try? database.read { try Double.fetchOne($0, sql: "SELECT saved_at FROM favorites WHERE server_id = ? AND post_id = ?", arguments: [post.serverID, post.postID]) }).map(Date.init(timeIntervalSince1970:))
    }
}

extension AppDatabase {
    func deleteSelectedWorks(_ ids: Set<Int64>) throws {
        try dbWriter.write { db in
            for id in ids {
                try db.execute(sql: "DELETE FROM folder_works WHERE work_id IN (SELECT id FROM works WHERE gallery_id = ?)", arguments: [id])
                try db.execute(sql: "DELETE FROM works WHERE gallery_id = ?", arguments: [id])
            }
        }
    }
    func moveSelectedWorks(_ ids: Set<Int64>, to folderID: Int64, from source: Int64?) throws {
        try dbWriter.write { db in
            for id in ids {
                guard let work = try Int64.fetchOne(db, sql: "SELECT id FROM works WHERE gallery_id = ?", arguments: [id]) else { continue }
                if let source { try db.execute(sql: "DELETE FROM folder_works WHERE work_id = ? AND folder_id = ?", arguments: [work, source]) }
                else { try db.execute(sql: "DELETE FROM folder_works WHERE work_id = ?", arguments: [work]) }
                try db.execute(sql: "INSERT OR IGNORE INTO folder_works VALUES (?, ?, ?)", arguments: [folderID, work, ISO8601DateFormatter().string(from: Date())])
            }
        }
    }
}

extension AppEnvironment {
    func pruneSearchHistory() {
        try? database.dbWriter.write { try $0.execute(sql: "DELETE FROM search_history WHERE used_at < ?", arguments: [SearchRetention.cutoff(booru: false)]) }
        try? booru.database.write { try $0.execute(sql: "DELETE FROM history WHERE used_at < ?", arguments: [SearchRetention.cutoff(booru: true)]) }
        try? booru.refresh()
    }
}
