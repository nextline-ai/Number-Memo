import Foundation
import GRDB
import Observation

struct ChallengeStore {
    let database: DatabaseQueue
    init(_ booru: BooruStore) { database = booru.database }
    static func migrate(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE challenges (id TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL);
            CREATE TABLE challenge_sessions (id TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL);
            """)
    }
    func definitions() throws -> [ChallengeDefinition] {
        try database.read { db in
            try Data.fetchAll(db, sql: "SELECT payload FROM challenges ORDER BY rowid").map { try JSONDecoder().decode(ChallengeDefinition.self, from: $0) }
        }
    }
    func example() throws -> ChallengeDefinition {
        try database.write { db in
            if let data = try Data.fetchOne(db, sql: "SELECT payload FROM challenges WHERE id = ?", arguments: [ChallengeDefinition.exampleID]) {
                return try JSONDecoder().decode(ChallengeDefinition.self, from: data)
            }
            var game = ChallengeDefinition.croquis(); game.id = ChallengeDefinition.exampleID
            try Self.write(game, db: db)
            return game
        }
    }
    func sessionIDs() throws -> Set<String> {
        try database.read { Set(try String.fetchAll($0, sql: "SELECT id FROM challenge_sessions")) }
    }
    func save(_ game: ChallengeDefinition) throws {
        try game.validate()
        try database.write { db in try Self.write(game, db: db) }
    }
    private static func write(_ game: ChallengeDefinition, db: Database) throws {
        let data = try JSONEncoder().encode(game)
        guard data.count <= ChallengeBackup.maximumBytes else { throw ChallengeError.unsupported }
        try db.execute(sql: "INSERT INTO challenges (id, payload) VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET payload = excluded.payload", arguments: [game.id, data])
    }
    func delete(_ id: String) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM challenges WHERE id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM challenge_sessions WHERE id = ?", arguments: [id])
        }
    }
    func restore(_ backup: ChallengeBackup, replace: Bool) throws {
        try backup.validate()
        try database.write { db in
            for var game in backup.games {
                if !replace, try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM challenges WHERE id = ?)", arguments: [game.id]) == true {
                    game.id = UUID().uuidString
                    let suffix = " " + L10n.text("Copy")
                    game.title = String(game.title.prefix(200 - suffix.count)) + suffix
                }
                try game.validate(); try Self.write(game, db: db)
            }
        }
    }
    func session(_ game: ChallengeDefinition) throws -> ChallengeSession {
        try database.read { db in
            guard let data = try Data.fetchOne(db, sql: "SELECT payload FROM challenge_sessions WHERE id = ?", arguments: [game.id]) else { return ChallengeSession(definition: game) }
            let session = try JSONDecoder().decode(ChallengeSession.self, from: data)
            try session.definition.validate()
            return session
        }
    }
    func hasSession(_ id: String) -> Bool {
        (try? database.read { try Bool.fetchOne($0, sql: "SELECT EXISTS(SELECT 1 FROM challenge_sessions WHERE id = ?)", arguments: [id]) }) ?? false
    }
    /// Optimistic revision prevents another window from awarding the same mission twice.
    func commit(_ session: ChallengeSession, expected: Int) throws -> ChallengeSession {
        try database.write { db in
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM challenges WHERE id = ?)", arguments: [session.definition.id]) == true else { throw ChallengeError.stale }
            let existing = try Data.fetchOne(db, sql: "SELECT payload FROM challenge_sessions WHERE id = ?", arguments: [session.definition.id])
            let revision = try existing.map { try JSONDecoder().decode(ChallengeSession.self, from: $0).revision } ?? 0
            guard revision == expected else { throw ChallengeError.stale }
            var next = session; next.revision = expected + 1
            try db.execute(sql: "INSERT INTO challenge_sessions (id, payload) VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET payload = excluded.payload", arguments: [next.definition.id, try JSONEncoder().encode(next)])
            return next
        }
    }
}

@MainActor @Observable
final class ChallengeSessionController: Identifiable {
    let id = UUID()
    private(set) var session: ChallengeSession
    var error: String?
    private(set) var stoppedReels = 0
    private(set) var unavailable = false
    private let store: ChallengeStore?
    private let engine: ChallengeEngine
    private let now: () -> Date
    private let latestDefinition: ChallengeDefinition
    init(game: ChallengeDefinition, store: ChallengeStore? = nil, engine: ChallengeEngine = .init(), now: @escaping () -> Date = Date.init) throws {
        try game.validate()
        self.store = store; self.engine = engine; self.now = now; latestDefinition = game
        session = try store?.session(game) ?? .init(definition: game)
        var restored = session; engine.reconcile(&restored, now: now(), restore: true)
        if restored != session { try persist(restored) }
    }
    private func persist(_ next: ChallengeSession) throws {
        session = try store?.commit(next, expected: session.revision) ?? next
    }
    private func change(_ action: (inout ChallengeSession) throws -> Void) {
        guard !unavailable else { return }
        do {
            var next = session; try action(&next)
            if next != session { try persist(next) }
        } catch {
            if case ChallengeError.stale = error { unavailable = true }
            self.error = error.localizedDescription
        }
    }
    func draw() { guard session.phase == .idle else { return }; stoppedReels = 0; change { try engine.draw(&$0) } }
    func stopReel(_ count: Int) { stoppedReels = min(3, count) }
    func reveal() { stoppedReels = 3; change { if $0.phase == .spinning { $0.phase = .active } } }
    func tick() {
        // Running seconds are derived in the UI; only phase transitions need disk writes.
        guard session.phase == .active, let deadline = session.deadline, deadline <= now() else { return }
        change { engine.reconcile(&$0, now: now()) }
    }
    func seconds(at date: Date) -> Int { session.deadline.map { max(0, Int(ceil($0.timeIntervalSince(date)))) } ?? session.remaining }
    func toggleTimer() {
        change { value in
            engine.reconcile(&value, now: now())
            guard value.phase == .active, value.mission?.kind == .time else { return }
            if value.deadline != nil { value.deadline = nil }
            else { value.deadline = now().addingTimeInterval(Double(value.remaining)) }
        }
    }
    func resetTimer() {
        change { value in
            guard [.active, .ready].contains(value.phase), let mission = value.mission, mission.kind == .time else { return }
            value.remaining = mission.goal; value.deadline = nil; value.phase = .active
        }
    }
    func adjust(_ amount: Int) {
        change { value in
            guard [.active, .ready].contains(value.phase), let mission = value.mission, mission.kind == .count else { return }
            value.count = min(mission.goal, max(0, value.count + amount))
            value.phase = value.count == mission.goal ? .ready : .active
        }
    }
    func complete() { change { engine.complete(&$0, now: now()) } }
    func skip() {
        change { value in
            guard [.active, .ready].contains(value.phase) else { return }
            value.phase = .idle; value.mission = nil; value.deadline = nil; value.selectedPost = nil; value.count = 0; value.remaining = 0
        }
    }
    func restart() {
        change { value in
            let current = try store?.definitions().first { $0.id == latestDefinition.id } ?? latestDefinition
            var next = ChallengeSession(definition: current)
            next.revision = value.revision; next.sourceKind = value.sourceKind; next.serverIDs = value.serverIDs
            next.folderID = value.folderID; next.spinSpeed = value.spinSpeed
            value = next
        }
    }
    func select(_ post: BooruPost?) { change { $0.selectedPost = post } }
    func source(kind: String, servers: [String], folder: String?) {
        change { $0.sourceKind = kind; $0.serverIDs = servers; $0.folderID = folder; $0.selectedPost = nil }
    }
    func speed(_ value: String) { change { $0.spinSpeed = value } }
}
