import Foundation
import UIKit

struct InsightGenerationPolicy {
    static let window: TimeInterval = 5 * 60
    static let limit = 3
    var starts: [TimeInterval] = []
    var running = false
    mutating func begin(now: TimeInterval, foreground: Bool, lowPower: Bool) -> Bool {
        guard foreground, !lowPower, !running else { return false }
        starts.removeAll { now - $0 >= Self.window }
        guard starts.count < Self.limit else { return false }
        starts.append(now); running = true
        return true
    }
    mutating func finish() { running = false }
}

/// Shared by reports and candidate ordering: no parallel model sessions or queued
/// catch-up bursts. Up to three starts per rolling five minutes, persisted across
/// launches. Calls within that allowance need no spacing. Temperature is not a gate.
actor InsightGenerationBudget {
    static let shared = InsightGenerationBudget()
    private var policy: InsightGenerationPolicy
    private let defaults: UserDefaults
    private var reports: [String: TasteReport] = [:]
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let previous = defaults.object(forKey: "taste.ai.lastStarted") as? Double
        policy = .init(starts: defaults.array(forKey: "taste.ai.starts") as? [Double] ?? previous.map { [$0] } ?? [])
    }
    func begin() async -> Bool {
        let foreground = await MainActor.run { UIApplication.shared.applicationState == .active }
        let now = Date().timeIntervalSince1970
        guard policy.begin(now: now, foreground: foreground, lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled) else { return false }
        defaults.set(policy.starts, forKey: "taste.ai.starts")
        defaults.removeObject(forKey: "taste.ai.lastStarted")
        return true
    }
    func finish() { policy.finish() }
    func cached(_ key: String, snapshot: TasteSnapshot) -> TasteReport? {
        guard var value = reports[key] else { return nil }
        value.digest = snapshot.digest
        return value.isValid(for: snapshot) ? value : nil
    }
    func save(_ report: TasteReport, key: String) {
        guard report.generatedByAI else { return }
        if reports.count >= 16, let first = reports.keys.sorted().first { reports.removeValue(forKey: first) }
        reports[key] = report
    }
    static func key(_ snapshot: TasteSnapshot, control: TasteControl, language: String) -> String {
        // Identity used only for local cache lookup; never passed to the model.
        let tags = snapshot.tags.sorted { $0.id < $1.id }.map {
            [$0.id, String($0.confirmed), String($0.hidden), String($0.general), String($0.searches), String($0.discovery), String($0.lift ?? 0), $0.works.map(\.key).sorted().joined(separator: ",")].joined(separator: "|")
        }
        let parts = [control.epoch, language, String(snapshot.saves), String(snapshot.previousSaves ?? -1), String(snapshot.period?.start.timeIntervalSince1970 ?? -1), String(snapshot.period?.end.timeIntervalSince1970 ?? -1)] + tags + snapshot.previousTagCounts.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }
        return tasteDigest(Data(parts.joined(separator: "\n").utf8))
    }
    static func watchRuntime() async throws {
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(500))
            let active = await MainActor.run { UIApplication.shared.applicationState == .active }
            guard active, !ProcessInfo.processInfo.isLowPowerModeEnabled else { throw CancellationError() }
        }
        throw CancellationError()
    }
}
