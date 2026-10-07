import Foundation
import CryptoKit
import SwiftUI

public struct DiscoveryContext: Codable, Hashable, Sendable {
    enum Origin: String, Codable, Sendable { case search, feed, recommendation, library, external }
    var origin: Origin
    var session: String
    var included: Set<String>
    var constraints: Set<String>
    var recommendationTags: Set<String>?
    init(origin: Origin = .external, query: String = "", defaults: String = "", session: String = UUID().uuidString) {
        self.origin = origin; self.session = session
        included = Set(query.split(whereSeparator: \.isWhitespace).map(String.init).filter { !$0.hasPrefix("-") }.map(TasteTagPolicy.normalize))
        constraints = Set(defaults.split(whereSeparator: \.isWhitespace).map { TasteTagPolicy.normalize(String($0).trimmingCharacters(in: CharacterSet(charactersIn: "-"))) })
        constraints.formUnion(query.split(whereSeparator: \.isWhitespace).filter { $0.hasPrefix("-") }.map { TasteTagPolicy.normalize(String($0.dropFirst())) })
    }
    enum CodingKeys: String, CodingKey { case origin, session, included, constraints, recommendationTags }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(origin, forKey: .origin); try container.encode(session, forKey: .session)
        try container.encode(included.sorted(), forKey: .included); try container.encode(constraints.sorted(), forKey: .constraints)
        try container.encodeIfPresent(recommendationTags?.sorted(), forKey: .recommendationTags)
    }
    static let unknown = DiscoveryContext(origin: .external, session: "unknown")
    static func recommended(_ tag: String, session: String) -> Self {
        var value = Self(origin: .recommendation, session: session)
        value.recommendationTags = [TasteTagPolicy.normalize(tag)]
        return value
    }
    // A deliberate save from recommendations is evidence, but never a search.
    var preferenceAction: Bool { organic || (origin == .recommendation && recommendationTags != nil) }
    var chosenTags: Set<String> { Set((origin == .recommendation ? recommendationTags ?? [] : included).map(TasteTagPolicy.normalize)) }
    var organic: Bool { origin == .search || origin == .feed }
}

private struct DiscoveryContextKey: EnvironmentKey { static let defaultValue = DiscoveryContext.unknown }
extension EnvironmentValues {
    var discoveryContext: DiscoveryContext {
        get { self[DiscoveryContextKey.self] }
        set { self[DiscoveryContextKey.self] = newValue }
    }
}

enum TasteTagPolicy {
    static let version = 2
    // Exact matches only. Unknown and artistic categories remain eligible.
    static let technical: Set<String> = [
        "jpg", "jpeg", "png", "gif", "webp", "avif", "apng", "bmp", "tiff", "svg", "mp4", "webm", "mov", "flash", "video", "animated", "animated_gif", "animated_png", "sound", "audio", "no_sound",
        "highres", "absurdres", "incredibly_absurdres", "lowres", "huge_filesize", "big_filesize", "small_filesize", "wide_image", "tall_image", "jpeg_artifacts", "compression_artifacts",
        "tagme", "translation_request", "translated", "partially_translated", "check_translation", "commentary_request", "commentary", "translated_commentary", "source_request", "bad_id", "bad_link", "bad_pixiv_id", "bad_twitter_id", "duplicate", "revision", "resized", "upscaled", "md5_mismatch", "corrupted_file"
    ]
    static let operators: Set<String> = ["rating", "order", "sort", "score", "id", "width", "height", "mpixels", "filesize", "filetype", "status", "date", "age", "pool", "limit", "page", "language", "type"]
    static func normalize(_ tag: String) -> String { tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: " ", with: "_") }
    static func eligible(_ tag: String, metadata: Set<String> = []) -> Bool {
        let tag = normalize(tag)
        guard !tag.isEmpty, !technical.contains(tag), !metadata.contains(tag), !tag.hasPrefix("-") else { return false }
        if let colon = tag.firstIndex(of: ":"), operators.contains(String(tag[..<colon])) { return false }
        return !tag.contains("*") && !tag.contains("~") && !tag.contains("{") && !tag.contains("}")
    }
    static func filter(_ tags: [String], metadata: [String] = []) -> [String] {
        let blocked = Set(metadata.map(normalize))
        return Set(tags.map(normalize).filter { eligible($0, metadata: blocked) }).sorted()
    }
}

enum TasteMode: String, Codable, Sendable { case booru, comics }
struct TasteItem: Codable, Hashable, Sendable {
    var source: String
    var id: Int64
    var tags: [String]
    var metadata: [String] = []
    var key: String { source + "#" + String(id) }
    var eligibleTags: [String] { TasteTagPolicy.filter(tags, metadata: metadata) }
    static func comic(_ id: Int64, tags: String? = nil) -> Self {
        .init(source: "https://hitomi.la", id: id, tags: (tags ?? "").components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) })
    }
}

struct TasteEvent: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable { case save, remove, open, search, seed, imported, metadata, taxonomy }
    var id: String = UUID().uuidString
    var epoch: String = "initial"
    var generation: String = "initial"
    var device: String = ""
    var at: Double = Date().timeIntervalSince1970
    var kind: Kind
    var item: TasteItem
    var context: DiscoveryContext = .unknown
    static func ordered(_ a: Self, _ b: Self) -> Bool { a.at == b.at ? a.id < b.id : a.at < b.at }
}

struct TasteControl: Codable, Equatable, Sendable {
    var version = 1
    var timestamp: Double = 0
    var author: String = ""
    var epoch = "initial"
    var generation = "initial"
    var enabled = true
    var enabledTimestamp: Double = 0
    var enabledAuthor = ""
    var resetTimestamp: Double = 0
    var resetAuthor = ""
    var aiEnabled = true
    var cloudEnabled = true
    var timeZone = TimeZone.current.identifier
    var excluded: Set<String> = []
    // Optional for backward-compatible decoding of existing local and iCloud controls.
    var analysisExclusions: [String: [String]]?
    func analysisExcluded(_ mode: TasteMode) -> Set<String> {
        if let saved = analysisExclusions?[mode.rawValue] { return Set(saved.map { Self.normalizeAnalysisExclusion($0, mode: mode) }) }
        return mode == .comics ? ["female:sole_female", "male:sole_male", "tag:digital", "tag:group"] : ["1girl", "1boy", "solo"]
    }
    mutating func setAnalysisExcluded(_ tags: Set<String>, mode: TasteMode) {
        if analysisExclusions == nil { analysisExclusions = [:] }
        analysisExclusions?[mode.rawValue] = Set(tags.map { Self.normalizeAnalysisExclusion($0, mode: mode) }.filter { !$0.isEmpty }).sorted()
    }
    static func normalizeExclusion(_ value: String) -> String {
        value.components(separatedBy: ":").map { part in
            part.lowercased().split(whereSeparator: { $0.isWhitespace || $0 == "_" }).joined(separator: "_")
        }.joined(separator: ":")
    }
    // Repair the original default spelling at the exclusion boundary only.
    // Keep stored artwork tags, search queries and statistical identities unchanged.
    static func normalizeAnalysisExclusion(_ value: String, mode: TasteMode) -> String {
        let normalized = normalizeExclusion(value)
        guard mode == .comics else { return normalized }
        switch normalized {
        case "female:solo_female": return "female:sole_female"
        case "male:solo_male": return "male:sole_male"
        case "solo_female": return "sole_female"
        case "solo_male": return "sole_male"
        default: return normalized
        }
    }
    func allows(_ tag: String, source: String, mode: TasteMode) -> Bool {
        let normalized = Self.normalizeAnalysisExclusion(tag, mode: mode)
        func matches(_ exclusion: String) -> Bool {
            let blocked = Self.normalizeAnalysisExclusion(exclusion, mode: mode)
            if normalized == blocked { return true }
            // Older Hitomi metadata/imports stored tag values without namespaces.
            // Match those exact legacy values, never a different explicit namespace.
            guard mode == .comics, !normalized.contains(":"),
                  let colon = blocked.firstIndex(of: ":"),
                  ["female", "male", "tag"].contains(String(blocked[..<colon])) else { return false }
            return normalized == String(blocked[blocked.index(after: colon)...])
        }
        return !analysisExcluded(mode).contains(where: matches) && !excluded.contains(where: { key in
            let parts = key.components(separatedBy: "\n")
            return parts.count == 2 && parts[0] == source && matches(parts[1])
        })
    }
    func analysisKey(_ mode: TasteMode) -> String {
        let values = [epoch, timeZone, String(aiEnabled), String(enabled)] + analysisExcluded(mode).sorted() + excluded.sorted()
        return tasteDigest((try? JSONEncoder().encode(values)) ?? Data())
    }
    func newer(than other: Self) -> Bool { timestamp == other.timestamp ? author > other.author : timestamp > other.timestamp }
    func merged(with other: Self) -> Self {
        var result = other.newer(than: self) ? other : self
        let reset = other.resetTimestamp > resetTimestamp || (other.resetTimestamp == resetTimestamp && other.resetAuthor > resetAuthor) ? other : self
        result.epoch = reset.epoch; result.resetTimestamp = reset.resetTimestamp; result.resetAuthor = reset.resetAuthor
        let permission = other.enabledTimestamp > enabledTimestamp || (other.enabledTimestamp == enabledTimestamp && other.enabledAuthor > enabledAuthor) ? other : self
        result.enabled = permission.enabled; result.enabledTimestamp = permission.enabledTimestamp; result.enabledAuthor = permission.enabledAuthor; result.generation = permission.generation
        return result
    }
    var validCloudControl: Bool { version == 1 && (epoch == "initial" || UUID(uuidString: epoch) != nil) && TimeZone(identifier: timeZone) != nil }
    static func tagKey(source: String, tag: String) -> String { source + "\n" + tag }
}

struct TasteTag: Identifiable, Hashable, Sendable {
    var source: String
    var name: String
    var confirmed = 0
    var hidden = 0
    var general = 0
    var searches = 0
    var opened = 0
    var sessions: Set<String> = []
    var works: [TasteItem] = []
    var lift: Double?
    var previouslySearched = false
    var id: String { TasteControl.tagKey(source: source, tag: name) }
    var discovery: Bool { !previouslySearched && hidden >= 5 && sessions.count >= 3 && (lift.map { $0 > 1 } ?? true) }
    var count: Int { confirmed + hidden + general }
    var weight: Double { log1p(Double(count)) * (lift.map { min(3, max(0.25, $0)) } ?? 1) }
}

struct TasteSnapshot: Sendable {
    var tags: [TasteTag]
    var saves: Int
    var opens: Int
    var searches: Int
    var activity: [Date: Int]
    var digest: String
    var period: DateInterval?
    var previousSaves: Int?
    var previousTagCounts: [String: Int] = [:]
}

enum TastePeriod: String, CaseIterable, Identifiable { case recommendations, week, month
    var id: String { rawValue }
    var title: String { switch self { case .recommendations: L10n.text("Recommendations"); case .week: L10n.text("Weekly"); case .month: L10n.text("Monthly") } }
    func interval(offset: Int, now: Date, timeZone: String) -> DateInterval? {
        guard self != .recommendations else { return nil }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: timeZone) ?? .gmt
        calendar.firstWeekday = 2; calendar.minimumDaysInFirstWeek = 4
        let unit: Calendar.Component = self == .week ? .weekOfYear : .month
        guard let date = calendar.date(byAdding: unit, value: offset, to: now) else { return nil }
        return calendar.dateInterval(of: unit, for: date)
    }
}

func tasteDigest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
