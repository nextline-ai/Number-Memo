import Foundation
import GRDB

public struct ImportSummary: Sendable {
    public let folders: Int
    public let works: Int
    public let catalog: Int
    public let titlesFilled: Int
    public let titlesMissing: Int
    public let artists: Int

    public init(folders: Int = 0, works: Int = 0, catalog: Int = 0, titlesFilled: Int = 0, titlesMissing: Int = 0, artists: Int = 0) {
        self.folders = folders
        self.works = works
        self.catalog = catalog
        self.titlesFilled = titlesFilled
        self.titlesMissing = titlesMissing
        self.artists = artists
    }
}

public final class VioletImportService: Sendable {
    private let appDb: AppDatabase

    public init(appDb: AppDatabase) {
        self.appDb = appDb
    }

    public static func openReadOnlyDb(at path: String) throws -> DatabaseQueue {
        var config = Configuration()
        config.readonly = true
        return try DatabaseQueue(path: path, configuration: config)
    }

    public static func isUserDb(at path: String) -> Bool {
        guard let db = try? openReadOnlyDb(at: path) else { return false }
        return (try? db.read { try $0.tableExists("BookmarkArticle") }) ?? false
    }

    public static func isDataDb(at path: String) -> Bool {
        guard let db = try? openReadOnlyDb(at: path) else { return false }
        return (try? db.read { try $0.tableExists("HitomiColumnModel") }) ?? false
    }

    // MARK: - Safe Column Helpers (Never throw 'try!' on mixed types)

    private static func safeString(from row: Row, column: String) -> String? {
        let val: DatabaseValue = row[column]
        if val.isNull { return nil }
        switch val.storage {
        case .string(let s):
            return s
        case .int64(let i):
            return String(i)
        case .double(let d):
            return String(d)
        case .blob, .null:
            return nil
        }
    }

    private static func safeInt64(from row: Row, column: String) -> Int64? {
        let val: DatabaseValue = row[column]
        if val.isNull { return nil }
        switch val.storage {
        case .int64(let i):
            return i
        case .string(let s):
            return Int64(s)
        case .double(let d):
            return Int64(d)
        case .blob, .null:
            return nil
        }
    }

    private static func parsePublished(from row: Row) -> String? {
        let val: DatabaseValue = row["Published"]
        if val.isNull { return nil }
        switch val.storage {
        case .int64(let ticks):
            return formatTicks(ticks)
        case .string(let s):
            if let ticks = Int64(s), ticks > 600_000_000_000_000_000 {
                return formatTicks(ticks)
            }
            return s
        case .double(let d):
            let ticks = Int64(d)
            if ticks > 600_000_000_000_000_000 {
                return formatTicks(ticks)
            }
            return String(d)
        case .blob, .null:
            return nil
        }
    }

    private static func formatTicks(_ ticks: Int64) -> String {
        let epochTicks: Int64 = 621_355_968_000_000_000
        if ticks > epochTicks {
            let seconds = Double(ticks - epochTicks) / 10_000_000.0
            let date = Date(timeIntervalSince1970: seconds)
            return ISO8601DateFormatter().string(from: date)
        } else {
            return "\(ticks)"
        }
    }

    private static func cleanPipedString(_ raw: String?) -> String? {
        guard let raw = raw, !raw.isEmpty else { return nil }
        let parts = raw.split(separator: "|")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "N/A" }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private static func unescapeHtml(_ text: String?) -> String? {
        guard let text = text else { return nil }
        return text
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
    }

    // MARK: - User DB Import

    public func importUserDb(path: String) throws -> (folders: Int, works: Int, artists: Int) {
        let src = try Self.openReadOnlyDb(at: path)
        var folderCount = 0
        var workCount = 0
        var artistCount = 0

        try src.read { db in
            let groups = try Row.fetchAll(db, sql: "SELECT * FROM BookmarkGroup ORDER BY Gorder ASC, Id ASC")
            var groupMap: [Int64: Int64] = [:]
            var assignedColors: Set<Int64> = []

            for group in groups {
                guard let violetId = Self.safeInt64(from: group, column: "Id")
                    ?? Self.safeInt64(from: group, column: "id") else { continue }
                var name = Self.safeString(from: group, column: "Name")
                    ?? Self.safeString(from: group, column: "name") ?? L10n.text("Folders")
                let rawColor = Self.safeInt64(from: group, column: "Color")
                    ?? Self.safeInt64(from: group, column: "color")
                if name == "violet_default" { name = "미분류" }

                let colorInt: Int64
                if let raw = rawColor, raw != 4294940672, raw != 0, !assignedColors.contains(raw) {
                    colorInt = raw
                } else {
                    colorInt = appDb.nextUniqueFolderColor(excluding: assignedColors)
                }
                assignedColors.insert(colorInt)

                let desc = Self.safeString(from: group, column: "Description")
                let folder = try appDb.createFolder(name: name, description: desc, color: colorInt, violetGroupId: violetId)
                if let folderId = folder.id {
                    groupMap[violetId] = folderId
                    folderCount += 1
                }
            }

            let defaultFolder = try appDb.ensureDefaultFolder()
            let defaultFolderId = defaultFolder.id ?? 1

            if groupMap[1] == nil { groupMap[1] = defaultFolderId }
            if groupMap[0] == nil { groupMap[0] = defaultFolderId }

            let articles = try Row.fetchAll(db, sql: "SELECT * FROM BookmarkArticle ORDER BY DateTime DESC, Id DESC")
            for article in articles {
                guard let galleryId = Self.safeInt64(from: article, column: "Article")
                    ?? Self.safeInt64(from: article, column: "article")
                    ?? Self.safeInt64(from: article, column: "GalleryId")
                    ?? Self.safeInt64(from: article, column: "Id") else { continue }

                let rawGroupId = Self.safeInt64(from: article, column: "GroupId")
                    ?? Self.safeInt64(from: article, column: "group_id")
                    ?? Self.safeInt64(from: article, column: "Group")

                let targetFolderId: Int64
                if let rawGroupId, let mapped = groupMap[rawGroupId] {
                    targetFolderId = mapped
                } else {
                    targetFolderId = defaultFolderId
                }

                let catalog = try appDb.getCatalog(galleryId: galleryId)
                let bookmarkedAt = Self.safeString(from: article, column: "DateTime")

                _ = try appDb.upsertWork(
                    galleryId: galleryId,
                    folderId: targetFolderId,
                    title: catalog?.title,
                    artists: catalog?.artists,
                    language: catalog?.language,
                    type: catalog?.type,
                    series: catalog?.series,
                    groups: catalog?.groups,
                    tags: catalog?.tags,
                    publishedAt: catalog?.published,
                    bookmarkedAt: bookmarkedAt,
                    metadataSource: catalog != nil ? "catalog" : nil,
                    catalogMatched: catalog != nil
                )
                workCount += 1
            }

            // Prune works from defaultFolderId if they belong to any other folder
            try? appDb.dbWriter.write { db in
                try db.execute(sql: """
                DELETE FROM folder_works
                WHERE folder_id = ?
                  AND work_id IN (SELECT work_id FROM folder_works WHERE folder_id != ?)
                """, arguments: [defaultFolderId, defaultFolderId])
            }

            if try db.tableExists("BookmarkArtist") {
                let artistRows = try Row.fetchAll(db, sql: "SELECT * FROM BookmarkArtist")
                for row in artistRows {
                    guard let name = Self.safeString(from: row, column: "Artist"), !name.isEmpty else { continue }
                    let isGroup = Int(Self.safeInt64(from: row, column: "IsGroup") ?? 0)
                    _ = try appDb.addFavoriteArtist(name: name, kind: isGroup)
                    artistCount += 1
                }
            }
        }

        return (folderCount, workCount, artistCount)
    }

    // MARK: - Targeted Fast Match (내 보관함 작품만 즉시 매칭)

    public func matchAndFillWorks(fromDataDb path: String) throws -> (matched: Int, totalWorks: Int) {
        let allTargetIds = try appDb.listAllGalleryIds()
        guard !allTargetIds.isEmpty else {
            return (0, 0)
        }

        let src = try Self.openReadOnlyDb(at: path)
        let chunkSize = 400
        var matchedTotal = 0

        for chunkStart in stride(from: 0, to: allTargetIds.count, by: chunkSize) {
            let chunkEnd = min(chunkStart + chunkSize, allTargetIds.count)
            let idChunk = Array(allTargetIds[chunkStart..<chunkEnd])
            let placeholders = Array(repeating: "?", count: idChunk.count).joined(separator: ",")

            let sql = """
            SELECT Id, Title, Type, Artists, Characters, Groups, Language, Series, Tags, Published
            FROM HitomiColumnModel
            WHERE Id IN (\(placeholders))
            """

            let rows = try src.read { db in
                try Row.fetchAll(db, sql: sql, arguments: StatementArguments(idChunk))
            }

            var batch: [CatalogWork] = []
            batch.reserveCapacity(rows.count)

            for row in rows {
                guard let id = Self.safeInt64(from: row, column: "Id") else { continue }
                let title = Self.unescapeHtml(Self.safeString(from: row, column: "Title"))
                let type = Self.safeString(from: row, column: "Type")
                let language = Self.safeString(from: row, column: "Language")
                let artists = Self.cleanPipedString(Self.safeString(from: row, column: "Artists"))
                let groups = Self.cleanPipedString(Self.safeString(from: row, column: "Groups"))
                let series = Self.cleanPipedString(Self.safeString(from: row, column: "Series"))
                let characters = Self.cleanPipedString(Self.safeString(from: row, column: "Characters"))
                let tags = Self.cleanPipedString(Self.safeString(from: row, column: "Tags"))
                let published = Self.parsePublished(from: row)

                batch.append(CatalogWork(
                    id: id,
                    title: title,
                    type: type,
                    language: language,
                    artists: artists,
                    groups: groups,
                    series: series,
                    characters: characters,
                    tags: tags,
                    published: published
                ))
            }

            if !batch.isEmpty {
                let updated = try appDb.applyCatalogBatchToWorks(batch)
                matchedTotal += updated
            }
        }

        return (matchedTotal, allTargetIds.count)
    }

    // MARK: - Full Catalog Import (수십만 건 전체 저장)

    public func importDataDb(path: String, progress: (@Sendable (Int) -> Void)? = nil) throws -> Int {
        let src = try Self.openReadOnlyDb(at: path)
        let pageSize = 1000
        var lastId: Int64 = 0
        var total = 0

        while true {
            let chunk = try src.read { db in
                let sql = """
                SELECT Id, Title, Type, Artists, Characters, Groups, Language, Series, Tags, Published
                FROM HitomiColumnModel
                WHERE Id > ?
                ORDER BY Id ASC
                LIMIT \(pageSize)
                """
                return try Row.fetchAll(db, sql: sql, arguments: [lastId])
            }
            if chunk.isEmpty { break }

            var batch: [CatalogWork] = []
            batch.reserveCapacity(chunk.count)

            for row in chunk {
                guard let id = Self.safeInt64(from: row, column: "Id") else { continue }
                lastId = id

                let title = Self.unescapeHtml(Self.safeString(from: row, column: "Title"))
                let type = Self.safeString(from: row, column: "Type")
                let language = Self.safeString(from: row, column: "Language")
                let artists = Self.cleanPipedString(Self.safeString(from: row, column: "Artists"))
                let groups = Self.cleanPipedString(Self.safeString(from: row, column: "Groups"))
                let series = Self.cleanPipedString(Self.safeString(from: row, column: "Series"))
                let characters = Self.cleanPipedString(Self.safeString(from: row, column: "Characters"))
                let tags = Self.cleanPipedString(Self.safeString(from: row, column: "Tags"))
                let published = Self.parsePublished(from: row)

                batch.append(CatalogWork(
                    id: id,
                    title: title,
                    type: type,
                    language: language,
                    artists: artists,
                    groups: groups,
                    series: series,
                    characters: characters,
                    tags: tags,
                    published: published
                ))
            }

            try appDb.upsertCatalogBatch(batch)
            total += batch.count
            progress?(total)
        }

        try appDb.applyCatalogToWorks()
        return total
    }
}
