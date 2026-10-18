#if DEBUG
import Foundation

enum ChallengeUITestSupport {
    static func seed(_ booru: BooruStore) throws {
        let store = ChallengeStore(booru)
        for timed in [false, true] {
            var game = ChallengeDefinition.croquis()
            game.id = timed ? "ui-timer" : "ui-count"
            game.helpPages = [.init(id: "tips", title: "Sketch Tips", body: "Choose clear shapes and take your time.")]
            game.title = timed ? "Timer Fixture" : "Count Fixture"
            game.reels[0].options = [.init(text: "Scenery", tags: ["scenery"])]
            game.reels[1].options = [.init(text: "Outline")]
            game.goal.mode = timed ? .time : .count
            game.goal.time = .init(minimum: 2, maximum: 2)
            game.goal.count = .init(minimum: 1, maximum: 1)
            game.target = 1
            try store.save(game)
            var session = ChallengeSession(definition: game)
            session.spinSpeed = ProcessInfo.processInfo.arguments.contains("--challenge-motion-test") ? "normal" : "instant"
            _ = try store.commit(session, expected: 0)
        }
        let server = BooruServer.presets[0]
        let folder = try booru.saveFolder(id: "challenge-fixture", name: "Sketch References")
        try booru.saveFavorite(BooruFixtureSource.post(101, server: server), folderID: folder)
    }
}
#endif
