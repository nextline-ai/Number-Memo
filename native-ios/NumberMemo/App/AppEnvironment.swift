import Foundation
import SwiftUI

public enum AppTheme: String, CaseIterable, Identifiable, Sendable {
    case dark = "dark"
    case light = "light"
    case system = "system"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .dark: return L10n.text("Dark Mode")
        case .light: return L10n.text("Light Mode")
        case .system: return L10n.text("System Default")
        }
    }

    public var colorScheme: ColorScheme? {
        switch self {
        case .dark: return .dark
        case .light: return .light
        case .system: return nil
        }
    }
}

@Observable
public final class AppEnvironment: @unchecked Sendable {
    public let database: AppDatabase
    public let coverQueueActor: CoverQueueActor
    public let coverQueueState: CoverQueueState
    public let violetImporter: VioletImportService
    let booru: BooruStore

    var mode: AppMode {
        didSet { browserPreferences.set(mode.rawValue, forKey: "content_mode") }
    }
    var appLanguage: String {
        didSet {
            browserPreferences.set(appLanguage, forKey: "app.language")
            L10n.appLanguage = appLanguage
        }
    }

    private var hitomiTheme: AppTheme
    private var booruTheme: AppTheme
    private var hitomiColumns: Int
    private var booruColumns: Int

    public var appTheme: AppTheme {
        get { mode == .hitomi ? hitomiTheme : booruTheme }
        set {
            if mode == .hitomi { hitomiTheme = newValue } else { booruTheme = newValue }
            browserPreferences.set(newValue.rawValue, forKey: mode == .hitomi ? "app_theme" : "booru.app_theme")
        }
    }

    public var gridColumns: Int {
        get { mode == .hitomi ? hitomiColumns : booruColumns }
        set {
            let value = min(5, max(1, newValue))
            if mode == .hitomi { hitomiColumns = value } else { booruColumns = value }
            browserPreferences.set(value, forKey: mode == .hitomi ? "grid_columns" : "booru.grid_columns")
        }
    }

    var defaultTags: String {
        didSet { browserPreferences.set(defaultTags, forKey: "hitomi.defaultTags") }
    }
    var defaultExcludedTags: String {
        didSet { browserPreferences.set(defaultExcludedTags, forKey: "hitomi.defaultExcludedTags") }
    }

    @MainActor var sync: LibraryCloudSync { syncStorage ?? makeSync() }
    @ObservationIgnored private var syncStorage: LibraryCloudSync?
    @MainActor private func makeSync() -> LibraryCloudSync {
        let value = LibraryCloudSync(defaults: browserPreferences); syncStorage = value; return value
    }
    func reloadSyncedPreferences() {
        appLanguage = browserPreferences.string(forKey: "app.language") ?? "system"
        hitomiTheme = AppTheme(rawValue: browserPreferences.string(forKey: "app_theme") ?? "") ?? .dark
        booruTheme = AppTheme(rawValue: browserPreferences.string(forKey: "booru.app_theme") ?? "") ?? .dark
        defaultTags = browserPreferences.string(forKey: "hitomi.defaultTags") ?? ""
        defaultExcludedTags = browserPreferences.string(forKey: "hitomi.defaultExcludedTags") ?? ""
    }
    private let browserPreferences: UserDefaults

    public var useEmbeddedBrowser: Bool {
        didSet {
            browserPreferences.set(useEmbeddedBrowser, forKey: "use_embedded_browser")
        }
    }

    public var isOnboardingCompleted: Bool {
        didSet {
            browserPreferences.set(isOnboardingCompleted, forKey: "onboarding_completed")
        }
    }

    public var isSiteVerified: Bool {
        didSet {
            browserPreferences.set(isSiteVerified, forKey: "site_verified")
        }
    }

    public convenience init(database: AppDatabase, browserPreferences: UserDefaults = .standard) {
        self.init(database: database, browserPreferences: browserPreferences, booru: try! BooruStore())
    }

    init(database: AppDatabase, browserPreferences: UserDefaults = .standard, booru: BooruStore) {
        self.browserPreferences = browserPreferences
        self.appLanguage = browserPreferences.string(forKey: "app.language") ?? "system"
        L10n.appLanguage = browserPreferences.string(forKey: "app.language") ?? "system"
        self.booru = booru
        self.mode = AppMode(rawValue: browserPreferences.string(forKey: "content_mode") ?? "") ?? .booru
        self.database = database
        self.coverQueueActor = CoverQueueActor(database: database)
        self.coverQueueState = CoverQueueState()
        self.violetImporter = VioletImportService(appDb: database)

        self.hitomiTheme = AppTheme(rawValue: browserPreferences.string(forKey: "app_theme") ?? "") ?? .dark
        self.booruTheme = AppTheme(rawValue: browserPreferences.string(forKey: "booru.app_theme") ?? "") ?? .dark
        let hitomiColumns = browserPreferences.integer(forKey: "grid_columns")
        let booruColumns = browserPreferences.integer(forKey: "booru.grid_columns")
        self.hitomiColumns = hitomiColumns > 0 ? min(5, hitomiColumns) : 2
        self.booruColumns = booruColumns > 0 ? min(5, booruColumns) : 3
        self.defaultTags = browserPreferences.string(forKey: "hitomi.defaultTags") ?? ""
        self.defaultExcludedTags = browserPreferences.string(forKey: "hitomi.defaultExcludedTags") ?? ""

        // New opt-in fallback; the old preference selected native UI versus external Safari.
        self.useEmbeddedBrowser = browserPreferences.bool(forKey: "use_embedded_browser")

        self.isOnboardingCompleted = browserPreferences.bool(forKey: "onboarding_completed")
        self.isSiteVerified = browserPreferences.bool(forKey: "site_verified")
    }

    static func supportsComicsAddress(_ input: String) -> Bool {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URLComponents(string: value.contains("://") ? value : "https://" + value) else { return false }
        return url.scheme?.lowercased() == "https" && url.host?.lowercased() == "hitomi.la"
            && (url.path.isEmpty || url.path == "/") && url.query == nil && url.fragment == nil
            && url.user == nil && url.password == nil && (url.port == nil || url.port == 443)
    }

    @discardableResult
    public func verifySite(input: String) -> Bool {
        let cleaned = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let isValid = cleaned == "hitomi" || Self.supportsComicsAddress(input)
        if isValid { self.isSiteVerified = true }
        return isValid
    }

    public static func standard() -> AppEnvironment {
        do {
            let db = try AppDatabase.open()
            return AppEnvironment(database: db, booru: try BooruStore.open())
        } catch {
            fatalError("Failed to initialize database: \(error)")
        }
    }

    public static func preview() -> AppEnvironment {
        let db = try! AppDatabase.inMemory()
        let defaults = UserDefaults(suiteName: "com.numbermemo.preview-browser")!
        defaults.removePersistentDomain(forName: "com.numbermemo.preview-browser")
        return AppEnvironment(database: db, browserPreferences: defaults)
    }

    public func startCoverQueue() {
        guard isSiteVerified else { return }
        Task {
            await coverQueueActor.start(state: coverQueueState)
        }
    }
}
