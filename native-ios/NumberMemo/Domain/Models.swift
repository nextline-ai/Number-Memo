import Foundation
import GRDB

public struct Folder: Identifiable, Codable, Equatable, Hashable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "folders"

    public var id: Int64?
    public var name: String
    public var displayName: String { L10n.folderName(name) }
    public var description: String?
    public var color: Int64 // ARGB 32-bit integer
    public var sortOrder: Int
    public var createdAt: String
    public var violetGroupId: Int64?
    public var workCount: Int

    public init(
        id: Int64? = nil,
        name: String,
        description: String? = nil,
        color: Int64 = 4288585374,
        sortOrder: Int = 0,
        createdAt: String = ISO8601DateFormatter().string(from: Date()),
        violetGroupId: Int64? = nil,
        workCount: Int = 0
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.color = color
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.violetGroupId = violetGroupId
        self.workCount = workCount
    }

    public typealias Columns = CodingKeys

    public enum CodingKeys: String, CodingKey, ColumnExpression {
        case id
        case name
        case description
        case color
        case sortOrder = "sort_order"
        case createdAt = "created_at"
        case violetGroupId = "violet_group_id"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(Int64.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        color = try container.decode(Int64.self, forKey: .color)
        sortOrder = try container.decode(Int.self, forKey: .sortOrder)
        createdAt = try container.decode(String.self, forKey: .createdAt)
        violetGroupId = try container.decodeIfPresent(Int64.self, forKey: .violetGroupId)
        workCount = 0
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encode(color, forKey: .color)
        try container.encode(sortOrder, forKey: .sortOrder)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(violetGroupId, forKey: .violetGroupId)
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

public struct Work: Identifiable, Codable, Equatable, Hashable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "works"

    public var id: Int64?
    public var galleryId: Int64
    public var title: String?
    public var artists: String?
    public var language: String?
    public var type: String?
    public var series: String?
    public var groups: String?
    public var tags: String?
    public var note: String?
    public var bookmarkedAt: String
    public var publishedAt: String?
    public var lastOpenedAt: String?
    public var updatedAt: String?
    public var metadataSource: String?
    public var catalogMatched: Bool
    public var thumbStatus: String // missing, ready, failed, gone
    public var thumbPath: String?
    public var thumbFailedAt: String?
    public var thumbPage: Int?

    public var folders: [Folder] = []

    public var hasTitle: Bool {
        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        return !title.isEmpty
    }

    public var hasThumb: Bool {
        thumbStatus == "ready" && thumbPath != nil && FileManager.default.fileExists(atPath: thumbPath!)
    }

    public init(
        id: Int64? = nil,
        galleryId: Int64,
        title: String? = nil,
        artists: String? = nil,
        language: String? = nil,
        type: String? = nil,
        series: String? = nil,
        groups: String? = nil,
        tags: String? = nil,
        note: String? = nil,
        bookmarkedAt: String = ISO8601DateFormatter().string(from: Date()),
        publishedAt: String? = nil,
        lastOpenedAt: String? = nil,
        updatedAt: String? = nil,
        metadataSource: String? = nil,
        catalogMatched: Bool = false,
        thumbStatus: String = "missing",
        thumbPath: String? = nil,
        thumbFailedAt: String? = nil,
        thumbPage: Int? = 1,
        folders: [Folder] = []
    ) {
        self.id = id
        self.galleryId = galleryId
        self.title = title
        self.artists = artists
        self.language = language
        self.type = type
        self.series = series
        self.groups = groups
        self.tags = tags
        self.note = note
        self.bookmarkedAt = bookmarkedAt
        self.publishedAt = publishedAt
        self.lastOpenedAt = lastOpenedAt
        self.updatedAt = updatedAt
        self.metadataSource = metadataSource
        self.catalogMatched = catalogMatched
        self.thumbStatus = thumbStatus
        self.thumbPath = thumbPath
        self.thumbFailedAt = thumbFailedAt
        self.folders = folders
    }

    public typealias Columns = CodingKeys

    public enum CodingKeys: String, CodingKey, ColumnExpression {
        case id
        case galleryId = "gallery_id"
        case title
        case artists
        case language
        case type
        case series
        case groups
        case tags
        case note
        case bookmarkedAt = "bookmarked_at"
        case publishedAt = "published_at"
        case lastOpenedAt = "last_opened_at"
        case updatedAt = "updated_at"
        case metadataSource = "metadata_source"
        case catalogMatched = "catalog_matched"
        case thumbStatus = "thumb_status"
        case thumbPath = "thumb_path"
        case thumbFailedAt = "thumb_failed_at"
        case thumbPage = "thumb_page"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(Int64.self, forKey: .id)
        galleryId = try container.decode(Int64.self, forKey: .galleryId)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        artists = try container.decodeIfPresent(String.self, forKey: .artists)
        language = try container.decodeIfPresent(String.self, forKey: .language)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        series = try container.decodeIfPresent(String.self, forKey: .series)
        groups = try container.decodeIfPresent(String.self, forKey: .groups)
        tags = try container.decodeIfPresent(String.self, forKey: .tags)
        note = try container.decodeIfPresent(String.self, forKey: .note)
        bookmarkedAt = try container.decode(String.self, forKey: .bookmarkedAt)
        publishedAt = try container.decodeIfPresent(String.self, forKey: .publishedAt)
        lastOpenedAt = try container.decodeIfPresent(String.self, forKey: .lastOpenedAt)
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
        metadataSource = try container.decodeIfPresent(String.self, forKey: .metadataSource)
        catalogMatched = try container.decodeIfPresent(Bool.self, forKey: .catalogMatched) ?? false
        thumbStatus = try container.decodeIfPresent(String.self, forKey: .thumbStatus) ?? "missing"
        thumbPath = try container.decodeIfPresent(String.self, forKey: .thumbPath)
        thumbFailedAt = try container.decodeIfPresent(String.self, forKey: .thumbFailedAt)
        thumbPage = try container.decodeIfPresent(Int.self, forKey: .thumbPage) ?? 1
        folders = []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encode(galleryId, forKey: .galleryId)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(artists, forKey: .artists)
        try container.encodeIfPresent(language, forKey: .language)
        try container.encodeIfPresent(type, forKey: .type)
        try container.encodeIfPresent(series, forKey: .series)
        try container.encodeIfPresent(groups, forKey: .groups)
        try container.encodeIfPresent(tags, forKey: .tags)
        try container.encodeIfPresent(note, forKey: .note)
        try container.encode(bookmarkedAt, forKey: .bookmarkedAt)
        try container.encodeIfPresent(publishedAt, forKey: .publishedAt)
        try container.encodeIfPresent(lastOpenedAt, forKey: .lastOpenedAt)
        try container.encodeIfPresent(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(metadataSource, forKey: .metadataSource)
        try container.encode(catalogMatched, forKey: .catalogMatched)
        try container.encode(thumbStatus, forKey: .thumbStatus)
        try container.encodeIfPresent(thumbPath, forKey: .thumbPath)
        try container.encodeIfPresent(thumbFailedAt, forKey: .thumbFailedAt)
        try container.encodeIfPresent(thumbPage, forKey: .thumbPage)
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

public struct CatalogWork: Identifiable, Codable, Equatable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "catalog_works"

    public var id: Int64 // gallery_id
    public var title: String?
    public var type: String?
    public var language: String?
    public var artists: String?
    public var groups: String?
    public var series: String?
    public var characters: String?
    public var tags: String?
    public var published: String?

    public init(
        id: Int64,
        title: String? = nil,
        type: String? = nil,
        language: String? = nil,
        artists: String? = nil,
        groups: String? = nil,
        series: String? = nil,
        characters: String? = nil,
        tags: String? = nil,
        published: String? = nil
    ) {
        self.id = id
        self.title = title
        self.type = type
        self.language = language
        self.artists = artists
        self.groups = groups
        self.series = series
        self.characters = characters
        self.tags = tags
        self.published = published
    }
}

public struct ArtistMemo: Identifiable, Codable, Equatable, Hashable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "artists"

    public var id: Int64?
    public var name: String
    public var kind: Int // 0: artist, 1: group
    public var note: String?
    public var folderId: Int64?
    public var bookmarkedAt: String

    public init(
        id: Int64? = nil,
        name: String,
        kind: Int = 0,
        note: String? = nil,
        folderId: Int64? = nil,
        bookmarkedAt: String = ISO8601DateFormatter().string(from: Date())
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.note = note
        self.folderId = folderId
        self.bookmarkedAt = bookmarkedAt
    }

    public typealias Columns = CodingKeys

    public enum CodingKeys: String, CodingKey, ColumnExpression {
        case id
        case name
        case kind
        case note
        case folderId = "folder_id"
        case bookmarkedAt = "bookmarked_at"
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

public struct SaveResult: Sendable {
    public let works: [Work]
    public let created: Int
    public let duplicates: Int

    public init(works: [Work], created: Int, duplicates: Int) {
        self.works = works
        self.created = created
        self.duplicates = duplicates
    }
}

public struct IdentifiableInt64: Identifiable, Hashable, Sendable {
    public let id: Int64
    public init(id: Int64) { self.id = id }
}

public struct IdentifiableString: Identifiable, Hashable, Sendable {
    public let id: String
    public init(id: String) { self.id = id }
}
