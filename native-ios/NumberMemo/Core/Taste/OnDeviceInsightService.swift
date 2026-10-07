import Foundation
import GRDB
#if canImport(FoundationModels)
import FoundationModels
#endif

enum TasteInsightPattern: String, Codable, Sendable { case confirmed, discovery, frequent, rising, association }
struct TasteInsight: Codable, Hashable, Identifiable, Sendable {
    var tagKey: String
    var relatedKey: String?
    var pattern: TasteInsightPattern
    var id: String { tagKey + ":" + pattern.rawValue }
}
struct TasteReport: Codable, Sendable, Equatable {
    var version = 1
    var epoch: String
    var digest: String
    var language: String
    var insights: [TasteInsight]
    var generatedByAI: Bool
    var id: String { tasteDigest(Data((epoch + digest + language).utf8)) }
    func isValid(for snapshot: TasteSnapshot) -> Bool {
        guard version == 1, digest == snapshot.digest, insights.count <= 3,
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

/// Deliberately incapable of carrying tag names, URLs, titles, or source IDs.
struct AnonymousTasteInput: Codable, Sendable {
    struct Candidate: Codable, Sendable {
        var token: String
        var saved: Int
        var confirmed: Int
        var searches: Int
        var lift: Double?
        var patterns: [TasteInsightPattern]
        var relatedToken: String?
    }
    var candidates: [Candidate]
    var savedCount: Int
    var previousSavedCount: Int?
}

struct TastePromptBoundary: Sendable {
    let input: AnonymousTasteInput
    private let mapping: [String: TasteTag]
    init(snapshot: TasteSnapshot) {
        let tags = Array(snapshot.tags.filter { $0.count > 0 }.prefix(24)).shuffled()
        var mapping: [String: TasteTag] = [:]
        var candidates: [AnonymousTasteInput.Candidate] = []
        for (i, tag) in tags.enumerated() { mapping["T\(i + 1)"] = tag }
        for (i, tag) in tags.enumerated() {
            var patterns: [TasteInsightPattern] = [.frequent]
            if tag.confirmed > 0 { patterns.append(.confirmed) }
            if tag.discovery { patterns.append(.discovery) }
            if snapshot.previousSaves != nil, tag.count > snapshot.previousTagCounts[tag.id, default: 0] { patterns.append(.rising) }
            let works = Set(tag.works.map(\.key))
            let related = mapping.sorted(by: { $0.key < $1.key }).first { _, other in
                guard other.id != tag.id, other.source == tag.source, works.count >= 5 else { return false }
                let theirs = Set(other.works.map(\.key)); let overlap = works.intersection(theirs).count
                return overlap >= 5 && Double(overlap) / Double(max(works.count, theirs.count)) >= 0.8
            }?.key
            if related != nil { patterns.append(.association) }
            candidates.append(.init(token: "T\(i + 1)", saved: tag.count, confirmed: tag.confirmed, searches: tag.searches, lift: tag.lift, patterns: patterns, relatedToken: related))
        }
        self.mapping = mapping
        input = .init(candidates: candidates, savedCount: snapshot.saves, previousSavedCount: snapshot.previousSaves)
    }
    func validate(_ selections: [(String, String)]) -> [TasteInsight]? {
        guard !selections.isEmpty, selections.count <= 3, Set(selections.map(\.0)).count == selections.count else { return nil }
        var insights: [TasteInsight] = []
        for (token, rawPattern) in selections {
            guard let tag = mapping[token], let pattern = TasteInsightPattern(rawValue: rawPattern),
                  let candidate = input.candidates.first(where: { $0.token == token }), candidate.patterns.contains(pattern) else { return nil }
            insights.append(.init(tagKey: tag.id, relatedKey: pattern == .association ? candidate.relatedToken.flatMap { mapping[$0]?.id } : nil, pattern: pattern))
        }
        return insights
    }
}

struct OnDeviceInsightService {
    static func prioritize(_ candidates: [TasteRecommendation], control: TasteControl) async -> [TasteRecommendation] {
        guard control.enabled, control.aiEnabled, !candidates.isEmpty else { return candidates }
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), SystemLanguageModel.default.isAvailable {
            guard !Task.isCancelled, await InsightGenerationBudget.shared.begin() else { return candidates }
            let boundary = RecommendationPromptBoundary(candidates)
            do {
                let tokens = try await withThrowingTaskGroup(of: [String].self) { group in
                    group.addTask {
                        let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: "Choose up to three distinct candidate tokens to introduce first, using only their supplied scores and evidence. Do not infer what tokens represent or invent candidates. Prefer supported choices while including a discovery when evidence supports it.")
                        let response = try await session.respond(to: String(decoding: JSONEncoder().encode(boundary.input), as: UTF8.self), generating: GeneratedTasteCandidates.self)
                        return response.content.tokens
                    }
                    group.addTask { try await InsightGenerationBudget.watchRuntime(); throw CancellationError() }
                    defer { group.cancelAll() }
                    return try await group.next() ?? []
                }
                try Task.checkCancellation()
                if let selected = boundary.validate(tokens) {
                    let keys = Set(selected.map(\.id))
                    await InsightGenerationBudget.shared.finish()
                    return selected + candidates.filter { !keys.contains($0.id) }
                }
            } catch { /* Invalid output, refusal, and cancellation preserve the statistical ordering. */ }
            await InsightGenerationBudget.shared.finish()
        }
        #endif
        return candidates
    }
    static var canGenerate: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) { return SystemLanguageModel.default.isAvailable }
        #endif
        return false
    }
    static var availabilityMessage: String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return L10n.text("On-device AI available")
            case .unavailable(.appleIntelligenceNotEnabled): return L10n.text("Enable Apple Intelligence for AI insights.")
            case .unavailable(.modelNotReady): return L10n.text("The on-device model is not ready yet.")
            default: return L10n.text("Statistical insights are available on this device.")
            }
        }
        #endif
        return L10n.text("Statistical insights are available on this device.")
    }
    static func report(snapshot: TasteSnapshot, control: TasteControl, language: String, selectionOffset: Int = 0) async -> TasteReport {
        let boundary = TastePromptBoundary(snapshot: snapshot)
        let eligible = Array(snapshot.tags.filter { $0.count > 0 }.prefix(24))
        let rotated = eligible.isEmpty ? [] : (0..<eligible.count).map { eligible[(max(0, selectionOffset) + $0) % eligible.count] }
        var fallback = rotated.filter(\.discovery).prefix(1).map { TasteInsight(tagKey: $0.id, pattern: .discovery) }
        for tag in rotated where !fallback.contains(where: { $0.tagKey == tag.id }) {
            if fallback.count == 3 { break }
            fallback.append(.init(tagKey: tag.id, pattern: tag.confirmed > 0 ? .confirmed : .frequent))
        }
        var result = TasteReport(epoch: control.epoch, digest: snapshot.digest, language: language, insights: fallback, generatedByAI: false)
        guard control.enabled, control.aiEnabled, !boundary.input.candidates.isEmpty else { return result }
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), SystemLanguageModel.default.isAvailable {
            let key = InsightGenerationBudget.key(snapshot, control: control, language: language)
            if let cached = await InsightGenerationBudget.shared.cached(key, snapshot: snapshot) { return cached }
            guard !Task.isCancelled, await InsightGenerationBudget.shared.begin() else { return result }
            do {
                let selections = try await withThrowingTaskGroup(of: [(String, String)].self) { group in
                    group.addTask { try await generate(boundary.input) }
                    group.addTask { try await InsightGenerationBudget.watchRuntime(); throw CancellationError() }
                    defer { group.cancelAll() }
                    return try await group.next() ?? []
                }
                try Task.checkCancellation()
                if let validated = boundary.validate(selections) { result.insights = validated; result.generatedByAI = true }
            } catch { /* Keep the statistical result; never log prompts or model transcripts. */ }
            await InsightGenerationBudget.shared.save(result, key: key)
            await InsightGenerationBudget.shared.finish()
        }
        #endif
        return result
    }
    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private static func generate(_ input: AnonymousTasteInput) async throws -> [(String, String)] {
        let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: "Select up to three distinct meaningful patterns from the supplied anonymous statistical candidates. Use only the supplied token and one of its allowed patterns. Prefer well-supported discoveries and changes. Do not infer what tokens mean. Do not calculate numbers or generate prose.")
        let prompt = String(decoding: try JSONEncoder().encode(input), as: UTF8.self)
        let response = try await session.respond(to: prompt, generating: GeneratedTasteReport.self)
        return response.content.selections.map { ($0.token, $0.pattern.rawValue) }
    }
    #endif
}
#if canImport(FoundationModels)
@available(iOS 26.0, *) @Generable
private enum GeneratedTastePattern: String { case confirmed, discovery, frequent, rising, association }
@available(iOS 26.0, *) @Generable
private struct GeneratedTasteSelection { var token: String; var pattern: GeneratedTastePattern }
@available(iOS 26.0, *) @Generable
private struct GeneratedTasteReport { var selections: [GeneratedTasteSelection] }
@available(iOS 26.0, *) @Generable
private struct GeneratedTasteCandidates { var tokens: [String] }
#endif

struct RecommendationPromptBoundary: Sendable {
    struct Candidate: Encodable, Sendable { var token: String; var score: Double; var savedEvidence: Int; var discovery: Bool }
    let input: [Candidate]
    private let mapping: [String: TasteRecommendation]
    init(_ candidates: [TasteRecommendation]) {
        let pairs = candidates.shuffled().enumerated().map { ("C\($0.offset + 1)", $0.element) }
        mapping = Dictionary(uniqueKeysWithValues: pairs)
        input = pairs.map { Candidate(token: $0.0, score: $0.1.score, savedEvidence: $0.1.reason.count, discovery: $0.1.reason.discovery) }
    }
    func validate(_ tokens: [String]) -> [TasteRecommendation]? {
        guard !tokens.isEmpty, tokens.count <= 3, Set(tokens).count == tokens.count, tokens.allSatisfy({ mapping[$0] != nil }) else { return nil }
        return tokens.compactMap { mapping[$0] }
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
            // Keep a generated report when another device only has the fallback.
            if let data = try Data.fetchOne(db, sql: "SELECT payload FROM taste_reports WHERE id = ?", arguments: [report.id]),
               let existing = try? JSONDecoder().decode(TasteReport.self, from: data), existing == report || (existing.generatedByAI && !report.generatedByAI) { return }
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
