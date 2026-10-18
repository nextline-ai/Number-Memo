import SwiftUI

struct BooruRootView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.scenePhase) private var scenePhase
    @Environment(BooruStore.self) private var store
    @Binding var selectedTab: AppTab
    private var source: any BooruProviding {
        #if DEBUG
        if BooruUITestSupport.enabled { return BooruUITestSupport.source }
        #endif
        return BooruClient.shared
    }
    private var startup: LaunchFeedWarmup? {
        #if DEBUG
        if ContentUITestSupport.enabled || ContentUITestSupport.unitTestsEnabled,
           !ProcessInfo.processInfo.arguments.contains("--launch-warmup-test") { return nil }
        #endif
        return env.launchFeeds
    }
    var body: some View {
        AppTabLayout(selection: $selectedTab, mode: .booru,
            saved: NavigationStack {
                Group {
                    if store.servers.isEmpty { BooruSetupView() }
                    else { BooruFavoritesView(source: source) }
                }.appRootHeader("Saved")
            },
            explore: NavigationStack {
                Group {
                    if store.servers.isEmpty { BooruSetupView() }
                    else {
                        Group {
                            if store.selectedServers.isEmpty { BooruNoSelectionView() }
                            else { BooruFeedView(servers: store.selectedServers, source: source, startup: startup) }
                        }
                            .toolbar { ToolbarItem(placement: .topBarTrailing) { BooruServerMenu() } }
                    }
                }.appRootHeader("Explore")
            },
            collections: NavigationStack {
                Group {
                    if store.servers.isEmpty { BooruSetupView() }
                    else { BooruSavedServersView(source: source) }
                }.appRootHeader("Tags")
            },
            settings: NavigationStack { BooruMoreView(source: source).appRootHeader("More") })
        .onChange(of: store.servers.count) { old, new in
            if env.mode == .booru && old == 0 && new > 0 && (selectedTab == .folders || selectedTab == .works) { selectedTab = .works }
        }
        .onChange(of: env.mode == .booru && scenePhase == .active) { _, active in
            if !active { Task { await BooruThumbnailCache.shared.cancelPrefetch() } }
        }
        .alert(L10n.text("Unable to save. Please try again."), isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button(L10n.text("OK")) { store.error = nil }
        } message: { Text(store.error ?? "") }
    }

}

struct BooruSetupView: View {
    @State private var addingServer = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Image(systemName: "photo.on.rectangle.angled").font(.system(size: 48)).foregroundStyle(.tint)
                Text(L10n.text("Connect an Image Website")).font(.largeTitle.bold())
                Text(L10n.text("No websites are included. Add a website you use, or bring your servers and favorites from a backup."))
                    .foregroundStyle(.secondary)
                Button { addingServer = true } label: {
                    Label(L10n.text("Enter Website Address"), systemImage: "link")
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                }.buttonStyle(.borderedProminent).controlSize(.large).accessibilityIdentifier("booru.setupAddress")
                NavigationLink { AnimeBoxesImportView() } label: {
                    Label(L10n.text("Import from Anime Boxes"), systemImage: "square.and.arrow.down")
                }.accessibilityIdentifier("booru.setupImport")
            }.padding(24).frame(maxWidth: 560).frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $addingServer) { BooruServerEditor(server: nil) }
    }
}

struct BooruServerMenu: View {
    var compact = false
    @Environment(BooruStore.self) private var store
    var body: some View {
        Menu {
            ForEach(store.servers) { server in
                Button { store.perform { try store.toggleServer(server) } } label: {
                    Label(server.displayName, systemImage: store.selectedServerIDs.contains(server.id) ? "checkmark.circle.fill" : "globe")
                }
            }
        } label: {
            Image(systemName: "server.rack").font(.system(size: 17, weight: .medium))
                .frame(width: compact ? nil : 36, height: compact ? nil : 44)
        }.menuActionDismissBehavior(.disabled).accessibilityLabel(L10n.text("Servers") + ": " + (store.selectedServerIDs.isEmpty ? L10n.text("None") : store.selectedServers.map(\.displayName).joined(separator: ", "))).accessibilityIdentifier("booru.server")
    }
}

@MainActor @Observable
final class BooruFeedLoader {
    private(set) var posts: [BooruPost] = []
    private(set) var visiblePosts: [BooruPost] = []
    private(set) var loading = false
    private(set) var didLoad = false
    private(set) var contentID: String?
    private(set) var unsupportedSort = false
    private(set) var errors: [String: String] = [:]
    var error: String? { errors.values.first }
    var hasMore: Bool { remaining.contains { errors[$0] == nil } }
    private var pages: [String: Int] = [:]
    private var pageFingerprints: [String: [Int64]] = [:]
    private var remaining = Set<String>()
    private var generation = UUID()
    @ObservationIgnored private var blacklistText: [String: String] = [:]
    @ObservationIgnored private var blacklists: [String: BooruBlacklist] = [:]
    @ObservationIgnored private var excludedPostIDs = Set<String>()

    func setExcludedPostIDs(_ ids: Set<String>) {
        guard ids != excludedPostIDs else { return }
        excludedPostIDs = ids
        updateVisiblePosts()
    }

    func setBlacklists(_ text: [String: String]) {
        guard text != blacklistText else { return }
        blacklistText = text
        blacklists = text.mapValues(BooruBlacklist.init)
        updateVisiblePosts()
    }

    private func publish(_ values: [BooruPost]) {
        guard posts != values else { return }
        posts = values
        updateVisiblePosts()
    }

    private func updateVisiblePosts() {
        visiblePosts = blacklists.values.allSatisfy { $0.rules.isEmpty } && excludedPostIDs.isEmpty ? posts
            : posts.filter { !excludedPostIDs.contains($0.id) && !(blacklists[$0.serverID]?.contains($0) ?? false) }
    }

    func load(server: BooruServer, source: any BooruProviding, query: String, poolID: Int64? = nil, reset: Bool) async {
        await load(servers: [server], source: source, query: query, poolID: poolID, reset: reset)
    }

    func load(servers: [BooruServer], source: any BooruProviding, query: String, poolID: Int64? = nil, sort: BooruSort = .latest, rating: BooruRating = .all, reset: Bool, contentID: String? = nil, startup: LaunchFeedWarmup? = nil, useLaunchPage: Bool = false, onGoldRestricted: ((String, [Int64]) -> Void)? = nil) async {
        if !reset && (loading || !hasMore) { return }
        if reset { generation = UUID() }
        let token = generation
        unsupportedSort = false
        var nextPages = reset ? [:] : pages
        var nextFingerprints = reset ? [:] : pageFingerprints
        var nextPosts = reset ? [] : posts
        var seen = Set(nextPosts.map(\.id))
        var nextErrors = reset ? [:] : errors
        var nextRemaining = reset ? Set(servers.map(\.id)) : remaining
        let requests = servers.filter { nextRemaining.contains($0.id) && nextErrors[$0.id] == nil }.map { ($0, nextPages[$0.id] ?? 0) }
        loading = true
        defer { if token == generation { loading = false } }
        await withTaskGroup(of: (String, BooruBatch?, String?).self) { group in
            for (server, page) in requests {
                group.addTask {
                    do {
                        let batch: BooruBatch
                        if let poolID { batch = try await source.poolPosts(server: server, poolID: poolID, page: page) }
                        else if reset, useLaunchPage, let startup {
                            batch = try await startup.booruPage(server: server, query: query, rating: rating, sort: sort, initialConsumer: true)
                        } else {
                            if reset, let startup { await startup.invalidateBooru(server: server, query: query, rating: rating, sort: sort) }
                            try Task.checkCancellation()
                            batch = try await BooruSortValidation.posts(source: source, server: server, query: rating.query(query, server: server), page: page, sort: sort)
                        }
                        return (server.id, batch, nil)
                    } catch is UnsupportedBooruSort { return (server.id, nil, "unsupported-sort") }
                    catch { return (server.id, nil, BooruConnectionMessage.describe(error)) }
                }
            }
            for await (id, batch, error) in group {
                guard !Task.isCancelled, token == generation else { group.cancelAll(); return }
                if error == "unsupported-sort" { unsupportedSort = true; continue }
                if let batch {
                    if !batch.goldRestrictedIDs.isEmpty { onGoldRestricted?(id, batch.goldRestrictedIDs) }
                    let incoming = batch.posts.filter { seen.insert($0.id).inserted }
                    nextPosts += incoming
                    if poolID == nil, !nextPosts.isEmpty, nextPosts.allSatisfy({ sort.metric($0) != nil }) {
                        nextPosts.sort { sort.metric($0) == sort.metric($1) ? $0.id < $1.id : sort.metric($0)! > sort.metric($1)! }
                    }
                    nextPages[id, default: 0] += 1
                    let fingerprint = (batch.posts.map(\.postID) + batch.goldRestrictedIDs).sorted()
                    if !batch.hasMore || batch.sourcePostCount == 0 || nextFingerprints[id] == fingerprint
                        || !reset && incoming.isEmpty && batch.goldRestrictedIDs.isEmpty { nextRemaining.remove(id) }
                    nextFingerprints[id] = fingerprint
                } else { nextErrors[id] = error }
                // Publish each server as it finishes so slow hosts do not delay the first images.
                // Popular sorting stays atomic until every server validates the requested sort.
                if sort == .latest && !unsupportedSort && !nextPosts.isEmpty {
                    publish(nextPosts); pages = nextPages; pageFingerprints = nextFingerprints; errors = nextErrors; remaining = nextRemaining
                    self.contentID = contentID; didLoad = true
                    if reset && useLaunchPage, batch != nil, let server = servers.first(where: { $0.id == id }) {
                        startup?.didPublishBooru(server: server, query: query, rating: rating, sort: sort)
                    }
                }
            }
        }
        // A cancelled refresh must never replace a populated feed with an empty one.
        guard !Task.isCancelled, token == generation else { return }
        guard !unsupportedSort else { return }
        publish(nextPosts); pages = nextPages; pageFingerprints = nextFingerprints; errors = nextErrors; remaining = nextRemaining
        self.contentID = contentID; didLoad = true
        if reset && useLaunchPage {
            for server in servers where nextPages[server.id] != nil {
                startup?.didPublishBooru(server: server, query: query, rating: rating, sort: sort)
            }
        }
    }
}

struct BooruFeedView: View {
    let servers: [BooruServer]
    let source: any BooruProviding
    private let startup: LaunchFeedWarmup?
    var pool: BooruPool?
    var challenge: ChallengeSessionController?
    var header: AnyView?
    @State private var challengeBrowser = false
    @Environment(BooruStore.self) private var store
    @Environment(AppEnvironment.self) private var env
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.discoveryContext) private var inheritedContext
    @State private var tasteSession = UUID().uuidString
    @State private var submitted = false
    private var discovery: DiscoveryContext {
        if let challenge { return DiscoveryContext(origin: .external, session: "challenge:" + challenge.session.definition.id) }
        return DiscoveryContext(origin: !submitted && inheritedContext.origin == .recommendation ? .recommendation : query.isEmpty ? .feed : .search, query: query, session: tasteSession)
    }
    @State private var loader = BooruFeedLoader()
    @State private var searchText: String
    @State private var query: String
    @State private var suggestions: [BooruTag] = []
    @State private var suggesting = false
    @State private var suggestionError: String?
    @State private var retry = 0
    @State private var validating: BooruServer?
    @State private var accountServer: BooruServer?
    @State private var browserServerID: String?
    @State private var sort: BooruSort = .latest
    @State private var acceptedSort: BooruSort = .latest
    @State private var sortMessage: String?
    @State private var isSearchBarVisible = true
    @State private var searchScroll = ScrollSearchVisibility()
    @State private var scrollPosition = BooruFeedScrollPosition()
    @State private var searchSlotPinned = false
    @State private var paginationFooterVisible = false
    @State private var loadedRequest: String?
    @SwiftUI.AppStorage("booru.rating", store: ReaderPreferences.booruDefaults) private var savedRating: BooruRating = .all
    @SwiftUI.AppStorage("booru.useEmbeddedBrowser", store: ReaderPreferences.booruDefaults) private var useEmbeddedBrowser = false
    @State private var selectedPost: BooruPost?
    @State private var viewerPosition: BooruPost?
    @State private var saveFeedback: WorkSaveFeedback?
    @FocusState private var searchFocused: Bool
    @SwiftUI.AppStorage("booru.rememberHistory", store: ReaderPreferences.booruDefaults) private var rememberHistory = true

    init(server: BooruServer, source: any BooruProviding, initialQuery: String = "", pool: BooruPool? = nil) {
        self.init(servers: [server], source: source, initialQuery: initialQuery, pool: pool)
    }
    init(servers: [BooruServer], source: any BooruProviding, initialQuery: String = "", pool: BooruPool? = nil, challenge: ChallengeSessionController? = nil, header: AnyView? = nil, startup: LaunchFeedWarmup? = nil) {
        self.servers = servers; self.source = source; self.pool = pool
        self.startup = startup
        self.challenge = challenge; self.header = header
        _searchText = State(initialValue: initialQuery); _query = State(initialValue: initialQuery)
    }
    private var rating: BooruRating {
        get { challenge?.imageRating ?? savedRating }
        nonmutating set {
            if let challenge { challenge.rating(newValue) }
            else { savedRating = newValue }
        }
    }
    private func openBrowser(_ id: String? = nil) {
        browserServerID = id
        if challenge == nil { useEmbeddedBrowser = true } else { challengeBrowser = true }
    }
    private var visiblePosts: [BooruPost] { loader.visiblePosts }
    private var hasAccessiblePosts: Bool { loader.posts.contains(where: store.isVisible) }
    private var isActive: Bool { env.mode == .booru && scenePhase == .active }
    private func updateBlacklists() {
        loader.setBlacklists(Dictionary(uniqueKeysWithValues: servers.map { ($0.id, store.blacklist(serverID: $0.id)) }))
        loader.setExcludedPostIDs(store.confirmedGoldRestrictedIDs)
    }
    private func updateFooterVisibility() {
        let visible = scrollPosition.footerFrame.map { $0.maxY > 0 && $0.minY < scrollPosition.viewportHeight } ?? false
        if paginationFooterVisible != visible { paginationFooterVisible = visible }
    }
    var body: some View {
        Group {
            if useEmbeddedBrowser && challenge == nil {
                BooruEmbeddedBrowserView(servers: servers, query: query, poolID: pool?.id, sort: sort, rating: rating, preferredServerID: browserServerID)
            } else { nativeFeed }
        }
        .workSaveFeedback($saveFeedback, identifier: "booru.saveStatus")
        .navigationTitle(challenge?.session.definition.title ?? pool?.name.replacingOccurrences(of: "_", with: " ") ?? L10n.text("Explore"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $validating) { server in
            BooruValidationView(server: server, initialURL: server.browsingURL(query: sort.query(rating.query(query, server: server), engine: server.engine), poolID: pool?.id))
        }
        .sheet(isPresented: $challengeBrowser) {
            NavigationStack {
                BooruEmbeddedBrowserView(servers: servers, query: query, poolID: pool?.id, sort: sort, rating: rating, preferredServerID: browserServerID)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.text("Done")) { challengeBrowser = false } } }
            }.tint(.purple)
        }
        .sheet(item: $accountServer) { BooruServerEditor(server: $0) }
        .fullScreenCover(item: $selectedPost) { post in
            if let server = store.servers.first(where: { $0.id == post.serverID }) { BooruPostView(post: viewerPosition ?? post, posts: visiblePosts, server: server, source: source, loadMore: {
                for _ in 0..<3 {
                    guard !Task.isCancelled, UIApplication.shared.applicationState == .active else { break }
                    let count = visiblePosts.count
                    await load(reset: false)
                    if visiblePosts.count > count || !loader.hasMore { break }
                }
                return BooruViewerBatch(posts: visiblePosts, hasMore: loader.hasMore, failure: loader.error)
            }, positionChanged: { viewerPosition = $0; challenge?.select($0) }, challenge: challenge).environment(\.discoveryContext, discovery) }
        }
    }
    private var nativeFeed: some View {
        ZStack(alignment: .top) {
            ScrollView {
              VStack(spacing: 0) {
                GeometryReader { proxy in
                    Color.clear.preference(key: BooruFeedOffsetKey.self, value: proxy.frame(in: .named("booru.feedViewport")).minY)
                }.frame(height: 0)
                LazyVStack(spacing: 16) {
                    if let header {
                        header
                        Group {
                            if !searchSlotPinned { searchControls }
                            else { Color.clear.frame(height: 56) }
                        }.padding(.horizontal, -16).background {
                            GeometryReader { proxy in
                                Color.clear.preference(key: BooruSearchSlotKey.self, value: proxy.frame(in: .named("booru.feedViewport")).minY)
                            }
                        }
                    }
                    if pool == nil { filters }
                    BooruPostGrid(posts: visiblePosts, showsFavoriteIndicator: true, prefetch: {
                        if loader.hasMore && !loader.loading { Task { await load(reset: false) } }
                    }, feedback: { saveFeedback = $0 }) { viewerPosition = $0; selectedPost = $0; challenge?.select($0) }.environment(\.discoveryContext, discovery)
                    if loader.loading { ProgressView(L10n.text("Loading")).padding(24) }
                    ForEach(servers.filter { loader.errors[$0.id] != nil }) { server in
                        VStack(alignment: .leading, spacing: 12) {
                            Label(server.displayName, systemImage: "server.rack").font(.headline)
                            Text(loader.errors[server.id] ?? "").font(.subheadline).foregroundStyle(.secondary)
                            DisclosureGroup(L10n.text("Search Tags")) {
                                Text(sort.query(rating.query(query, server: server), engine: server.engine))
                                    .font(.caption.monospaced()).textSelection(.enabled)
                            }
                            if server.engine == .danbooru && query.split(whereSeparator: \.isWhitespace).count >= 2 {
                                Text(L10n.text("Danbooru limits searches by account level. Regular accounts usually allow up to two tags. For more tags, upgrade on the website and enter your username and API key here. Gelbooru does not have this two-tag limit. Connection errors can have other causes."))
                                    .font(.footnote).foregroundStyle(.secondary)
                                Button(L10n.text("Account Settings"), systemImage: "person.crop.circle") { accountServer = server }
                                    .accessibilityIdentifier("booru.accountSettings")
                            }
                            HStack {
                                Button(L10n.text("Validate Client"), systemImage: "checkmark.shield") { validating = server }
                                    .buttonStyle(.borderedProminent).accessibilityIdentifier("booru.validate")
                                Button(L10n.text("Try Again")) { retry += 1 }.buttonStyle(.bordered).accessibilityIdentifier("content.retry")
                            }
                            Button(L10n.text("Use Embedded Browser"), systemImage: "globe") { openBrowser(server.id) }
                                .accessibilityIdentifier("booru.openBrowser")
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 18))
                    }
                    if loader.didLoad && !loader.loading && loader.errors.isEmpty && visiblePosts.isEmpty && (!loader.hasMore || hasAccessiblePosts) {
                        ContentUnavailableView(L10n.text(!hasAccessiblePosts ? (pool == nil ? "No Posts" : "No Available Posts") : "Posts Hidden"), systemImage: "photo.on.rectangle", description: Text(L10n.text(!hasAccessiblePosts ? (pool == nil ? "Try different tags or another server." : "This website returned no posts for this pool. It may be empty or its posts may no longer be available.") : "These posts match your blacklist. You can load the next page.")))
                        if pool != nil {
                            Button(L10n.text("Open in Browser"), systemImage: "globe") { openBrowser() }
                        }
                    }
                    if loader.hasMore {
                        Button(L10n.text("Load More")) { Task { await load(reset: false) } }
                            .buttonStyle(.bordered).accessibilityIdentifier("booru.more")
                            .disabled(loader.loading)
                            .onGeometryChange(for: CGRect.self) { proxy in
                                proxy.frame(in: .named("booru.feedViewport"))
                            } action: { frame in
                                scrollPosition.footerFrame = frame
                                updateFooterVisibility()
                            }
                    }
                }.padding(16).padding(.top, pool == nil && header == nil ? 56 : 0)
              }
            }
            .coordinateSpace(name: "booru.feedViewport")
            .scrollDismissesKeyboard(.interactively)
            .trackScrollGeometry { oldY, newY in
                if let visible = searchScroll.update(oldY: oldY, newY: newY, focused: searchFocused) { isSearchBarVisible = visible }
            }
            .onPreferenceChange(BooruFeedOffsetKey.self) { value in
                if #available(iOS 18.0, *) { return }
                guard let value else { return }
                let newY = -value
                if let visible = searchScroll.update(oldY: scrollPosition.y, newY: newY, focused: searchFocused) { isSearchBarVisible = visible }
                scrollPosition.y = newY
            }
            .onPreferenceChange(BooruSearchSlotKey.self) { value in
                if let value {
                    let pinned = value <= 0
                    if pinned != searchSlotPinned { searchSlotPinned = pinned }
                }
            }
            .refreshable {
                let value = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                if query != value { query = value }
                else {
                    // SwiftUI can cancel its refresh action while the scroll view updates.
                    // Keep this user-requested refresh alive until the result is committed.
                    await Task { await load(reset: true) }.value
                }
            }
            if pool == nil && (header == nil || searchSlotPinned) {
                searchControls
                    .offset(y: isSearchBarVisible ? 0 : -60).opacity(isSearchBarVisible ? 1 : 0)
                    .allowsHitTesting(isSearchBarVisible).accessibilityHidden(!isSearchBarVisible)
            }
        }.clipped()
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { height in
            scrollPosition.viewportHeight = height
            updateFooterVisibility()
        }
        .task(id: "\(paginationFooterVisible):\(loader.loading):\(loader.posts.count):\(requestKey):\(isActive)") {
            guard paginationFooterVisible, isActive, !loader.loading, loader.hasMore, !visiblePosts.isEmpty, selectedPost == nil else { return }
            // Let appended rows lay out before deciding whether the same footer
            // still reaches the viewport after a refresh or page completion.
            do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
            guard paginationFooterVisible, isActive, !loader.loading, loader.hasMore, !visiblePosts.isEmpty, selectedPost == nil else { return }
            // Loading changes this task's identity. The request owns its lifetime
            // just like the grid's existing pagination action.
            Task { await load(reset: false) }
        }
        .animation(isSearchBarVisible ? .spring(response: 0.35, dampingFraction: 0.86) : .easeInOut(duration: 0.32), value: isSearchBarVisible)
        .onChange(of: searchFocused) { _, focused in if focused { isSearchBarVisible = true } }
        .onAppear { if !BooruRating.options(for: servers).contains(rating) { rating = .all } }
        .onChange(of: servers) { _, _ in
            updateBlacklists()
            if !BooruRating.options(for: servers).contains(rating) { rating = .all }
            if !sortOptions.contains(sort) { sort = .latest; acceptedSort = .latest }
        }
        .onChange(of: store.revision) { _, _ in updateBlacklists() }
        .onChange(of: store.confirmedGoldRestrictedIDs) { _, ids in loader.setExcludedPostIDs(ids) }
        .task(id: requestKey + ":\(isActive)") {
            guard isActive else { return }
            updateBlacklists()
            guard loadedRequest != requestKey else { return }
            let key = requestKey
            // A scene cancellation may leave a successfully published partial
            // first page. Preserve that page and its cursor when returning.
            if loader.didLoad && loader.contentID == key { loadedRequest = key; return }
            await load(reset: true, useLaunchPage: loadedRequest == nil && !loader.didLoad && retry == 0 && query.isEmpty && sort == .latest)
            if !Task.isCancelled && !loader.unsupportedSort { loadedRequest = key }
        }
        .onReceive(NotificationCenter.default.publisher(for: .booruClientValidated)) { if let id = $0.object as? String, servers.contains(where: { $0.id == id }) { retry += 1 } }
        .transientMessage($sortMessage)
        .task(id: "\(searchFocused):\(searchText)") { await complete() }
    }
    private var searchControls: some View {
        VStack(spacing: 0) {
            ScrollSearchBar(text: $searchText, focused: $searchFocused, prompt: L10n.text("Search tags"), identifier: "booru.search") { submit(searchText) }
            if searchFocused && (searchText.isEmpty && !searchHistory.isEmpty || !suggestions.isEmpty || suggestionError != nil || suggesting) {
                searchSuggestions.searchResultsPanel(height: searchText.isEmpty ? 260 : max(60, min(280, CGFloat(suggestions.count) * 47)))
            }
        }
    }
    private var requestKey: String { query + "|\(sort.rawValue)|\(rating.rawValue)|\(retry)|" + servers.map { $0.id + $0.canonicalAddress + $0.engine.rawValue }.joined(separator: ",") }
    private var sortOptions: [BooruSort] { BooruSort.options(for: servers, local: challenge?.session.sourceKind == "folder") }
    private var filters: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout())
        return layout {
            if BooruRating.options(for: servers).count > 1 {
                BrowseFilterMenu(title: rating.title, icon: "line.3.horizontal.decrease") {
                    Picker(L10n.text("Rating"), selection: Binding(get: { rating }, set: { rating = $0 })) { ForEach(BooruRating.options(for: servers)) { Text($0.title).tag($0) } }
                }.accessibilityIdentifier("booru.rating")
            }
            if !typeSize.isAccessibilitySize { Spacer() }
            BrowseFilterMenu(title: sort.title, icon: "arrow.up.arrow.down") {
                Picker(L10n.text("Sort"), selection: $sort) { ForEach(sortOptions) { Text($0.title).tag($0) } }
            }.accessibilityIdentifier("booru.sort")
        }
    }
    @ViewBuilder private var searchSuggestions: some View {
        VStack(alignment: .leading, spacing: 0) {
            if searchText.isEmpty {
                List {
                    SearchHistorySection(history: searchHistory, saved: servers.flatMap { store.savedTags(serverID: $0.id, kind: "search") }, open: { searchText = $0; submit($0) }, star: { query in
                        let allSaved = servers.allSatisfy { store.savedTags(serverID: $0.id, kind: "search").contains(query) }
                        store.perform { for server in servers where allSaved || !store.savedTags(serverID: server.id, kind: "search").contains(query) { try store.toggleTag(query, serverID: server.id, kind: "search") } }
                    }, remove: { query in store.perform { for server in servers { try store.deleteSearch(query, serverID: server.id) } } }, clear: {
                        store.perform { for server in servers { try store.clearHistory(serverID: server.id) } }
                    })
                }.listStyle(.plain).scrollContentBackground(.hidden)

            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(suggestions) { tag in
                            Button {
                                if let completion = BooruCompletion(searchText) { searchText = completion.inserting(tag.name) }
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: tag.isArtist ? "person" : "number").foregroundStyle(.secondary)
                                    Text(tag.name).font(.subheadline).foregroundStyle(.primary).lineLimit(1)
                                    Spacer(minLength: 4)
                                    Text(tag.count.formatted()).font(.caption).foregroundStyle(.secondary)
                                }.frame(minHeight: 46).padding(.horizontal, 12).contentShape(Rectangle())
                            }.accessibilityIdentifier("booru.suggestion.\(tag.name)")
                            if tag.id != suggestions.last?.id { Divider() }
                        }
                        if suggesting { ProgressView().padding(16).accessibilityLabel(L10n.text("Finding tags")) }
                        if let suggestionError { Text(suggestionError).font(.caption).foregroundStyle(.secondary).padding(12) }
                    }
                }

            }
        }.buttonStyle(.plain)
    }
    private var searchHistory: [String] {
        var seen = Set<String>()
        return servers.flatMap { store.history(serverID: $0.id) }.filter { seen.insert($0).inserted }
    }
    private func submit(_ text: String) {
        searchFocused = false
        suggestions = []
        submitted = true; tasteSession = UUID().uuidString
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if rememberHistory && challenge == nil { store.perform {
            for server in servers { try store.recordSearch(value, serverID: server.id) }
            try store.recordTasteSearch(DiscoveryContext(origin: .search, query: value, session: tasteSession), servers: servers)
        } }
        if query == value { retry += 1 } else { query = value }
    }
    private func load(reset: Bool, useLaunchPage: Bool = false) async {
        guard isActive else { return }
        let requested = sort
        await loader.load(servers: servers, source: source, query: query, poolID: pool?.id, sort: requested, rating: rating, reset: reset,
                          contentID: requestKey, startup: startup, useLaunchPage: useLaunchPage,
                          onGoldRestricted: { store.recordGoldRestrictions(serverID: $0, postIDs: $1) })
        guard !Task.isCancelled, sort == requested else { return }
        if loader.unsupportedSort {
            sort = acceptedSort
            loadedRequest = requestKey
            sortMessage = L10n.text("This server does not support that sort. Your previous sort has been restored.")
        } else if loader.errors.isEmpty { acceptedSort = requested }
    }
    private func complete() async {
        suggestions = []; suggestionError = nil; suggesting = false
        guard searchFocused, let completion = BooruCompletion(searchText) else { return }
        suggesting = true
        defer { if !Task.isCancelled { suggesting = false } }
        do {
            try await Task.sleep(for: .milliseconds(300))
            let tasteStore = store.tasteStore
            let found = await withTaskGroup(of: [BooruTag].self, returning: [BooruTag].self) { group in
                for server in servers { group.addTask {
                    let suggestions = (try? await source.suggestions(server: server, token: completion.token)) ?? []
                    let metadata = suggestions.filter(\.isMetadata).map(\.name)
                    if !metadata.isEmpty { try? tasteStore.record(.taxonomy, item: .init(source: server.canonicalAddress, id: 0, tags: [], metadata: metadata), context: .unknown) }
                    return suggestions
                } }
                var values: [BooruTag] = []
                for await tags in group { values += tags }
                return values
            }
            try Task.checkCancellation()
            var seen = Set<String>()
            suggestions = Array(found.sorted { $0.count > $1.count }.filter { seen.insert($0.name).inserted }.prefix(12))
        } catch { if !Task.isCancelled { suggestionError = error.localizedDescription } }
    }
}

struct BooruPostGrid: View {
    @Environment(\.discoveryContext) private var discovery
    let posts: [BooruPost]
    var server: BooruServer? = nil
    var showsFavoriteIndicator = false
    var selection: Binding<Set<String>>? = nil
    var prefetch: (() -> Void)? = nil
    var feedback: (WorkSaveFeedback) -> Void = { _ in }
    let open: (BooruPost) -> Void
    @Environment(BooruStore.self) private var store
    @Environment(AppEnvironment.self) private var env
    @Environment(\.scenePhase) private var scenePhase
    @State private var filing: BooruPost?
    @State private var similarity: VisualSimilaritySeed?
    var body: some View {
        let favorites = store.favoriteIDs
        let prefetchThresholdIndex = max(0, posts.count - 8)
        let serversByID = Dictionary(uniqueKeysWithValues: store.servers.map { ($0.id, $0) })
        return LazyVGrid(columns: WorkGridLayout.columns(env.gridColumns), spacing: 12) {
            ForEach(Array(posts.enumerated()), id: \.element.id) { index, post in
                if let server = serversByID[post.serverID] ?? server {
                    Group {
                        if let selection {
                            Button {
                                if selection.wrappedValue.contains(post.id) { selection.wrappedValue.remove(post.id) }
                                else { selection.wrappedValue.insert(post.id) }
                            } label: {
                                thumbnail(post, server: server, isFavorite: favorites.contains(post.id)).overlay(alignment: .topTrailing) {
                                    Image(systemName: selection.wrappedValue.contains(post.id) ? "checkmark.circle.fill" : "circle")
                                        .font(.title2).foregroundStyle(.white, .blue).padding(10)
                                }
                            }.buttonStyle(.plain)
                        } else if showsFavoriteIndicator {
                            Button { open(post) } label: {
                                thumbnail(post, server: server, isFavorite: favorites.contains(post.id))
                            }.buttonStyle(.plain).hoverEffect(.highlight)
                                .highPriorityGesture(LongPressGesture(minimumDuration: 0.55).onEnded { _ in save(post) })
                                .accessibilityAddTraits(.isButton)
                                .accessibilityAction { open(post) }
                                .accessibilityAction(named: L10n.text(favorites.contains(post.id) ? "Remove Favorite" : "Add Favorite")) { save(post) }
                                .accessibilityAction(named: L10n.text("Save to Folder")) { filing = post }
                        } else {
                            Button { open(post) } label: { thumbnail(post, server: server, isFavorite: favorites.contains(post.id)) }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    if store.isFavorite(post) { Button(L10n.text("Find works with a similar art style"), systemImage: "photo.on.rectangle.angled") { similarity = .init(post: post) } }
                                    Button(L10n.text(store.isFavorite(post) ? "Remove Favorite" : "Add Favorite"), systemImage: "heart") { save(post) }
                                    Button(L10n.text("Save to Folder"), systemImage: "folder") { filing = post }
                                    ShareLink(item: server.pageURL(postID: post.postID))
                                }
                        }
                    }
                    .id(post.id)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(server.displayName + " · " + String(post.postID))
                    .accessibilityIdentifier("booru.post.\(post.postID)")
                    .accessibilityValue(selection.map { $0.wrappedValue.contains(post.id) ? L10n.text("Selected") : "" } ?? (showsFavoriteIndicator ? WorkSaveResult.accessibilityValue(saved: favorites.contains(post.id), mode: .booru) : ""))
                    .onAppear {
                        guard env.mode == .booru, scenePhase == .active else { return }
                        if index >= prefetchThresholdIndex {
                            prefetch?()
                        }
                        guard index.isMultiple(of: 4) else { return }
                        let lookaheadEnd = min(posts.count, index + 9)
                        if index + 1 < lookaheadEnd {
                            let upcoming = Array(posts[(index + 1)..<lookaheadEnd])
                            let targets = upcoming.compactMap { p -> (URL, BooruServer)? in
                                guard let url = p.previewURL ?? p.sampleURL else { return nil }
                                let s = serversByID[p.serverID] ?? server
                                return (url, s)
                            }
                            BooruThumbnailCache.shared.prefetch(targets)
                        }
                    }
                }
            }
        }.sheet(item: $similarity) { VisualSimilarityView(seed: $0) }
        .sheet(item: $filing) { BooruFolderPicker(post: $0).environment(\.discoveryContext, discovery) }
    }

    private func thumbnail(_ post: BooruPost, server: BooruServer, isFavorite: Bool) -> some View {
        BooruPostThumbnailCard(post: post, server: server, showsFavoriteIndicator: showsFavoriteIndicator, isFavorite: isFavorite)
            .equatable()
    }

    private func save(_ post: BooruPost) {
        feedback(.perform { try BooruFavoriteAction.toggle(post, store: store, context: discovery) })
    }
}

struct BooruPostThumbnailCard: View, Equatable {
    let post: BooruPost
    let server: BooruServer
    var showsFavoriteIndicator = false
    var isFavorite = false
    var body: some View {
        BooruThumbnail(post: post, server: server)
            .frame(maxWidth: .infinity).aspectRatio(0.78, contentMode: .fit).clipped()
            .overlay(alignment: .topTrailing) {
                if post.isVideo || post.isAnimated {
                    Image(systemName: post.isVideo ? "play.fill" : "sparkles")
                        .font(.system(size: 10, weight: .bold)).padding(6).background(.ultraThinMaterial, in: Capsule()).padding(8)
                }
            }
            .overlay(alignment: .topLeading) {
                if showsFavoriteIndicator && isFavorite {
                    Image(systemName: "heart.fill").foregroundStyle(.pink).padding(8)
                        .background(.ultraThinMaterial, in: Circle()).padding(8)
                        .accessibilityIdentifier("booru.favoriteBadge.\(post.postID)")
                }
            }
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            // Cropping pixels does not crop SwiftUI hit testing.
            .contentShape(Rectangle())
    }
}

struct BooruNoSelectionView: View {
    var body: some View {
        ContentUnavailableView(L10n.text("No servers selected"), systemImage: "server.rack",
            description: Text(L10n.text("Choose servers using the server button above. Your saved works are kept.")))
            .accessibilityIdentifier("booru.noSelection")
    }
}


private final class BooruFeedScrollPosition {
    var y: CGFloat = 0
    var footerFrame: CGRect?
    var viewportHeight: CGFloat = 0
}
private struct BooruFeedOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) { value = nextValue() ?? value }
}
private struct BooruSearchSlotKey: PreferenceKey {
    static var defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) { value = nextValue() ?? value }
}
