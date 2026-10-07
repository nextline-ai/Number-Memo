import SwiftUI

struct BooruRootView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(BooruStore.self) private var store
    @Binding var selectedTab: AppTab
    private var source: any BooruProviding {
        #if DEBUG
        if BooruUITestSupport.enabled { return BooruUITestSupport.source }
        #endif
        return BooruClient.shared
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
                        BooruFeedView(servers: store.selectedServers, source: source)
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
                }.disabled(store.selectedServerIDs == [server.id])
            }
        } label: {
            Image(systemName: "server.rack").font(.system(size: 17, weight: .medium))
                .frame(width: compact ? nil : 32, height: compact ? nil : 32)
        }.menuActionDismissBehavior(.disabled).accessibilityLabel(L10n.text("Servers") + ": " + store.selectedServers.map(\.displayName).joined(separator: ", ")).accessibilityIdentifier("booru.server")
    }
}

@MainActor @Observable
final class BooruFeedLoader {
    private(set) var posts: [BooruPost] = []
    private(set) var loading = false
    private(set) var didLoad = false
    private(set) var errors: [String: String] = [:]
    var error: String? { errors.values.first }
    var hasMore: Bool { remaining.contains { errors[$0] == nil } }
    private var pages: [String: Int] = [:]
    private var remaining = Set<String>()
    private var generation = UUID()

    func load(server: BooruServer, source: any BooruProviding, query: String, poolID: Int64? = nil, reset: Bool) async {
        await load(servers: [server], source: source, query: query, poolID: poolID, reset: reset)
    }

    func load(servers: [BooruServer], source: any BooruProviding, query: String, poolID: Int64? = nil, sort: BooruSort = .latest, rating: BooruRating = .all, reset: Bool) async {
        if !reset && (loading || !hasMore) { return }
        if reset { generation = UUID() }
        let token = generation
        var nextPages = reset ? [:] : pages
        var nextPosts = reset ? [] : posts
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
                        else { batch = try await source.posts(server: server, query: sort.query(rating.query(query, server: server), engine: server.engine), page: page) }
                        return (server.id, batch, nil)
                    } catch { return (server.id, nil, BooruConnectionMessage.describe(error)) }
                }
            }
            for await (id, batch, error) in group {
                guard !Task.isCancelled, token == generation else { group.cancelAll(); return }
                if let batch {
                    var seen = Set(nextPosts.map(\.id))
                    nextPosts += batch.posts.filter { seen.insert($0.id).inserted }
                    if sort == .popular && poolID == nil { nextPosts.sort { $0.score == $1.score ? $0.id < $1.id : $0.score > $1.score } }
                    nextPages[id, default: 0] += 1
                    if !batch.hasMore { nextRemaining.remove(id) }
                } else { nextErrors[id] = error }
            }
        }
        // A cancelled refresh must never replace a populated feed with an empty one.
        guard !Task.isCancelled, token == generation else { return }
        posts = nextPosts; pages = nextPages; errors = nextErrors; remaining = nextRemaining
        didLoad = true
    }
}

struct BooruFeedView: View {
    let servers: [BooruServer]
    let source: any BooruProviding
    var pool: BooruPool?
    @Environment(BooruStore.self) private var store
    @Environment(\.discoveryContext) private var inheritedContext
    @State private var tasteSession = UUID().uuidString
    @State private var submitted = false
    private var discovery: DiscoveryContext { DiscoveryContext(origin: !submitted && inheritedContext.origin == .recommendation ? .recommendation : query.isEmpty ? .feed : .search, query: query, session: tasteSession) }
    @State private var loader = BooruFeedLoader()
    @State private var searchText: String
    @State private var query: String
    @State private var suggestions: [BooruTag] = []
    @State private var suggestionError: String?
    @State private var retry = 0
    @State private var validating: BooruServer?
    @State private var accountServer: BooruServer?
    @State private var browserServerID: String?
    @State private var sort: BooruSort = .latest
    @State private var isSearchBarVisible = true
    @State private var searchScroll = ScrollSearchVisibility()
    @State private var loadedRequest: String?
    @SwiftUI.AppStorage("booru.rating", store: ReaderPreferences.booruDefaults) private var rating: BooruRating = .all
    @SwiftUI.AppStorage("booru.useEmbeddedBrowser", store: ReaderPreferences.booruDefaults) private var useEmbeddedBrowser = false
    @State private var selectedPost: BooruPost?
    @FocusState private var searchFocused: Bool
    @SwiftUI.AppStorage("booru.rememberHistory", store: ReaderPreferences.booruDefaults) private var rememberHistory = true
    @SwiftUI.AppStorage("booru.autoLoad", store: ReaderPreferences.booruDefaults) private var autoLoad = false

    init(server: BooruServer, source: any BooruProviding, initialQuery: String = "", pool: BooruPool? = nil) {
        self.init(servers: [server], source: source, initialQuery: initialQuery, pool: pool)
    }
    init(servers: [BooruServer], source: any BooruProviding, initialQuery: String = "", pool: BooruPool? = nil) {
        self.servers = servers; self.source = source; self.pool = pool
        _searchText = State(initialValue: initialQuery); _query = State(initialValue: initialQuery)
    }
    private var visiblePosts: [BooruPost] {
        let filters = Dictionary(uniqueKeysWithValues: servers.map { ($0.id, BooruBlacklist(store.blacklist(serverID: $0.id))) })
        return loader.posts.filter { !(filters[$0.serverID]?.contains($0) ?? false) }
    }
    var body: some View {
        Group {
            if useEmbeddedBrowser {
                BooruEmbeddedBrowserView(servers: servers, query: query, poolID: pool?.id, sort: sort, rating: rating, preferredServerID: browserServerID)
            } else { nativeFeed }
        }
        .navigationTitle(pool?.name.replacingOccurrences(of: "_", with: " ") ?? L10n.text("Explore"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $validating) { server in
            BooruValidationView(server: server, initialURL: server.browsingURL(query: sort.query(rating.query(query, server: server), engine: server.engine), poolID: pool?.id))
        }
        .sheet(item: $accountServer) { BooruServerEditor(server: $0) }
        .fullScreenCover(item: $selectedPost) { post in
            if let server = store.servers.first(where: { $0.id == post.serverID }) { BooruPostView(post: post, posts: visiblePosts, server: server, source: source).environment(\.discoveryContext, discovery) }
        }
    }
    private var nativeFeed: some View {
        ZStack(alignment: .top) {
            ScrollView {
                LazyVStack(spacing: 16) {
                    if pool == nil { filters }
                    BooruPostGrid(posts: visiblePosts, showsFavoriteIndicator: pool == nil) { selectedPost = $0 }.environment(\.discoveryContext, discovery)
                    if loader.loading { ProgressView(L10n.text("Loading")).padding(24) }
                    ForEach(servers.filter { loader.errors[$0.id] != nil }) { server in
                        VStack(alignment: .leading, spacing: 12) {
                            Label(server.displayName, systemImage: "server.rack").font(.headline)
                            Text(loader.errors[server.id] ?? "").font(.subheadline).foregroundStyle(.secondary)
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
                            Button(L10n.text("Use Embedded Browser"), systemImage: "globe") { browserServerID = server.id; useEmbeddedBrowser = true }
                                .accessibilityIdentifier("booru.openBrowser")
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 18))
                    }
                    if loader.didLoad && !loader.loading && loader.errors.isEmpty && visiblePosts.isEmpty {
                        ContentUnavailableView(L10n.text(loader.posts.isEmpty ? (pool == nil ? "No Posts" : "No Available Posts") : "Posts Hidden"), systemImage: "photo.on.rectangle", description: Text(L10n.text(loader.posts.isEmpty ? (pool == nil ? "Try different tags or another server." : "This website returned no posts for this pool. It may be empty or its posts may no longer be available.") : "These posts match your blacklist. You can load the next page.")))
                        if pool != nil {
                            Button(L10n.text("Open in Browser"), systemImage: "globe") { useEmbeddedBrowser = true }
                        }
                    }
                    if loader.hasMore && !loader.loading {
                        Button(L10n.text("Load More")) { Task { await load(reset: false) } }
                            .buttonStyle(.bordered).accessibilityIdentifier("booru.more")
                            .task(id: autoLoad) { if autoLoad { await load(reset: false) } }
                    }
                }.padding(16).padding(.top, pool == nil ? 56 : 0)
            }
            .scrollDismissesKeyboard(.interactively)
            .trackScrollGeometry { oldY, newY in
                if let visible = searchScroll.update(oldY: oldY, newY: newY, focused: searchFocused) { isSearchBarVisible = visible }
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
            if pool == nil {
                VStack(spacing: 0) {
                    ScrollSearchBar(text: $searchText, focused: $searchFocused, prompt: L10n.text("Search tags"), identifier: "booru.search") { submit(searchText) }
                    if searchFocused && (searchText.isEmpty && !searchHistory.isEmpty || !suggestions.isEmpty || suggestionError != nil) {
                        searchSuggestions
                            .frame(maxHeight: searchText.isEmpty ? 260 : min(280, CGFloat(suggestions.count) * 47))
                            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
                            .padding(.horizontal, 16).shadow(color: .black.opacity(0.12), radius: 8, y: 4)
                    }
                }
                .offset(y: isSearchBarVisible ? 0 : -60).opacity(isSearchBarVisible ? 1 : 0)
                .allowsHitTesting(isSearchBarVisible).accessibilityHidden(!isSearchBarVisible)
            }
        }
        .animation(isSearchBarVisible ? .spring(response: 0.35, dampingFraction: 0.86) : .easeInOut(duration: 0.32), value: isSearchBarVisible)
        .onChange(of: searchFocused) { _, focused in if focused { isSearchBarVisible = true } }
        .onChange(of: searchText) { _, value in if value.isEmpty { query = "" } }
        .onAppear { if !BooruRating.options(for: servers).contains(rating) { rating = .all } }
        .onChange(of: servers) { _, _ in if !BooruRating.options(for: servers).contains(rating) { rating = .all } }
        .task(id: requestKey) {
            guard loadedRequest != requestKey else { return }
            let key = requestKey
            await load(reset: true)
            if !Task.isCancelled { loadedRequest = key }
        }
        .onReceive(NotificationCenter.default.publisher(for: .booruClientValidated)) { if let id = $0.object as? String, servers.contains(where: { $0.id == id }) { retry += 1 } }
        .task(id: "\(searchFocused):\(searchText)") { await complete() }
    }
    private var requestKey: String { query + "|\(sort.rawValue)|\(rating.rawValue)|\(retry)|" + servers.map { $0.id + $0.canonicalAddress }.joined(separator: ",") }
    private var filters: some View {
        HStack {
            Menu {
                Picker(L10n.text("Sort"), selection: $sort) {
                    ForEach(BooruSort.allCases) { Text($0.title).tag($0) }
                }
            } label: { Label(sort.title, systemImage: "arrow.up.arrow.down").font(.subheadline.weight(.medium)) }
                .accessibilityIdentifier("booru.sort")
            Spacer()
            if BooruRating.options(for: servers).count > 1 {
                Menu {
                    Picker(L10n.text("Rating"), selection: $rating) {
                        ForEach(BooruRating.options(for: servers)) { Text($0.title).tag($0) }
                    }
                } label: { Label(rating.title, systemImage: "line.3.horizontal.decrease").font(.subheadline.weight(.medium)) }
                    .accessibilityLabel(L10n.text("Rating") + ": " + rating.title).accessibilityIdentifier("booru.rating")
            }
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
                }.listStyle(.plain).frame(height: 260)

            } else {
                ForEach(suggestions) { tag in
                    Button {
                        if let completion = BooruCompletion(searchText) { searchText = completion.inserting(tag.name) }
                    } label: {
                        HStack {
                            Image(systemName: tag.isArtist ? "person" : "number")
                            Text(tag.name).lineLimit(1)
                            Spacer()
                            Text(tag.count.formatted()).font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 10).contentShape(Rectangle())
                    }.accessibilityIdentifier("booru.suggestion.\(tag.name)")
                }
                if let suggestionError { Text(suggestionError).font(.caption).foregroundStyle(.secondary) }
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
        if rememberHistory { store.perform {
            for server in servers { try store.recordSearch(value, serverID: server.id) }
            try store.recordTasteSearch(DiscoveryContext(origin: .search, query: value, session: tasteSession), servers: servers)
        } }
        if query == value { retry += 1 } else { query = value }
    }
    private func load(reset: Bool) async { await loader.load(servers: servers, source: source, query: query, poolID: pool?.id, sort: sort, rating: rating, reset: reset) }
    private func complete() async {
        suggestions = []; suggestionError = nil
        guard searchFocused, let completion = BooruCompletion(searchText) else { return }
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
    let open: (BooruPost) -> Void
    @Environment(BooruStore.self) private var store
    @Environment(AppEnvironment.self) private var env
    @State private var filing: BooruPost?
    var body: some View {
        let favorites = store.favoriteIDs
        return LazyVGrid(columns: WorkGridLayout.columns(env.gridColumns), spacing: 12) {
            ForEach(posts) { post in
                if let server = store.servers.first(where: { $0.id == post.serverID }) ?? server {
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
                                .accessibilityAction(named: L10n.text("Add Favorite")) { save(post) }
                        } else {
                            Button { open(post) } label: { thumbnail(post, server: server, isFavorite: favorites.contains(post.id)) }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button(L10n.text(store.isFavorite(post) ? "Remove Favorite" : "Add Favorite"), systemImage: "heart") { store.perform { try store.toggleFavorite(post, context: discovery) } }
                                    Button(L10n.text("Save to Folder"), systemImage: "folder") { filing = post }
                                    ShareLink(item: server.pageURL(postID: post.postID))
                                }
                        }
                    }
                    .id(post.id)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(server.displayName + " · " + String(post.postID))
                    .accessibilityIdentifier("booru.post.\(post.postID)")
                    .accessibilityValue(selection.map { $0.wrappedValue.contains(post.id) ? L10n.text("Selected") : "" } ?? (showsFavoriteIndicator && favorites.contains(post.id) ? L10n.text("Saved") : ""))
                }
            }
        }.sheet(item: $filing) { BooruFolderPicker(post: $0).environment(\.discoveryContext, discovery) }
    }

    private func thumbnail(_ post: BooruPost, server: BooruServer, isFavorite: Bool) -> some View {
        BooruPostThumbnailCard(post: post, server: server, showsFavoriteIndicator: showsFavoriteIndicator, isFavorite: isFavorite)
    }

    private func save(_ post: BooruPost) {
        store.perform {
            try store.toggleFavorite(post, context: discovery)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }
}

struct BooruPostThumbnailCard: View {
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
