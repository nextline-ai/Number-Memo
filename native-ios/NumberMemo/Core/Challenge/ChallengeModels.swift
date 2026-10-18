import Foundation

struct ChallengeOption: Codable, Equatable, Identifiable, Sendable {
    var id = UUID().uuidString
    var text: String
    var tags: [String] = []
    var group = ""
    var enabled = true
    var weight = 1
}

struct ChallengeGroup: Codable, Equatable, Identifiable, Sendable {
    var id = UUID().uuidString
    var title: String
    var options: [ChallengeOption]
    var filter = ""
    var eligible: [ChallengeOption] { options.filter { $0.enabled && (filter.isEmpty || $0.group == filter) } }
}

struct ChallengeRange: Codable, Equatable, Sendable {
    var minimum: Int
    var maximum: Int
    var step: Int = 1
    func validate(limit: Int) -> Bool {
        minimum > 0 && maximum >= minimum && maximum <= limit && step > 0 && step <= limit && (maximum - minimum) % step == 0
    }
}

struct ChallengeGoalRule: Codable, Equatable, Sendable {
    enum Mode: String, Codable, CaseIterable, Sendable { case time, count, mixed }
    var mode: Mode = .time
    var time = ChallengeRange(minimum: 30, maximum: 120, step: 30)
    var count = ChallengeRange(minimum: 1, maximum: 3)
    var timeWeight = 50
    var countWeight = 50
}

struct ChallengeScoreBand: Codable, Equatable, Identifiable, Sendable {
    var id = UUID().uuidString
    var through: Int
    var minimum: Int
    var maximum: Int
}

struct ChallengeEnding: Codable, Equatable, Identifiable, Sendable {
    var id = UUID().uuidString
    var title: String
    var detail: String
    var badge: String
    var color: String = "purple"
    var weight: Int = 1
    static let colors = ["purple", "pink", "green", "orange", "blue"]
}

struct ChallengeHelpPage: Codable, Equatable, Identifiable, Sendable {
    var id = UUID().uuidString
    var title: String
    var body: String
}

struct ChallengeDefinition: Codable, Equatable, Identifiable, Sendable {
    var id = UUID().uuidString
    var title: String
    var detail = ""
    var helpPages: [ChallengeHelpPage]? = nil
    var reels: [ChallengeGroup]
    var groups: [ChallengeGroup] = []
    var template = "{reel1} · {reel2} · {goal}"
    var goal = ChallengeGoalRule()
    var target = 100
    var bands: [ChallengeScoreBand] = [
        .init(through: 40, minimum: 12, maximum: 20),
        .init(through: 80, minimum: 6, maximum: 11),
        .init(through: 100, minimum: 1, maximum: 5)
    ]
    var multiplier = 1.0
    var endings: [ChallengeEnding]
    var fixedEndingID: String?
    var variables: [String] { ["reel1", "reel2", "goal"] + groups.indices.map { "extra\($0 + 1)" } }

    static let exampleID = "builtin.croquis.v1"
    var instructionPages: [ChallengeHelpPage] {
        var pages: [ChallengeHelpPage] = []
        if !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            pages.append(.init(id: "overview", title: L10n.text("How to Play"), body: detail))
        }
        pages += helpPages ?? []
        if pages.isEmpty { pages = [.init(id: "overview", title: L10n.text("How to Play"), body: L10n.text("Draw a mission, complete its goal, and collect points until the final result."))] }
        return pages
    }

    func validate() throws {
        func require(_ value: Bool, _ field: String) throws { if !value { throw ChallengeError.invalid(field) } }
        func validText(_ text: String, max: Int = 4000) -> Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.count <= max }
        try require(validText(id, max: 128) && validText(title, max: 200) && detail.count <= 4000, "Challenge Details")
        try require(reels.count == 2 && groups.count <= 12, "Draw Options")
        let help = helpPages ?? []
        try require(help.count <= 12 && Set(help.map(\.id)).count == help.count, "Help Tabs")
        for page in help {
            try require(page.id != "overview" && validText(page.id, max: 128) && validText(page.title, max: 200) && validText(page.body, max: 16000), "Help Tabs")
        }
        let all = reels + groups
        try require(Set(all.map(\.id)).count == all.count, "Draw Options")
        for group in all {
            try require(validText(group.id, max: 128) && validText(group.title, max: 200) && group.filter.count <= 200, "Draw Options")
            try require(!group.options.isEmpty && group.options.count <= 1000 && !group.eligible.isEmpty, group.title)
            try require(Set(group.options.map(\.id)).count == group.options.count, group.title)
            for option in group.options {
                try require(validText(option.id, max: 128) && validText(option.text) && option.group.count <= 200 && (1...10000).contains(option.weight), group.title)
                // Atomic tags only: filters and server settings remain user controlled.
                try require(option.tags.count <= 20 && option.tags.allSatisfy { tag in
                    validText(tag, max: 128) && !tag.contains(where: { $0.isWhitespace }) && !tag.contains(":") && !tag.hasPrefix("-") && !tag.hasPrefix("~") && !tag.contains("{") && !tag.contains("}")
                }, "Search Tags")
            }
        }
        try require(goal.time.validate(limit: 86400) && goal.count.validate(limit: 10000), "Goal Range")
        try require((1...10000).contains(goal.timeWeight) && (1...10000).contains(goal.countWeight), "Goal Probability")
        try require((1...100000).contains(target) && [0.5, 1, 1.5, 2].contains(multiplier), "Scoring")
        try require(!bands.isEmpty && bands.count <= 100 && Set(bands.map(\.id)).count == bands.count, "Scoring")
        var previous = -1
        for band in bands {
            try require(validText(band.id, max: 128) && band.through > previous && band.through <= 100000 && band.minimum > 0 && band.maximum >= band.minimum && band.maximum <= 100000, "Scoring")
            previous = band.through
        }
        try require(previous >= target - 1, "Scoring")
        try require(!endings.isEmpty && endings.count <= 100 && Set(endings.map(\.id)).count == endings.count, "Endings")
        for ending in endings {
            try require(validText(ending.id, max: 128) && validText(ending.title, max: 200) && ending.detail.count <= 4000 && ending.badge.count <= 40 && ChallengeEnding.colors.contains(ending.color) && (1...10000).contains(ending.weight), "Endings")
        }
        try require(fixedEndingID == nil || endings.contains { $0.id == fixedEndingID }, "Endings")
        try require(validText(template), "Mission Text")
        let pattern = try NSRegularExpression(pattern: #"\{([^{}]*)\}"#)
        let ns = template as NSString
        let matches = pattern.matches(in: template, range: NSRange(location: 0, length: ns.length))
        try require(matches.allSatisfy { variables.contains(ns.substring(with: $0.range(at: 1))) }, "Mission Variables")
        let remainder = pattern.stringByReplacingMatches(in: template, range: NSRange(location: 0, length: ns.length), withTemplate: "")
        try require(!remainder.contains("{") && !remainder.contains("}"), "Mission Variables")
    }

    static func croquis() -> Self {
        func option(_ key: String, _ tag: String) -> ChallengeOption { .init(text: L10n.text(key), tags: [tag]) }
        return .init(title: L10n.text("Croquis Challenge"), detail: L10n.text("Draw a subject, a drawing method, and a time limit. Choose a reference image, then start the timer when you are ready. Sketch until time is up and tap Complete Mission to earn points. Reach 100 points to finish your session. You can pause or skip a mission at any time."), reels: [
            .init(title: L10n.text("Subject"), options: [option("Person", "solo"), option("Animal", "animal"), option("Scenery", "scenery"), option("Object", "still_life")]),
            .init(title: L10n.text("Drawing Method"), options: ["Outline", "Large Shapes", "Light and Shadow"].map { .init(text: L10n.text($0)) })
        ], template: L10n.text("Sketch {reel1} using {reel2}. Goal: {goal}."), endings: [
            .init(title: L10n.text("Great Practice"), detail: L10n.text("You completed your sketch session. Take a look at your progress."), badge: "★", color: "purple", weight: 10),
            .init(title: L10n.text("Fresh Perspective"), detail: L10n.text("Every sketch helps you see new shapes."), badge: "✦", color: "purple", weight: 45),
            .init(title: L10n.text("Creative Momentum"), detail: L10n.text("Keep your sketches and enjoy what you learned."), badge: "✧", color: "purple", weight: 45)
        ])
    }
}

enum ChallengeError: LocalizedError {
    case invalid(String), unsupported, stale
    var errorDescription: String? {
        switch self {
        case .invalid(let field): return L10n.text("Check this field: %@", L10n.text(field))
        case .unsupported: return L10n.text("This challenge backup is too large or uses an unsupported format.")
        case .stale: return L10n.text("The challenge changed. Reopen it to continue.")
        }
    }
}

struct ChallengeBackup: Codable, Sendable {
    var format = "number-memo-challenges"
    var schemaVersion = 1
    var games: [ChallengeDefinition]
    static let maximumBytes = 10 * 1024 * 1024
    func validate() throws {
        guard format == "number-memo-challenges", schemaVersion == 1 else { throw ChallengeError.unsupported }
        guard games.count <= 200, Set(games.map(\.id)).count == games.count else { throw ChallengeError.invalid("Challenges") }
        for game in games { try game.validate() }
    }
    func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumBytes else { throw ChallengeError.unsupported }
        return data
    }
    static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw ChallengeError.unsupported }
        let value = try JSONDecoder().decode(Self.self, from: data); try value.validate(); return value
    }
    static func read(_ url: URL) throws -> Self {
        let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? maximumBytes + 1) <= maximumBytes else { throw ChallengeError.unsupported }
        return try decode(Data(contentsOf: url))
    }
}
