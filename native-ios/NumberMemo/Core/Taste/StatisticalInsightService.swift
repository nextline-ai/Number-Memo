import Foundation
import GRDB

enum TasteInsightPattern: String, Codable, Sendable { case confirmed, discovery, frequent, rising, association }
struct TasteInsight: Codable, Hashable, Identifiable, Sendable {
    var tagKey: String
    var relatedKey: String?
    var pattern: TasteInsightPattern
    var id: String { tagKey + ":" + pattern.rawValue }
}
struct TasteReport: Codable, Sendable, Equatable {
    var version = 2
    var epoch: String
    var digest: String
    var language: String
    var insights: [TasteInsight]
    private enum RetiredKeys: String, CodingKey { case generatedByAI }
    func encode(to encoder: Encoder) throws {
        var legacy = encoder.container(keyedBy: RetiredKeys.self)
        try legacy.encode(false, forKey: .generatedByAI)
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(version, forKey: .version)
        try values.encode(epoch, forKey: .epoch)
        try values.encode(digest, forKey: .digest)
        try values.encode(language, forKey: .language)
        try values.encode(insights, forKey: .insights)
    }
    var id: String { tasteDigest(Data((epoch + digest + language).utf8)) }
    func isValid(for snapshot: TasteSnapshot) -> Bool {
        guard version == 2, digest == snapshot.digest, insights.count <= 3,
              Set(insights.map(\.tagKey)).count == insights.count else { return false }
        return insights.allSatisfy { insight in
            guard let tag = snapshot.tags.first(where: { $0.id == insight.tagKey }), tag.count > 0 else { return false }
            if insight.pattern != .association && insight.relatedKey != nil { return false }
            switch insight.pattern {
            case .frequent: return true
            case .confirmed: return tag.confirmed > 0
            case .discovery: return tag.discovery
            case .rising: return snapshot.previousSaves != nil && tag.count > snapshot.previousTagCounts[tag.id, default: 0]
            case .association:
                guard let related = snapshot.tags.first(where: { $0.id == insight.relatedKey }), related.id != tag.id, related.source == tag.source else { return false }
                let works = Set(tag.works.map(\.key)), theirs = Set(related.works.map(\.key))
                let overlap = works.intersection(theirs).count
                return overlap >= 5 && Double(overlap) / Double(max(works.count, theirs.count)) >= 0.8
            }
        }
    }
}

enum StatisticalInsightService {
    static func report(snapshot: TasteSnapshot, control: TasteControl, language: String, selectionOffset: Int = 0) async -> TasteReport {
        let eligible = Array(snapshot.tags.filter { $0.count > 0 }.prefix(24))
        let rotated = eligible.isEmpty ? [] : (0..<eligible.count).map { eligible[(max(0, selectionOffset) + $0) % eligible.count] }
        var fallback = rotated.filter(\.discovery).prefix(1).map { TasteInsight(tagKey: $0.id, pattern: .discovery) }
        for tag in rotated where !fallback.contains(where: { $0.tagKey == tag.id }) {
            if fallback.count == 3 { break }
            let rising = snapshot.previousSaves != nil && tag.count >= 3 && tag.count > snapshot.previousTagCounts[tag.id, default: 0]
            fallback.append(.init(tagKey: tag.id, pattern: rising ? .rising : tag.confirmed > 0 ? .confirmed : .frequent))
        }
        return TasteReport(epoch: control.epoch, digest: snapshot.digest, language: language, insights: fallback)
    }
}

extension TasteStore {
    func report(digest: String, language: String, epoch: String) throws -> TasteReport? {
        let id = tasteDigest(Data((epoch + digest + language).utf8))
        return try database.read { try Data.fetchOne($0, sql: "SELECT payload FROM taste_reports WHERE id = ?", arguments: [id]).map { try JSONDecoder().decode(TasteReport.self, from: $0) } }
    }
    func saveReport(_ report: TasteReport, uploaded: Bool = false) throws {
        try database.write { db in
            guard try Self.control(db).epoch == report.epoch else { return }
            if let data = try Data.fetchOne(db, sql: "SELECT payload FROM taste_reports WHERE id = ?", arguments: [report.id]),
               let existing = try? JSONDecoder().decode(TasteReport.self, from: data), existing == report { return }
            try db.execute(sql: "INSERT OR REPLACE INTO taste_reports VALUES (?, ?, ?)", arguments: [report.id, try JSONEncoder().encode(report), uploaded])
        }
    }
    func pendingReports() throws -> [TasteReport] {
        try database.read { try Data.fetchAll($0, sql: "SELECT payload FROM taste_reports WHERE uploaded = 0 LIMIT 20").map { try JSONDecoder().decode(TasteReport.self, from: $0) } }
    }
    func acknowledgeReports(_ ids: [String]) throws {
        try database.write { db in for id in ids { try db.execute(sql: "UPDATE taste_reports SET uploaded = 1 WHERE id = ?", arguments: [id]) } }
    }
}
