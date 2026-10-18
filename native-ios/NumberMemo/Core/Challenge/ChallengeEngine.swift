import Foundation

struct ChallengeMission: Codable, Equatable, Sendable {
    var id = UUID().uuidString
    var selections: [ChallengeOption]
    var kind: ChallengeGoalRule.Mode
    var goal: Int
    var text: String
    var tags: [String] { Array(Set(selections.flatMap(\.tags))).sorted() }
    var goalText: String { Self.goalText(kind: kind, value: goal) }
    static func goalText(kind: ChallengeGoalRule.Mode, value: Int) -> String {
        let key = kind == .time ? (value == 1 ? "%@ second" : "%@ seconds") : (value == 1 ? "%@ repetition" : "%@ repetitions")
        return L10n.text(key, String(value))
    }
}

struct ChallengeSession: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable { case idle, spinning, active, ready, ended }
    var definition: ChallengeDefinition
    var phase: Phase = .idle
    var score = 0
    var mission: ChallengeMission?
    var remaining = 0
    var count = 0
    var deadline: Date?
    var ending: ChallengeEnding?
    var revision = 0
    // Local only. Never serialized as part of a ChallengeBackup or cloud row.
    var sourceKind = "servers"
    var serverIDs: [String] = []
    var folderID: String?
    var selectedPost: BooruPost?
    var spinSpeed = "normal"
    var canSearchImages: Bool { mission != nil && (phase == .active || phase == .ready) }
    var progress: Double { Double(score) / Double(definition.target) }
}

/// The only randomness and wall clock dependencies are explicit inputs.
struct ChallengeEngine {
    var random: (Range<Int>) -> Int = { Int.random(in: $0) }
    private func choose<T>(_ values: [T], weight: (T) -> Int) -> T {
        let total = values.reduce(0) { $0 + weight($1) }
        var ticket = random(0..<total)
        for value in values { ticket -= weight(value); if ticket < 0 { return value } }
        return values[values.count - 1]
    }
    private func number(_ range: ChallengeRange) -> Int {
        range.minimum + random(0..<((range.maximum - range.minimum) / range.step + 1)) * range.step
    }
    func draw(_ session: inout ChallengeSession) throws {
        guard session.phase == .idle else { return }
        try session.definition.validate()
        let definition = session.definition
        let choices = (definition.reels + definition.groups).map { choose($0.eligible, weight: { $0.weight }) }
        let rule = definition.goal
        let kind: ChallengeGoalRule.Mode = rule.mode == .mixed
            ? (random(0..<(rule.timeWeight + rule.countWeight)) < rule.timeWeight ? .time : .count) : rule.mode
        let goal = number(kind == .time ? rule.time : rule.count)
        var variables = ["reel1": choices[0].text, "reel2": choices[1].text, "goal": ChallengeMission.goalText(kind: kind, value: goal)]
        for (index, option) in choices.dropFirst(2).enumerated() { variables["extra\(index + 1)"] = option.text }
        // Replace tokens in the template once: option text is never interpreted as a template.
        let regex = try NSRegularExpression(pattern: #"\{([^{}]*)\}"#)
        let text = NSMutableString(string: definition.template)
        for match in regex.matches(in: definition.template, range: NSRange(location: 0, length: text.length)).reversed() {
            let key = (definition.template as NSString).substring(with: match.range(at: 1))
            text.replaceCharacters(in: match.range, with: variables[key] ?? "")
        }
        session.mission = .init(selections: choices, kind: kind, goal: goal, text: text as String)
        session.phase = .spinning; session.remaining = kind == .time ? goal : 0
        session.count = 0; session.deadline = nil; session.selectedPost = nil
    }
    func reconcile(_ session: inout ChallengeSession, now: Date, restore: Bool = false) {
        if restore && session.phase == .spinning { session.phase = .active }
        guard session.phase == .active, let mission = session.mission else { return }
        if mission.kind == .time {
            if let deadline = session.deadline { session.remaining = max(0, Int(ceil(deadline.timeIntervalSince(now)))) }
            if session.remaining == 0 { session.deadline = nil; session.phase = .ready }
        } else if session.count >= mission.goal { session.phase = .ready }
    }
    func complete(_ session: inout ChallengeSession, now: Date) {
        reconcile(&session, now: now)
        guard session.phase == .ready else { return }
        let definition = session.definition
        let band = definition.bands.first { session.score <= $0.through }!
        let points = max(1, Int((Double(random(band.minimum..<(band.maximum + 1))) * definition.multiplier).rounded()))
        session.score = min(definition.target, session.score + points)
        session.deadline = nil; session.remaining = 0; session.count = 0; session.mission = nil; session.selectedPost = nil
        if session.score == definition.target {
            session.ending = definition.endings.first { $0.id == definition.fixedEndingID } ?? choose(definition.endings, weight: { $0.weight })
            session.phase = .ended
        } else { session.phase = .idle }
    }
}
