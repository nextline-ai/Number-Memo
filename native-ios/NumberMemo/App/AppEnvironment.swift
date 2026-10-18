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

/// A launch page can be requested by the splash warmup and the visible feed at
/// once. Canceling one consumer must not cancel the other's request.
actor LaunchPageCache<Key: Hashable & Sendable, Value: Sendable> {
    private struct Flight {
        let id: UUID
        let task: Task<Value, Error>
        var consumers: Set<UUID>
    }
    private var values: [Key: Value] = [:]
    private var order: [Key] = []
    private var flights: [Key: Flight] = [:]

    func value(for key: Key, load: @escaping @Sendable () async throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        if let value = values[key] { return value }
        let consumer = UUID(), task: Task<Value, Error>
        if var flight = flights[key] {
            flight.consumers.insert(consumer); flights[key] = flight; task = flight.task
        } else {
            let token = UUID()
            task = Task {
                let value = try await load()
                try Task.checkCancellation()
                self.store(value, key: key, token: token)
                return value
            }
            flights[key] = Flight(id: token, task: task, consumers: [consumer])
        }
        return try await withTaskCancellationHandler {
            defer { release(key, consumer: consumer) }
            let value = try await task.value
            try Task.checkCancellation()
            return value
        } onCancel: { Task { await self.release(key, consumer: consumer) } }
    }

    private func store(_ value: Value, key: Key, token: UUID) {
        guard flights[key]?.id == token else { return }
        values[key] = value
        order.removeAll { $0 == key }; order.append(key)
        while order.count > 8 { values.removeValue(forKey: order.removeFirst()) }
    }
    private func release(_ key: Key, consumer: UUID) {
        guard var flight = flights[key], flight.consumers.remove(consumer) != nil else { return }
        if flight.consumers.isEmpty { flights.removeValue(forKey: key); flight.task.cancel() }
        else { flights[key] = flight }
    }
    func consumerCount(for key: Key) -> Int { flights[key]?.consumers.count ?? 0 }
    func invalidate(_ key: Key) {
        values.removeValue(forKey: key); order.removeAll { $0 == key }
        flights.removeValue(forKey: key)?.task.cancel()
    }
}

actor LaunchWorkSlots {
    private struct Waiter { let id: UUID; let priority: TaskPriority; let continuation: CheckedContinuation<Void, Error> }
    private var running = 0
    private var waiting: [Waiter] = []
    func perform<Value: Sendable>(_ operation: @Sendable () async throws -> Value) async throws -> Value {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else if running < 2 { running += 1; continuation.resume() }
                else { waiting.append(Waiter(id: id, priority: Task.currentPriority, continuation: continuation)) }
            }
        } onCancel: { Task { await self.cancel(id) } }
        defer { release() }
        try Task.checkCancellation()
        return try await operation()
    }
    private func cancel(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).continuation.resume(throwing: CancellationError())
    }
    private func release() {
        guard let index = waiting.indices.max(by: { waiting[$0].priority < waiting[$1].priority }) else { running -= 1; return }
        waiting.remove(at: index).continuation.resume()
    }
}

/// Process-local preparation of one list page and its thumbnail pixels. It never
/// advances a feed cursor or downloads reader originals.
@MainActor
final class LaunchFeedWarmup {
    struct MangaKey: Hashable, Sendable { let site: String; let query: GalleryQuery }
    struct BooruKey: Hashable, Sendable { let server: BooruServer; let query: String; let sort: BooruSort }
    private enum Job: Hashable, Sendable { case manga(MangaKey), booru(BooruKey) }
    private enum Prepared: Sendable { case manga(Job, [Int64]), booru(Job, BooruServer, [BooruPost]) }
    private enum Cover: Sendable { case manga(Int64), booru(URL, BooruServer) }
    let manga: any ContentProviding
    let booru: any BooruProviding
    let images: PageImageStore
    let mangaPages = LaunchPageCache<MangaKey, GalleryBatch>()
    let booruPages = LaunchPageCache<BooruKey, BooruBatch>()
    private let thumbnail: @Sendable (URL, BooruServer) async throws -> Void
    private let slots = LaunchWorkSlots()
    private var completed = Set<Job>()
    private var consumed = Set<Job>()
    private var work: Task<Void, Never>?
    private var generation = UUID()

    init(manga: any ContentProviding, booru: any BooruProviding, images: PageImageStore? = nil,
         thumbnail: @escaping @Sendable (URL, BooruServer) async throws -> Void = { url, server in
             _ = try await BooruThumbnailCache.shared.image(url: url, server: server)
         }) {
        self.manga = manga; self.booru = booru
        self.images = images ?? PageImageStore(source: manga)
        self.thumbnail = thumbnail
    }

    func mangaPage(query: GalleryQuery, site: String, initialConsumer: Bool = false) async throws -> GalleryBatch {
        let source = manga, slots = slots
        let key = MangaKey(site: site, query: query)
        if initialConsumer, consumed.contains(.manga(key)) { return try await source.list(query, offset: 0, count: 24) }
        let page = try await mangaPages.value(for: key) {
            try await slots.perform { try await source.list(query, offset: 0, count: 24) }
        }
        try Task.checkCancellation()
        return page
    }
    func booruPage(server: BooruServer, query: String, sort: BooruSort, initialConsumer: Bool = false) async throws -> BooruBatch {
        let source = booru, slots = slots
        let key = BooruKey(server: server, query: query, sort: sort)
        if initialConsumer, consumed.contains(.booru(key)) {
            return try await BooruSortValidation.posts(source: source, server: server, query: query, page: 0, sort: sort)
        }
        let page = try await booruPages.value(for: key) {
            try await slots.perform {
                try await BooruSortValidation.posts(source: source, server: server, query: query, page: 0, sort: sort)
            }
        }
        try Task.checkCancellation()
        return page
    }
    // A canceled UI task can discard a result after its await returns. Consume
    // the handoff only when the feed actually publishes that first page.
    func didPublishManga(query: GalleryQuery, site: String) {
        consumed.insert(.manga(MangaKey(site: site, query: query)))
    }
    func didPublishBooru(server: BooruServer, query: String, sort: BooruSort) {
        consumed.insert(.booru(BooruKey(server: server, query: query, sort: sort)))
    }
    func invalidateManga(query: GalleryQuery, site: String) async {
        let key = MangaKey(site: site, query: query)
        consumed.insert(.manga(key)); completed.insert(.manga(key))
        await mangaPages.invalidate(key)
    }
    func invalidateBooru(server: BooruServer, query: String, sort: BooruSort) async {
        let key = BooruKey(server: server, query: query, sort: sort)
        consumed.insert(.booru(key)); completed.insert(.booru(key))
        await booruPages.invalidate(key)
    }

    func run(mangaQuery: GalleryQuery?, site: String, servers: [BooruServer], preferredMode: AppMode = .manga) async {
        guard !Task.isCancelled else { return }
        let previous = work, token = UUID()
        previous?.cancel(); generation = token
        let task = Task(priority: .utility) { [weak self] in
            // An in-flight shared thumbnail may still serve a visible cell. Its
            // worker retains the slot until it finishes, including after cancel.
            await previous?.value
            guard let self, !Task.isCancelled else { return }
            var jobs = mangaQuery.map { [Job.manga(MangaKey(site: site, query: $0))] } ?? []
            jobs += servers.map { .booru(BooruKey(server: $0, query: "", sort: .latest)) }
            if preferredMode == .booru, mangaQuery != nil, !servers.isEmpty { jobs.swapAt(0, 1) }
            jobs.removeAll { self.completed.contains($0) }
            var prepared: [Prepared] = []
            await withTaskGroup(of: Prepared?.self) { group in
                var iterator = jobs.makeIterator()
                for _ in 0..<2 { if let job = iterator.next() { group.addTask { await self.prepareList(job) } } }
                while let result = await group.next() {
                    if Task.isCancelled { group.cancelAll(); break }
                    if let result { prepared.append(result) }
                    if let job = iterator.next() { group.addTask { await self.prepareList(job) } }
                }
            }
            guard !Task.isCancelled else { return }
            var covers: [Cover] = [], posts: [(BooruPost, BooruServer)] = []
            for page in prepared {
                switch page {
                case .manga(_, let ids): covers += ids.prefix(10).map(Cover.manga)
                case .booru(_, let server, let batch): posts += batch.map { ($0, server) }
                }
            }
            // Twenty previews in total, even with multiple selected servers.
            // Keep the native list page sizes so pagination cannot skip IDs.
            posts.sort { $0.0.postID == $1.0.postID ? $0.0.id < $1.0.id : $0.0.postID > $1.0.postID }
            let booruCovers: [Cover] = posts.prefix(20).compactMap { post, server in
                (post.previewURL ?? post.sampleURL).map { .booru($0, server) }
            }
            covers = preferredMode == .booru ? booruCovers + covers : covers + booruCovers
            await withTaskGroup(of: Void.self) { group in
                var iterator = covers.makeIterator()
                for _ in 0..<2 { if let cover = iterator.next() { group.addTask { await self.prepareCover(cover) } } }
                while await group.next() != nil {
                    if Task.isCancelled { group.cancelAll(); break }
                    if let cover = iterator.next() { group.addTask { await self.prepareCover(cover) } }
                }
            }
            guard !Task.isCancelled else { return }
            for page in prepared {
                switch page { case .manga(let job, _), .booru(let job, _, _): completed.insert(job) }
            }
        }
        work = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        if generation == token { work = nil }
    }

    private func prepareList(_ job: Job) async -> Prepared? {
        do {
            try Task.checkCancellation()
            switch job {
            case .manga(let key):
                let page = try await mangaPage(query: key.query, site: key.site)
                return .manga(job, page.ids)
            case .booru(let key):
                let page = try await booruPage(server: key.server, query: key.query, sort: key.sort)
                return .booru(job, key.server, page.posts)
            }
        } catch { return nil }
    }
    private func prepareCover(_ cover: Cover) async {
        let manga = manga, images = images, thumbnail = thumbnail
        try? await slots.perform {
            switch cover {
            case .manga(let id):
                let gallery = try await manga.gallery(id)
                try Task.checkCancellation()
                if let page = gallery.pages.first { _ = try await images.load(page, galleryID: id, thumbnail: true) }
            case .booru(let url, let server): try await thumbnail(url, server)
            }
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
    let modeSwitchMotion = AppModeSwitchMotion()

    var mode: AppMode {
        didSet { browserPreferences.set(mode.rawValue, forKey: "content_mode") }
    }
    var appLanguage: String {
        didSet {
            browserPreferences.set(appLanguage, forKey: "app.language")
            L10n.appLanguage = appLanguage
        }
    }

    private var mangaTheme: AppTheme
    private var booruTheme: AppTheme
    private var mangaColumns: Int
    private var booruColumns: Int
    private var mangaFolderColumns: Int
    private var booruFolderColumns: Int

    public var appTheme: AppTheme {
        get { mode == .manga ? mangaTheme : booruTheme }
        set {
            if mode == .manga { mangaTheme = newValue } else { booruTheme = newValue }
            browserPreferences.set(newValue.rawValue, forKey: mode == .manga ? "app_theme" : "booru.app_theme")
        }
    }

    func gridColumns(for mode: AppMode) -> Int { mode == .manga ? mangaColumns : booruColumns }

    public var gridColumns: Int {
        get { mode == .manga ? mangaColumns : booruColumns }
        set {
            let value = min(5, max(0, newValue))
            if mode == .manga { mangaColumns = value } else { booruColumns = value }
            browserPreferences.set(value, forKey: mode == .manga ? "grid_columns" : "booru.grid_columns")
        }
    }

    public var folderColumns: Int {
        get { mode == .manga ? mangaFolderColumns : booruFolderColumns }
        set {
            let value = min(5, max(0, newValue))
            if mode == .manga { mangaFolderColumns = value } else { booruFolderColumns = value }
            browserPreferences.set(value, forKey: mode == .manga ? "folder_columns" : "booru.folder_columns")
        }
    }

    var defaultTags: String {
        didSet { browserPreferences.set(defaultTags, forKey: "manga.defaultTags") }
    }
    var defaultExcludedTags: String {
        didSet { browserPreferences.set(defaultExcludedTags, forKey: "manga.defaultExcludedTags") }
    }

    @MainActor var taste: TasteController {
        if let tasteStorage { return tasteStorage }
        let controller = TasteController(library: database, images: booru)
        tasteStorage = controller
        return controller
    }
    @ObservationIgnored private var tasteStorage: TasteController?
    @ObservationIgnored private var coverQueueTask: Task<Void, Never>?
    @ObservationIgnored private var coverQueueGeneration = UUID()
    @ObservationIgnored private var coverQueueActive = true
    @ObservationIgnored private var resumeCoverQueue = false
    @ObservationIgnored private var coverQueueRequested = false

    @MainActor var launchFeeds: LaunchFeedWarmup {
        if let launchFeedsStorage { return launchFeedsStorage }
        let manga: any ContentProviding
        let images: any BooruProviding
        #if DEBUG
        manga = ContentUITestSupport.enabled || ContentUITestSupport.unitTestsEnabled ? ContentUITestSupport.source : MangaContentSource.shared
        images = BooruUITestSupport.enabled || ContentUITestSupport.unitTestsEnabled ? BooruUITestSupport.source : BooruClient.shared
        #else
        manga = MangaContentSource.shared; images = BooruClient.shared
        #endif
        let value = LaunchFeedWarmup(manga: manga, booru: images)
        launchFeedsStorage = value
        return value
    }
    @ObservationIgnored private var launchFeedsStorage: LaunchFeedWarmup?

    var launchMangaQuery: GalleryQuery {
        GalleryQuery(language: L10n.contentLanguage).applyingDefaults(tags: defaultTags, excluded: defaultExcludedTags)
    }

    @MainActor var sync: LibraryCloudSync { syncStorage ?? makeSync() }
    @ObservationIgnored private var syncStorage: LibraryCloudSync?
    @MainActor private func makeSync() -> LibraryCloudSync {
        let value = LibraryCloudSync(defaults: browserPreferences); syncStorage = value; return value
    }
    func reloadSyncedPreferences() {
        // Assign only changed values: materializing absent defaults would upload them
        // as fresh edits and overwrite another device's preferences on the next pass.
        let language = browserPreferences.string(forKey: "app.language") ?? "system"
        if appLanguage != language { appLanguage = language }
        let comicsTheme = AppTheme(rawValue: browserPreferences.string(forKey: "app_theme") ?? "") ?? .dark
        if mangaTheme != comicsTheme { mangaTheme = comicsTheme }
        let imageTheme = AppTheme(rawValue: browserPreferences.string(forKey: "booru.app_theme") ?? "") ?? .dark
        if booruTheme != imageTheme { booruTheme = imageTheme }
        let tags = browserPreferences.string(forKey: "manga.defaultTags") ?? ""
        if defaultTags != tags { defaultTags = tags }
        let exclusions = browserPreferences.string(forKey: "manga.defaultExcludedTags") ?? ""
        if defaultExcludedTags != exclusions { defaultExcludedTags = exclusions }
        let verified = browserPreferences.bool(forKey: "site_verified") && Self.supportsComicsAddress(browserPreferences.string(forKey: "manga.site_address") ?? "")
        if isSiteVerified != verified { isSiteVerified = verified }
        let siteAddress = browserPreferences.string(forKey: "manga.site_address") ?? ""
        if mangaSiteAddress != siteAddress { mangaSiteAddress = siteAddress }
    }
    private let browserPreferences: UserDefaults

    public var mangaSiteAddress: String {
        didSet {
            browserPreferences.set(mangaSiteAddress, forKey: "manga.site_address")
            if browserPreferences != .standard {
                UserDefaults.standard.set(mangaSiteAddress, forKey: "manga.site_address")
            }
        }
    }

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

        self.mangaTheme = AppTheme(rawValue: browserPreferences.string(forKey: "app_theme") ?? "") ?? .dark
        self.booruTheme = AppTheme(rawValue: browserPreferences.string(forKey: "booru.app_theme") ?? "") ?? .dark
        let mangaColumns = browserPreferences.integer(forKey: "grid_columns")
        let booruColumns = browserPreferences.integer(forKey: "booru.grid_columns")
        self.mangaColumns = min(5, max(0, mangaColumns))
        self.booruColumns = min(5, max(0, booruColumns))
        self.mangaFolderColumns = min(5, max(0, browserPreferences.integer(forKey: "folder_columns")))
        self.booruFolderColumns = min(5, max(0, browserPreferences.integer(forKey: "booru.folder_columns")))
        self.defaultTags = browserPreferences.string(forKey: "manga.defaultTags") ?? ""
        self.defaultExcludedTags = browserPreferences.string(forKey: "manga.defaultExcludedTags") ?? ""

        // New opt-in fallback; the old preference selected native UI versus external Safari.
        self.useEmbeddedBrowser = browserPreferences.bool(forKey: "use_embedded_browser")

        self.isOnboardingCompleted = browserPreferences.bool(forKey: "onboarding_completed")
        self.isSiteVerified = browserPreferences.bool(forKey: "site_verified") && Self.supportsComicsAddress(browserPreferences.string(forKey: "manga.site_address") ?? "")
        self.mangaSiteAddress = browserPreferences.string(forKey: "manga.site_address") ?? ""
    }

    static func supportsComicsAddress(_ input: String) -> Bool {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return false }
        guard let url = URLComponents(string: value.contains("://") ? value : "https://" + value) else { return false }
        guard let host = url.host?.lowercased(), !host.isEmpty else { return false }
        guard url.user == nil && url.password == nil else { return false }
        guard host.contains(".") || host == "localhost" else { return false }
        guard !host.hasPrefix(".") && !host.hasSuffix(".") else { return false }
        if let scheme = url.scheme?.lowercased(), scheme != "https" && scheme != "http" {
            return false
        }
        return true
    }

    static func normalizedComicsAddress(_ input: String) -> String {
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URLComponents(string: raw.contains("://") ? raw : "https://" + raw),
              let host = url.host?.lowercased() else {
            return raw.lowercased()
        }
        return host
    }

    @discardableResult
    public func verifySite(input: String) -> Bool {
        let cleaned = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let isValid = Self.supportsComicsAddress(cleaned)
        if isValid {
            self.isSiteVerified = true
            let saved = Self.normalizedComicsAddress(cleaned)
            self.mangaSiteAddress = saved
        }
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

    @MainActor public func startCoverQueue() {
        guard isSiteVerified else { return }
        guard coverQueueActive, mode == .manga, CoverQueuePolicy.allowsBackfill else { resumeCoverQueue = true; return }
        if let task = coverQueueTask, !task.isCancelled {
            coverQueueRequested = true
            return
        }
        let previous = coverQueueTask, token = UUID()
        coverQueueGeneration = token
        coverQueueTask = Task { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled else { return }
            defer { if self.coverQueueGeneration == token { self.coverQueueTask = nil } }
            repeat {
                coverQueueRequested = false
                await coverQueueActor.start(state: coverQueueState)
            } while coverQueueRequested && !Task.isCancelled && coverQueueActive && mode == .manga && CoverQueuePolicy.allowsBackfill
            if !CoverQueuePolicy.allowsBackfill { resumeCoverQueue = true }
        }
    }

    @MainActor func setCoverQueueActive(_ active: Bool) {
        let allowed = active && mode == .manga && CoverQueuePolicy.allowsBackfill
        guard coverQueueActive != allowed else { return }
        coverQueueActive = allowed
        if !allowed {
            resumeCoverQueue = resumeCoverQueue || (coverQueueTask != nil && !coverQueueState.isPaused)
            coverQueueTask?.cancel()
        } else if resumeCoverQueue {
            resumeCoverQueue = false
            startCoverQueue()
        }
    }
}
