import Foundation
import GRDB

public final class AppDatabase: Sendable {
    public let dbWriter: any DatabaseWriter

    public init(_ dbWriter: any DatabaseWriter) throws {
        self.dbWriter = dbWriter
        try migrator.migrate(dbWriter)
    }

    public static func open(at path: String = AppStorage.localDbURL.path) throws -> AppDatabase {
        var config = Configuration()
        config.qos = .userInitiated
        config.foreignKeysEnabled = true
        let dbQueue = try DatabaseQueue(path: path, configuration: config)
        let db = try AppDatabase(dbQueue)
        try db.ensureDefaultFolder()
        return db
    }

    public static func inMemory() throws -> AppDatabase {
        let dbQueue = try DatabaseQueue(configuration: Configuration())
        let db = try AppDatabase(dbQueue)
        try db.ensureDefaultFolder()
        return db
    }

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_create_schema") { db in
            try db.create(table: "folders", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull().unique()
                t.column("description", .text)
                t.column("color", .integer).notNull().defaults(to: 4288585374)
                t.column("sort_order", .integer).notNull().defaults(to: 0)
                t.column("created_at", .text).notNull()
                t.column("violet_group_id", .integer)
            }

            try db.create(table: "works", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("gallery_id", .integer).notNull().unique()
                t.column("title", .text)
                t.column("artists", .text)
                t.column("language", .text)
                t.column("type", .text)
                t.column("series", .text)
                t.column("groups", .text)
                t.column("tags", .text)
                t.column("note", .text)
                t.column("bookmarked_at", .text).notNull()
                t.column("published_at", .text)
                t.column("last_opened_at", .text)
                t.column("updated_at", .text)
                t.column("metadata_source", .text)
                t.column("catalog_matched", .boolean).notNull().defaults(to: false)
                t.column("thumb_status", .text).notNull().defaults(to: "missing")
                t.column("thumb_path", .text)
                t.column("thumb_failed_at", .text)
                t.column("thumb_page", .integer).defaults(to: 1)
            }
            try db.create(index: "idx_works_bookmarked", on: "works", columns: ["bookmarked_at"])
            try db.create(index: "idx_works_gallery_id", on: "works", columns: ["gallery_id"])

            try db.create(table: "folder_works", ifNotExists: true) { t in
                t.column("folder_id", .integer).notNull().references("folders", onDelete: .cascade)
                t.column("work_id", .integer).notNull().references("works", onDelete: .cascade)
                t.column("added_at", .text).notNull()
                t.primaryKey(["folder_id", "work_id"])
            }

            try db.create(table: "catalog_works", ifNotExists: true) { t in
                t.column("id", .integer).primaryKey() // gallery_id
                t.column("title", .text)
                t.column("type", .text)
                t.column("language", .text)
                t.column("artists", .text)
                t.column("groups", .text)
                t.column("series", .text)
                t.column("characters", .text)
                t.column("tags", .text)
                t.column("published", .text)
            }
            try db.create(index: "idx_catalog_title", on: "catalog_works", columns: ["title"])

            try db.create(table: "artists", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("kind", .integer).notNull().defaults(to: 0)
                t.column("note", .text)
                t.column("folder_id", .integer).references("folders", onDelete: .setNull)
                t.column("bookmarked_at", .text).notNull()
                t.uniqueKey(["name", "kind"])
            }

            try db.create(table: "inbox", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("gallery_id", .integer).notNull()
                t.column("raw_text", .text)
                t.column("received_at", .text).notNull()
                t.column("processed_at", .text)
            }
        }

        migrator.registerMigration("v2_thumb_page") { db in
            if try !db.columns(in: "works").contains(where: { $0.name == "thumb_page" }) {
                try db.alter(table: "works") { t in
                    t.add(column: "thumb_page", .integer).defaults(to: 1)
                }
            }
        }

        migrator.registerMigration("v3_searches_and_sync_identity") { db in
            try db.execute(sql: "CREATE TABLE search_history (query TEXT PRIMARY KEY, used_at DOUBLE NOT NULL); CREATE TABLE saved_searches (query TEXT PRIMARY KEY);")
            try db.execute(sql: "ALTER TABLE folders ADD COLUMN sync_id TEXT")
            for row in try Row.fetchAll(db, sql: "SELECT id, name FROM folders") {
                let id: Int64 = row["id"]
                let name: String = row["name"]
                try db.execute(sql: "UPDATE folders SET sync_id = ? WHERE id = ?", arguments: [name == "미분류" ? "unsorted" : UUID().uuidString, id])
            }
            try db.execute(sql: "CREATE UNIQUE INDEX folder_sync_id ON folders(sync_id)")
        }
        migrator.registerMigration("v4_folder_order") { db in
            try db.execute(sql: "CREATE TABLE library_order (key TEXT PRIMARY KEY, value BLOB NOT NULL)")
        }
        migrator.registerMigration("v5_taste") { try TasteStore.migrate($0) }
        migrator.registerMigration("v6_visual_fingerprints") { try VisualFingerprintStore.migrate($0) }
        migrator.registerMigration("v7_visual_cleanup") { try VisualFingerprintStore.installDeletionTrigger($0) }
        return migrator
    }

    // MARK: - Folders & Color Generation

    public static let curatedFolderColors: [Int64] = [
        0xFF2563EB, // Royal Blue
        0xFF059669, // Emerald Green
        0xFFEA580C, // Bright Orange
        0xFFE11D48, // Rose Red
        0xFF7C3AED, // Deep Purple
        0xFF0891B2, // Ocean Cyan
        0xFFD97706, // Amber Gold
        0xFFDB2777, // Vibrant Pink
        0xFF4F46E5, // Indigo
        0xFF0D9488, // Teal
        0xFF65A30D, // Lime Green
        0xFFC026D3, // Fuchsia
        0xFFDC2626, // Crimson
        0xFF9333EA, // Violet
        0xFF0284C7, // Sky Blue
        0xFFB45309, // Warm Brown
        0xFF16A34A, // Forest Green
        0xFFF97316, // Tangerine
        0xFF6366F1, // Periwinkle
        0xFF14B8A6, // Turquoise
        0xFF84CC16, // Lime
        0xFFEC4899, // Pink
        0xFFA855F7, // Purple
        0xFF3B82F6, // Blue
        0xFF10B981, // Mint
        0xFFF59E0B, // Yellow Orange
        0xFFEF4444, // Light Red
        0xFF64748B  // Slate
    ]

    public static var presetColors: [Int64] { curatedFolderColors }

    public static func colorFromHSV(h: Double, s: Double, v: Double) -> Int64 {
        let c = v * s
        let modH = (h.truncatingRemainder(dividingBy: 1.0) + 1.0).truncatingRemainder(dividingBy: 1.0) * 6.0
        let x = c * (1.0 - abs(modH.truncatingRemainder(dividingBy: 2.0) - 1.0))
        let m = v - c
        let (r1, g1, b1): (Double, Double, Double)
        switch Int(modH) % 6 {
        case 0: (r1, g1, b1) = (c, x, 0)
        case 1: (r1, g1, b1) = (x, c, 0)
        case 2: (r1, g1, b1) = (0, c, x)
        case 3: (r1, g1, b1) = (0, x, c)
        case 4: (r1, g1, b1) = (x, 0, c)
        default: (r1, g1, b1) = (c, 0, x)
        }
        let r = Int64(round((r1 + m) * 255.0))
        let g = Int64(round((g1 + m) * 255.0))
        let b = Int64(round((b1 + m) * 255.0))
        return (0xFF << 24) | (r << 16) | (g << 8) | b
    }

    public func nextUniqueFolderColor(in db: Database, excluding: Set<Int64> = []) -> Int64 {
        let existingColors = (try? Int64.fetchAll(db, sql: "SELECT color FROM folders")) ?? []
        return Self.nextFolderColor(existingColors: existingColors, excluding: excluding)
    }

    /// Shared by both libraries: unused palette colors first, then golden-angle hues.
    public static func nextFolderColor(existingColors: [Int64], excluding: Set<Int64> = []) -> Int64 {
        var used = Set(existingColors)
        used.formUnion(excluding)

        for color in Self.curatedFolderColors {
            if !used.contains(color) {
                return color
            }
        }

        let goldenRatio = 0.618033988749895
        let count = existingColors.count + excluding.count
        let hue = (Double(count) * goldenRatio).truncatingRemainder(dividingBy: 1.0)
        return Self.colorFromHSV(h: hue, s: 0.75, v: 0.88)
    }

    public func nextUniqueFolderColor(excluding: Set<Int64> = []) -> Int64 {
        (try? dbWriter.read { db in nextUniqueFolderColor(in: db, excluding: excluding) })
            ?? Self.curatedFolderColors.first!
    }

    @discardableResult
    public func ensureDefaultFolder() throws -> Folder {
        try dbWriter.write { db in
            let folder: Folder
            if let existing = try Folder.fetchOne(db, sql: "SELECT * FROM folders WHERE name = '미분류' LIMIT 1")
                ?? Folder.fetchOne(db, sql: "SELECT * FROM folders ORDER BY sort_order ASC, id ASC LIMIT 1") {
                folder = existing
            } else {
                let now = ISO8601DateFormatter().string(from: Date())
                var newFolder = Folder(name: "미분류", description: "기본 폴더", color: 4280391411, sortOrder: 1, createdAt: now)
                try newFolder.insert(db)
                if newFolder.id == nil { newFolder.id = db.lastInsertedRowID }
                folder = newFolder
            }

            // Link any orphan works to the default folder
            if let defaultId = folder.id {
                try db.execute(sql: """
                INSERT OR IGNORE INTO folder_works (folder_id, work_id, added_at)
                SELECT ?, id, bookmarked_at FROM works
                WHERE id NOT IN (SELECT work_id FROM folder_works)
                """, arguments: [defaultId])

                // Prune works from defaultFolder if they belong to other folders
                try db.execute(sql: """
                DELETE FROM folder_works
                WHERE folder_id = ?
                  AND work_id IN (SELECT work_id FROM folder_works WHERE folder_id != ?)
                """, arguments: [defaultId, defaultId])
            }

            return folder
        }
    }

    public func syncFoldersToAppGroup() {
        guard let folders = try? listFolders() else { return }
        let payload = folders.map { [
            "id": $0.id ?? 0,
            "name": $0.name,
            "color": $0.color,
            "work_count": $0.workCount
        ] }
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            try? data.write(to: AppStorage.foldersJSONURL, options: .atomic)
            if let defaults = UserDefaults(suiteName: AppStorage.appGroup) {
                defaults.set(String(data: data, encoding: .utf8), forKey: "folders_json")
            }
        }
    }

    public func listFolders() throws -> [Folder] {
        try dbWriter.read { db in
            let sql = """
            SELECT f.*, COUNT(fw.work_id) AS work_count
            FROM folders f
            LEFT JOIN folder_works fw ON fw.folder_id = f.id
            GROUP BY f.id
            ORDER BY f.sort_order ASC, f.id ASC
            """
            let rows = try Row.fetchAll(db, sql: sql)
            return rows.map { row in
                Folder(
                    id: row["id"],
                    name: row["name"],
                    description: row["description"],
                    color: row["color"],
                    sortOrder: row["sort_order"],
                    createdAt: row["created_at"],
                    violetGroupId: row["violet_group_id"],
                    workCount: row["work_count"]
                )
            }
        }
    }

    public func folderPreviews(limitPerFolder: Int = 4) throws -> [Int64: [Work]] {
        try dbWriter.read { db in
            let sql = """
            SELECT fw.folder_id, w.*
            FROM folder_works fw
            INNER JOIN works w ON w.id = fw.work_id
            ORDER BY COALESCE(NULLIF(w.bookmarked_at, ''), fw.added_at) DESC, w.id DESC
            """
            let rows = try Row.fetchAll(db, sql: sql)
            var result: [Int64: [Work]] = [:]
            for row in rows {
                let folderId: Int64 = row["folder_id"]
                if (result[folderId]?.count ?? 0) < limitPerFolder {
                    let work = try Work(row: row)
                    result[folderId, default: []].append(work)
                }
            }
            return result
        }
    }

    public func createFolder(name: String, description: String? = nil, color: Int64? = nil, violetGroupId: Int64? = nil) throws -> Folder {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = try dbWriter.write { db -> Folder in
            let resolvedColor = color ?? nextUniqueFolderColor(in: db)

            // 1. Check by violetGroupId if provided
            if let violetGroupId, var existing = try Folder.filter(Column("violet_group_id") == violetGroupId).fetchOne(db) {
                if existing.name != trimmed && !trimmed.isEmpty {
                    try db.execute(sql: "UPDATE folders SET name = ? WHERE id = ?", arguments: [trimmed, existing.id])
                    existing.name = trimmed
                }
                return existing
            }

            // 2. Check by name
            if var existing = try Folder.filter(Folder.Columns.name == trimmed).fetchOne(db) {
                if let violetGroupId, existing.violetGroupId == nil {
                    try db.execute(sql: "UPDATE folders SET violet_group_id = ? WHERE id = ?", arguments: [violetGroupId, existing.id])
                    existing.violetGroupId = violetGroupId
                }
                return existing
            }

            let maxOrder: Int = try Int.fetchOne(db, sql: "SELECT MAX(sort_order) FROM folders") ?? 0
            let now = ISO8601DateFormatter().string(from: Date())
            var newFolder = Folder(
                name: trimmed,
                description: description,
                color: resolvedColor,
                sortOrder: maxOrder + 1,
                createdAt: now,
                violetGroupId: violetGroupId
            )
            try newFolder.insert(db)
            if newFolder.id == nil {
                newFolder.id = db.lastInsertedRowID
            }
            return newFolder
        }
        syncFoldersToAppGroup()
        return folder
    }

    public func deleteFolder(id: Int64) throws {
        try dbWriter.write { db in
            guard let defaultFolder = try Folder.fetchOne(db, sql: "SELECT * FROM folders WHERE name = '미분류' AND id != ? LIMIT 1", arguments: [id])
                ?? Folder.fetchOne(db, sql: "SELECT * FROM folders WHERE id != ? ORDER BY sort_order ASC, id ASC LIMIT 1", arguments: [id]) else {
                return
            }
            // Move works to default folder
            try db.execute(
                sql: """
                INSERT OR IGNORE INTO folder_works (folder_id, work_id, added_at)
                SELECT ?, work_id, added_at FROM folder_works WHERE folder_id = ?
                """,
                arguments: [defaultFolder.id, id]
            )
            try db.execute(sql: "DELETE FROM folder_works WHERE folder_id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM folders WHERE id = ?", arguments: [id])
        }
        syncFoldersToAppGroup()
    }

    public func renameFolder(id: Int64, name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try dbWriter.write { db in
            try db.execute(sql: "UPDATE folders SET name = ? WHERE id = ?", arguments: [trimmed, id])
        }
        syncFoldersToAppGroup()
    }

    public func setFolderColor(id: Int64, color: Int64) throws {
        try dbWriter.write { db in
            try db.execute(sql: "UPDATE folders SET color = ? WHERE id = ?", arguments: [color, id])
        }
        syncFoldersToAppGroup()
    }

    // MARK: - Works

    public func listWorks(folderId: Int64? = nil, query: String? = nil, artist: String? = nil) throws -> [Work] {
        try dbWriter.read { db in
            var conditions: [String] = []
            var arguments: [DatabaseValueConvertible] = []

            if let folderId {
                conditions.append("w.id IN (SELECT work_id FROM folder_works WHERE folder_id = ?)")
                arguments.append(folderId)
            }

            if let artist, !artist.isEmpty {
                conditions.append("(w.artists LIKE ? OR w.groups LIKE ?)")
                arguments.append("%\(artist)%")
                arguments.append("%\(artist)%")
            }

            if let query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
                if let idQuery = Int64(trimmed) {
                    conditions.append("(w.gallery_id = ? OR w.title LIKE ? OR w.artists LIKE ? OR w.tags LIKE ? OR w.note LIKE ?)")
                    arguments.append(idQuery)
                    arguments.append("%\(trimmed)%")
                    arguments.append("%\(trimmed)%")
                    arguments.append("%\(trimmed)%")
                    arguments.append("%\(trimmed)%")
                } else {
                    conditions.append("(w.title LIKE ? OR w.artists LIKE ? OR w.tags LIKE ? OR w.note LIKE ?)")
                    arguments.append("%\(trimmed)%")
                    arguments.append("%\(trimmed)%")
                    arguments.append("%\(trimmed)%")
                    arguments.append("%\(trimmed)%")
                }
            }

            let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
            let sql = """
            SELECT w.* FROM works w
            \(whereClause)
            ORDER BY w.bookmarked_at DESC, w.id DESC
            """
            var works = try Work.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))

            // Fetch attached folders
            for i in works.indices {
                if let workId = works[i].id {
                    let folderSql = """
                    SELECT f.* FROM folders f
                    INNER JOIN folder_works fw ON fw.folder_id = f.id
                    WHERE fw.work_id = ?
                    ORDER BY f.sort_order ASC
                    """
                    works[i].folders = try Folder.fetchAll(db, sql: folderSql, arguments: [workId])
                }
            }

            return works
        }
    }

    public func getWork(galleryId: Int64) throws -> Work? {
        try dbWriter.read { db in
            guard var work = try Work.filter(Work.Columns.galleryId == galleryId).fetchOne(db) else {
                return nil
            }
            if let workId = work.id {
                let folderSql = """
                SELECT f.* FROM folders f
                INNER JOIN folder_works fw ON fw.folder_id = f.id
                WHERE fw.work_id = ?
                ORDER BY f.sort_order ASC
                """
                work.folders = try Folder.fetchAll(db, sql: folderSql, arguments: [workId])
            }
            return work
        }
    }

    public func upsertWork(
        galleryId: Int64,
        folderId: Int64? = nil,
        title: String? = nil,
        artists: String? = nil,
        language: String? = nil,
        type: String? = nil,
        series: String? = nil,
        groups: String? = nil,
        tags: String? = nil,
        publishedAt: String? = nil,
        bookmarkedAt: String? = nil,
        metadataSource: String? = nil,
        catalogMatched: Bool = false,
        overwriteMetadata: Bool = false,
        discoveryContext: DiscoveryContext? = nil
    ) throws -> Work {
        try dbWriter.write { db in
            let now = ISO8601DateFormatter().string(from: Date())
            var work = try Work.filter(Work.Columns.galleryId == galleryId).fetchOne(db)
            let wasNew = work == nil

            if var existing = work {
                if overwriteMetadata || existing.metadataSource != "manual" {
                    if let title, !title.isEmpty { existing.title = title }
                    if let artists, !artists.isEmpty { existing.artists = artists }
                    if let language, !language.isEmpty { existing.language = language }
                    if let type, !type.isEmpty { existing.type = type }
                    if let series, !series.isEmpty { existing.series = series }
                    if let groups, !groups.isEmpty { existing.groups = groups }
                    if let tags, !tags.isEmpty { existing.tags = tags }
                    if let publishedAt, !publishedAt.isEmpty { existing.publishedAt = publishedAt }
                    if let metadataSource { existing.metadataSource = metadataSource }
                    existing.catalogMatched = catalogMatched || existing.catalogMatched
                }
                existing.updatedAt = now
                try existing.update(db)
                work = existing
            } else {
                var newWork = Work(
                    galleryId: galleryId,
                    title: title,
                    artists: artists,
                    language: language,
                    type: type,
                    series: series,
                    groups: groups,
                    tags: tags,
                    bookmarkedAt: bookmarkedAt ?? now,
                    publishedAt: publishedAt,
                    updatedAt: now,
                    metadataSource: metadataSource,
                    catalogMatched: catalogMatched
                )
                try newWork.insert(db)
                if newWork.id == nil {
                    newWork.id = db.lastInsertedRowID
                }
                work = newWork
            }

            // Bind to folder if provided
            if let folderId {
                let resolvedWorkId = work?.id ?? (try? Int64.fetchOne(db, sql: "SELECT id FROM works WHERE gallery_id = ?", arguments: [galleryId]))
                if let workId = resolvedWorkId {
                    try db.execute(
                        sql: "INSERT OR IGNORE INTO folder_works (folder_id, work_id, added_at) VALUES (?, ?, ?)",
                        arguments: [folderId, workId, now]
                    )
                    // If assigned to a non-default folder, remove from default folder (미분류)
                    if let defaultId = try? Int64.fetchOne(db, sql: "SELECT id FROM folders WHERE name = '미분류' OR id = 1 ORDER BY sort_order ASC, id ASC LIMIT 1"), defaultId != folderId {
                        try db.execute(
                            sql: "DELETE FROM folder_works WHERE folder_id = ? AND work_id = ?",
                            arguments: [defaultId, workId]
                        )
                    }
                }
            }

            if wasNew, let discoveryContext { try TasteStore.record(.save, item: .comic(galleryId, tags: work?.tags), context: discoveryContext, db: db) }
            else if wasNew { try TasteStore.record(.imported, item: .comic(galleryId, tags: work?.tags), db: db) }
            else if !wasNew { try TasteStore.record(.metadata, item: .comic(galleryId, tags: work?.tags), db: db) }
            return work!
        }
    }

    public func addWorkToFolder(workId: Int64, folderId: Int64) throws {
        let now = ISO8601DateFormatter().string(from: Date())
        try dbWriter.write { db in
            try db.execute(
                sql: "INSERT OR IGNORE INTO folder_works (folder_id, work_id, added_at) VALUES (?, ?, ?)",
                arguments: [folderId, workId, now]
            )
        }
    }

    public func setManualTitle(galleryId: Int64, title: String) throws {
        let now = ISO8601DateFormatter().string(from: Date())
        try dbWriter.write { db in
            try db.execute(
                sql: "UPDATE works SET title = ?, metadata_source = 'manual', updated_at = ? WHERE gallery_id = ?",
                arguments: [title, now, galleryId]
            )
        }
    }

    public func setNote(galleryId: Int64, note: String) throws {
        let now = ISO8601DateFormatter().string(from: Date())
        try dbWriter.write { db in
            try db.execute(
                sql: "UPDATE works SET note = ?, updated_at = ? WHERE gallery_id = ?",
                arguments: [note, now, galleryId]
            )
        }
    }

    public func markOpened(galleryId: Int64) throws {
        let now = ISO8601DateFormatter().string(from: Date())
        try dbWriter.write { db in
            try db.execute(
                sql: "UPDATE works SET last_opened_at = ? WHERE gallery_id = ?",
                arguments: [now, galleryId]
            )
        }
    }

    public func moveWorkToFolder(galleryId: Int64, targetFolderId: Int64, currentFolderId: Int64? = nil) throws {
        let now = ISO8601DateFormatter().string(from: Date())
        try dbWriter.write { db in
            guard let work = try Work.filter(Work.Columns.galleryId == galleryId).fetchOne(db),
                  let workId = work.id else { return }

            if let currentFolderId {
                try db.execute(
                    sql: "DELETE FROM folder_works WHERE folder_id = ? AND work_id = ?",
                    arguments: [currentFolderId, workId]
                )
            } else {
                try db.execute(
                    sql: "DELETE FROM folder_works WHERE work_id = ?",
                    arguments: [workId]
                )
            }

            try db.execute(
                sql: "INSERT OR IGNORE INTO folder_works (folder_id, work_id, added_at) VALUES (?, ?, ?)",
                arguments: [targetFolderId, workId, now]
            )
        }
    }

    public func deleteWork(galleryId: Int64) throws {
        try dbWriter.write { db in
            try TasteStore.record(.remove, item: .comic(galleryId), db: db)
            if let work = try Work.filter(Work.Columns.galleryId == galleryId).fetchOne(db), let workId = work.id {
                try db.execute(sql: "DELETE FROM folder_works WHERE work_id = ?", arguments: [workId])
                try db.execute(sql: "DELETE FROM works WHERE id = ?", arguments: [workId])
            }
        }
    }

    public func setThumb(galleryId: Int64, status: String, path: String? = nil, page: Int? = nil) throws {
        let now = ISO8601DateFormatter().string(from: Date())
        try dbWriter.write { db in
            if status == "failed" || status == "gone" {
                try db.execute(
                    sql: "UPDATE works SET thumb_status = ?, thumb_failed_at = ? WHERE gallery_id = ?",
                    arguments: [status, now, galleryId]
                )
            } else if status == "ready" {
                if let page = page {
                    try db.execute(
                        sql: "UPDATE works SET thumb_status = ?, thumb_path = ?, thumb_page = ?, thumb_failed_at = NULL WHERE gallery_id = ?",
                        arguments: [status, path, page, galleryId]
                    )
                } else {
                    try db.execute(
                        sql: "UPDATE works SET thumb_status = ?, thumb_path = ?, thumb_failed_at = NULL WHERE gallery_id = ?",
                        arguments: [status, path, galleryId]
                    )
                }
            } else {
                try db.execute(
                    sql: "UPDATE works SET thumb_status = ?, thumb_path = NULL WHERE gallery_id = ?",
                    arguments: [status, galleryId]
                )
            }
        }
        if status == "ready", let path {
            let store = VisualFingerprintStore(database: dbWriter)
            Task.detached(priority: .utility) {
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return }
                _ = try? await store.save(data: data, scope: "comics", id: galleryId)
            }
        }
    }

    public func setThumbPage(galleryId: Int64, page: Int) throws {
        try dbWriter.write { db in
            try db.execute(
                sql: "UPDATE works SET thumb_page = ? WHERE gallery_id = ?",
                arguments: [page, galleryId]
            )
        }
    }

    public func worksNeedingFill(limit: Int = 8, exclude: Set<Int64> = []) throws -> [Work] {
        try dbWriter.read { db in
            let placeholders = exclude.isEmpty ? "" : "AND gallery_id NOT IN (\(exclude.map(String.init).joined(separator: ",")))"
            let sql = """
            SELECT * FROM works
            WHERE (thumb_status IN ('missing', 'failed') OR title IS NULL OR title = '' OR tags IS NULL OR tags = '')
            \(placeholders)
            ORDER BY bookmarked_at DESC
            LIMIT ?
            """
            return try Work.fetchAll(db, sql: sql, arguments: [limit])
        }
    }

    public func countNeedingFill() throws -> Int {
        try dbWriter.read { db in
            let sql = """
            SELECT COUNT(*) FROM works
            WHERE thumb_status IN ('missing', 'failed') OR title IS NULL OR title = '' OR tags IS NULL OR tags = ''
            """
            return try Int.fetchOne(db, sql: sql) ?? 0
        }
    }

    public func worksCount() throws -> Int {
        try dbWriter.read { db in
            try Work.fetchCount(db)
        }
    }

    public func missingTitleCount() throws -> Int {
        try dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM works WHERE title IS NULL OR TRIM(title) = ''") ?? 0
        }
    }

    // MARK: - Catalog Works

    public func getCatalog(galleryId: Int64) throws -> CatalogWork? {
        try dbWriter.read { db in
            try CatalogWork.fetchOne(db, key: galleryId)
        }
    }

    public func catalogCount() throws -> Int {
        try dbWriter.read { db in
            try CatalogWork.fetchCount(db)
        }
    }

    public func listAllGalleryIds() throws -> [Int64] {
        try dbWriter.read { db in
            try Int64.fetchAll(db, sql: "SELECT gallery_id FROM works ORDER BY id DESC")
        }
    }

    public func listGalleryIdsNeedingMetadata() throws -> [Int64] {
        try dbWriter.read { db in
            try Int64.fetchAll(db, sql: "SELECT gallery_id FROM works WHERE title IS NULL OR title = '' OR tags IS NULL OR tags = '' OR catalog_matched = 0 ORDER BY id DESC")
        }
    }

    public func applyCatalogBatchToWorks(_ items: [CatalogWork]) throws -> Int {
        guard !items.isEmpty else { return 0 }
        let now = ISO8601DateFormatter().string(from: Date())
        return try dbWriter.write { db in
            let updateSql = """
            UPDATE works
            SET title = CASE WHEN (title IS NULL OR title = '' OR metadata_source != 'manual') THEN ? ELSE title END,
                artists = CASE WHEN (artists IS NULL OR artists = '' OR metadata_source != 'manual') THEN ? ELSE artists END,
                language = CASE WHEN (language IS NULL OR language = '' OR metadata_source != 'manual') THEN ? ELSE language END,
                type = CASE WHEN (type IS NULL OR type = '' OR metadata_source != 'manual') THEN ? ELSE type END,
                series = CASE WHEN (series IS NULL OR series = '' OR metadata_source != 'manual') THEN ? ELSE series END,
                groups = CASE WHEN (groups IS NULL OR groups = '' OR metadata_source != 'manual') THEN ? ELSE groups END,
                tags = CASE WHEN (tags IS NULL OR tags = '' OR metadata_source != 'manual') THEN ? ELSE tags END,
                published_at = CASE WHEN published_at IS NULL THEN ? ELSE published_at END,
                catalog_matched = 1,
                metadata_source = CASE WHEN metadata_source = 'manual' THEN 'manual' ELSE 'catalog' END,
                updated_at = ?
            WHERE gallery_id = ?
            """
            let updateStmt = try db.makeStatement(sql: updateSql)

            let insertCatSql = """
            INSERT OR REPLACE INTO catalog_works (id, title, type, language, artists, groups, series, characters, tags, published)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
            let catStmt = try db.makeStatement(sql: insertCatSql)

            var updatedCount = 0
            for item in items {
                try updateStmt.execute(arguments: [
                    item.title,
                    item.artists,
                    item.language,
                    item.type,
                    item.series,
                    item.groups,
                    item.tags,
                    item.published,
                    now,
                    item.id
                ])
                if db.changesCount > 0 {
                    updatedCount += 1
                }

                try catStmt.execute(arguments: [
                    item.id,
                    item.title,
                    item.type,
                    item.language,
                    item.artists,
                    item.groups,
                    item.series,
                    item.characters,
                    item.tags,
                    item.published
                ])
            }
            return updatedCount
        }
    }

    public func upsertCatalogBatch(_ batch: [CatalogWork]) throws {
        try dbWriter.write { db in
            let sql = """
            INSERT OR REPLACE INTO catalog_works (id, title, type, language, artists, groups, series, characters, tags, published)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
            let statement = try db.makeStatement(sql: sql)
            for item in batch {
                try statement.execute(arguments: [
                    item.id,
                    item.title,
                    item.type,
                    item.language,
                    item.artists,
                    item.groups,
                    item.series,
                    item.characters,
                    item.tags,
                    item.published
                ])
            }
        }
    }

    public func applyCatalogToWorks() throws {
        try dbWriter.write { db in
            let sql = """
            UPDATE works
            SET title = (SELECT c.title FROM catalog_works c WHERE c.id = works.gallery_id),
                artists = (SELECT c.artists FROM catalog_works c WHERE c.id = works.gallery_id),
                language = (SELECT c.language FROM catalog_works c WHERE c.id = works.gallery_id),
                type = (SELECT c.type FROM catalog_works c WHERE c.id = works.gallery_id),
                series = (SELECT c.series FROM catalog_works c WHERE c.id = works.gallery_id),
                groups = (SELECT c.groups FROM catalog_works c WHERE c.id = works.gallery_id),
                tags = (SELECT c.tags FROM catalog_works c WHERE c.id = works.gallery_id),
                published_at = (SELECT c.published FROM catalog_works c WHERE c.id = works.gallery_id),
                catalog_matched = 1,
                metadata_source = CASE WHEN metadata_source = 'manual' THEN 'manual' ELSE 'catalog' END
            WHERE EXISTS (SELECT 1 FROM catalog_works c WHERE c.id = works.gallery_id)
              AND (title IS NULL OR metadata_source != 'manual')
            """
            try db.execute(sql: sql)
        }
    }

    // MARK: - Artists

    public func listArtists() throws -> [ArtistMemo] {
        try dbWriter.read { db in
            try ArtistMemo.order(ArtistMemo.Columns.name.asc).fetchAll(db)
        }
    }

    public func addFavoriteArtist(name: String, kind: Int = 0) throws -> ArtistMemo {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return try dbWriter.write { db in
            if let existing = try ArtistMemo.filter(ArtistMemo.Columns.name == trimmed && ArtistMemo.Columns.kind == kind).fetchOne(db) {
                return existing
            }
            var artist = ArtistMemo(name: trimmed, kind: kind)
            try artist.insert(db)
            if artist.id == nil { artist.id = db.lastInsertedRowID }
            return artist
        }
    }

    public func removeFavoriteArtist(name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try dbWriter.write { db in
            try db.execute(sql: "DELETE FROM artists WHERE name = ?", arguments: [trimmed])
        }
    }
}
