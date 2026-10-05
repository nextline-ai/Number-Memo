#if DEBUG
import SwiftUI

enum ContentUITestSupport {
    static var unitTestsEnabled: Bool { ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil || NSClassFromString("XCTestCase") != nil }
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("--native-content-ui-test") || BooruUITestSupport.enabled || BooruUITestSupport.liveEnabled }
    static let source = FixtureContentSource()
    static var libraryJumpTest: Bool { enabled && ProcessInfo.processInfo.arguments.contains("--library-jump-test") }
    @MainActor static func environment() -> AppEnvironment {
        UserDefaults(suiteName: "com.numbermemo.booru-ui-tests")!.removePersistentDomain(forName: "com.numbermemo.booru-ui-tests")
        var env = AppEnvironment.preview()
        if ProcessInfo.processInfo.arguments.contains("--booru-restored-badge-test") {
            env = AppEnvironment(database: env.database, browserPreferences: UserDefaults(suiteName: "com.numbermemo.booru-ui-tests")!, booru: try! BooruUITestSupport.restoredBadgeStore())
        }
        env.isOnboardingCompleted = !ProcessInfo.processInfo.arguments.contains("--onboarding-test")
        if !ProcessInfo.processInfo.arguments.contains("--onboarding-test") && !ProcessInfo.processInfo.arguments.contains("--comics-setup-test") {
            _ = env.verifySite(input: "hitomi.la")
        }
        if !BooruUITestSupport.enabled && !BooruUITestSupport.liveEnabled { env.mode = .hitomi }
        if BooruUITestSupport.enabled {
            env.mode = .booru
            if !ProcessInfo.processInfo.arguments.contains("--onboarding-test") {
                for server in BooruServer.presets { try! env.booru.saveServer(server) }
                if !ProcessInfo.processInfo.arguments.contains("--booru-restored-badge-test") { try! env.booru.select(BooruServer.presets[0]) }
            }
        }
        if BooruUITestSupport.liveEnabled {
            env.mode = .booru
            for server in BooruServer.presets { try! env.booru.saveServer(server) }
            try! env.booru.select(BooruServer.presets[2])
            let args = ProcessInfo.processInfo.arguments
            if let index = args.firstIndex(of: "--booru-legacy-address"), args.indices.contains(index + 1),
               let url = try? BooruServer.validatedURL(args[index + 1]) {
                let server = BooruServer(id: "legacy-live", name: "Legacy", baseURL: url, engine: .oldGelbooru)
                try! env.booru.saveServer(server); try! env.booru.select(server)
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--browser-fallback-test") { env.useEmbeddedBrowser = true }
        if libraryJumpTest {
            let folder = try! env.database.createFolder(name: "이동 테스트")
            for index in 0..<120 {
                let month = 10 - index / 30
                let day = 30 - index % 30
                _ = try! env.database.upsertWork(galleryId: Int64(910000001 + index), folderId: folder.id,
                    title: "샘플 작품 \(index + 1)", bookmarkedAt: String(format: "2026-%02d-%02dT12:00:00Z", month, day))
            }
        }
        return env
    }
    static let defaults: UserDefaults = {
        let name = "com.deaum.numbermemo.reader-ui-tests"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        defaults.set(!ProcessInfo.processInfo.arguments.contains("--reader-help-test"), forKey: "reader.helpHidden")
        if ProcessInfo.processInfo.arguments.contains("--reader-auto-test") { defaults.set(2.0, forKey: "reader.autoSeconds") }
        return defaults
    }()
}

/// Synthetic pages keep device UI automation independent of private library data and the network.
actor FixtureContentSource: ContentProviding {
    private var shouldFail: Bool
    private(set) var imageRequests = 0
    init() { shouldFail = ProcessInfo.processInfo.arguments.contains("--native-content-initial-error") }

    func gallery(_ id: Int64) async throws -> NativeGallery {
        NativeGallery(id: id, title: "네이티브 읽기 테스트", artists: ["Number Memo"], language: "english", type: "테스트",
                      tags: ["female:sample", "tag:example"], pages: (1...3).map { index in
                          GalleryPage(hash: String(repeating: "a", count: 63) + String(index), name: "\(index).png", width: 800, height: 1200, hasAVIF: false)
                      })
    }

    func list(_ query: GalleryQuery, offset: Int, count: Int) async throws -> GalleryBatch {
        if shouldFail { shouldFail = false; throw URLError(.notConnectedToInternet) }
        let ids: [Int64] = ProcessInfo.processInfo.arguments.contains("--native-content-long-feed")
            ? (900000001...900000024).map { Int64($0) } : [900000001]
        return GalleryBatch(ids: offset == 0 ? ids : [], hasMore: false)
    }

    func suggestions(for token: String) async throws -> [TagSuggestion] {
        try await Task.sleep(for: .milliseconds(100))
        return token == "female:sa" ? [TagSuggestion(namespace: "female", name: "sample tag", count: 42)] : []
    }

    func image(_ page: GalleryPage, galleryID: Int64, thumbnail: Bool) async throws -> Data {
        imageRequests += 1
        if ProcessInfo.processInfo.arguments.contains("--native-content-image-error") { throw URLError(.timedOut) }
        return await MainActor.run {
            let short = ProcessInfo.processInfo.arguments.contains("--reader-short-page-test")
            let size = short ? CGSize(width: 1200, height: 400) : CGSize(width: 800, height: 1200)
            return UIGraphicsImageRenderer(size: size).image { context in
                UIColor(red: 0.9, green: 0.94, blue: 1, alpha: 1).setFill()
                context.fill(CGRect(origin: .zero, size: size))
                let text = ProcessInfo.processInfo.arguments.contains("--reader-japanese-test")
                    ? "今日はとてもいい天気です。\n\n一緒に公園に行きましょう。\n\n明日も楽しい一日になりますように。"
                    : "Number Memo\n\nPage \(page.name.prefix(1))\n\nNative Reader\n\nDouble tap to zoom"
                (text as NSString).draw(in: CGRect(x: 60, y: 120, width: 680, height: 920), withAttributes: [
                    .font: UIFont.systemFont(ofSize: 48, weight: .semibold), .foregroundColor: UIColor.black
                ])
            }.pngData()!
        }
    }
}
#endif
