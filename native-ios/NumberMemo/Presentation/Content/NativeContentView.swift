import SwiftUI
import GRDB

/// One entry point for library links and Explore, including the website fallback.
struct ContentEntryView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    var initialUrl: String = MangaUrls.home
    var embedded = false
    var body: some View {
        if !env.isSiteVerified {
            NavigationStack {
                ComicsSetupView()
                    .toolbar {
                        if !embedded {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button(L10n.text("Close"), systemImage: "xmark") { dismiss() }
                                    .labelStyle(.iconOnly).accessibilityIdentifier("content.close")
                            }
                        }
                    }
            }
        } else if env.useEmbeddedBrowser {
            if embedded {
                NavigationStack { InAppMangaBrowserView(initialUrl: initialUrl, embedded: true).appRootHeader("Explore") }
            } else { InAppMangaBrowserView(initialUrl: initialUrl, embedded: false) }
        } else {
            #if DEBUG
            if ContentUITestSupport.enabled {
                NativeContentView(initialUrl: initialUrl, source: ContentUITestSupport.source, savesProgress: false, embedded: embedded,
                                  images: env.launchFeeds.images, startup: ProcessInfo.processInfo.arguments.contains("--launch-warmup-test") ? env.launchFeeds : nil)
            } else {
                NativeContentView(initialUrl: initialUrl, source: env.launchFeeds.manga, embedded: embedded,
                                  images: env.launchFeeds.images, startup: env.launchFeeds)
            }
            #else
            NativeContentView(initialUrl: initialUrl, source: env.launchFeeds.manga, embedded: embedded,
                              images: env.launchFeeds.images, startup: env.launchFeeds)
            #endif
        }
    }

}

/// The native content view. It renders data directly and never creates a web view.
public struct NativeContentView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppEnvironment.self) private var env
    private let embedded: Bool
    private let initialRoute: ContentRoute?
    private let source: any ContentProviding
    private let savesProgress: Bool
    private let startup: LaunchFeedWarmup?
    @State private var images: PageImageStore
    @State private var path: [ContentRoute] = []
    @State private var presentedGallery: GalleryDestination?
    private struct GalleryDestination: Identifiable {
        let id: Int64
        let context: DiscoveryContext
    }
    @State private var presentedReader: ReaderDestination?
    @State private var readerSearch: String?
    private struct ReaderDestination: Identifiable {
        let id: Int64
        let page: Int
        let context: DiscoveryContext
    }
    private func openReader(_ id: Int64, _ page: Int, _ context: DiscoveryContext) {
        presentedReader = ReaderDestination(id: id, page: page, context: context)
    }
    private func navigate(_ route: ContentRoute) {
        switch route {
        case .gallery(let id): presentedGallery = GalleryDestination(id: id, context: .unknown)
        case .discoveredGallery(let id, let context): presentedGallery = GalleryDestination(id: id, context: context)
        case .reader(let id, let page): openReader(id, page, .unknown)
        case .discoveredReader(let id, let page, let context): openReader(id, page, context)
        default: path.append(route)
        }
    }

    public init(initialUrl: String = MangaUrls.home, embedded: Bool = false) {
        self.init(initialUrl: initialUrl, source: MangaContentSource.shared, embedded: embedded)
    }

    init(initialUrl: String = MangaUrls.home, source: any ContentProviding, savesProgress: Bool = true, embedded: Bool = false, initialQuery: String? = nil, images: PageImageStore? = nil, startup: LaunchFeedWarmup? = nil) {
        self.embedded = embedded
        initialRoute = initialQuery.map(ContentRoute.query) ?? ContentRoute.initial(initialUrl)
        self.source = source
        self.savesProgress = savesProgress
        self.startup = startup
        _images = State(initialValue: images ?? PageImageStore(source: source))
    }

    public var body: some View {
        NavigationStack(path: $path) {
            root
                .navigationDestination(for: ContentRoute.self) { route in destination(route) }
                .toolbar {
                    if embedded { ToolbarItem(placement: .principal) { AppModeSwitch() } }
                    if !embedded { ToolbarItem(placement: .topBarTrailing) {
                        Button(L10n.text("Close"), systemImage: "xmark") { dismiss() }
                            .labelStyle(.iconOnly)
                            .accessibilityIdentifier("content.close")
                    } }
                }
        }
        .sheet(item: $presentedGallery) { gallery in
            NativeContentView(initialUrl: MangaUrls.galleryUrl(for: gallery.id), source: source,
                              savesProgress: savesProgress, images: images)
                .environment(\.discoveryContext, gallery.context)
                .presentationDetents([.large]).presentationDragIndicator(.visible)
        }
        .fullScreenCover(item: $presentedReader, onDismiss: {
            if let readerSearch { self.readerSearch = nil; path.append(.query(readerSearch)) }
        }) { reader in
            NativeReaderView(galleryID: reader.id, initialPage: reader.page, source: source, images: images,
                             savesProgress: savesProgress, search: { text in readerSearch = text; presentedReader = nil },
                             exit: { presentedReader = nil })
                .environment(\.discoveryContext, reader.context)
        }
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder private var root: some View {
        if embedded && savesProgress && !env.isSiteVerified {
            ContentUnavailableView(L10n.text("Connect a Website"), systemImage: "globe", description: Text(L10n.text("Connect the website address in Settings.")))
                .navigationTitle("").navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.hidden, for: .navigationBar)
                .toolbar { ToolbarItem(placement: .topBarLeading) { LiquidGlassTitleCapsule(L10n.text("Explore")) } }
        } else if let initialRoute { destination(initialRoute) }
        else { GalleryFeedView(source: source, images: images, startup: startup, navigate: navigate) }
    }

    @ViewBuilder private func destination(_ route: ContentRoute) -> some View {
        switch route {
        case .discoveredGallery(let id, let context):
            RemoteGalleryView(galleryID: id, source: source, images: images, read: openReader).environment(\.discoveryContext, context)
        case .discoveredReader(let id, let page, let context):
            NativeReaderView(galleryID: id, initialPage: page, source: source, images: images, savesProgress: savesProgress, search: { text in
                if !path.isEmpty { path.removeLast() }; path.append(.query(text))
            }, exit: { if path.isEmpty { dismiss() } else { path.removeLast() } }).environment(\.discoveryContext, context)
        case .reader(let id, let page):
            NativeReaderView(galleryID: id, initialPage: page, source: source, images: images, savesProgress: savesProgress, search: { text in
                if !path.isEmpty { path.removeLast() }
                path.append(.query(text))
            }, exit: { if path.isEmpty { dismiss() } else { path.removeLast() } })
        case .gallery(let id):
            RemoteGalleryView(galleryID: id, source: source, images: images, read: openReader)
        case .artist(let name):
            GalleryFeedView(artist: name, source: source, images: images, navigate: navigate)
        case .query(let text):
            GalleryFeedView(initialQuery: text, source: source, images: images, navigate: navigate)
        }
    }
}

struct ContentFailureView: View {
    let message: String
    let retry: () -> Void
    var body: some View {
        ContentUnavailableView {
            Label(L10n.text("Unable to Load"), systemImage: "wifi.exclamationmark")
        } description: {
            Text(message)
        } actions: {
            Button(L10n.text("Try Again"), action: retry).buttonStyle(.borderedProminent)
                .accessibilityIdentifier("content.retry")
        }
    }
}

private struct ContentBookmark: Identifiable {
    let id: Int64
}

private struct GalleryFeedView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var isVisible = false
    @Environment(\.discoveryContext) private var inheritedContext
    @State private var tasteSession = UUID().uuidString
    @State private var submitted = false
    private var discovery: DiscoveryContext {
        DiscoveryContext(origin: !submitted && inheritedContext.origin == .recommendation ? .recommendation : query.text.isEmpty ? .feed : .search, query: query.text, defaults: env.defaultTags + " " + env.defaultExcludedTags, session: tasteSession)
    }
    @Environment(AppEnvironment.self) private var env
    @State private var toast: String?
    @State private var saveFeedback: WorkSaveFeedback?
    let artist: String?
    let source: any ContentProviding
    let images: PageImageStore
    let navigate: (ContentRoute) -> Void
    @State private var query: GalleryQuery
    @State private var searchText: String
    @State private var isSearchBarVisible = true
    @FocusState private var isSearchFocused: Bool
    @State private var suggestions: [TagSuggestion] = []
    @State private var suggesting = false
    @State private var searchScroll = ScrollSearchVisibility()
    @State private var paginationViewport = GalleryPaginationViewport()
    @State private var footerVisible = false
    @State private var bookmarkedIDs = Set<Int64>()
    @State private var history: [String] = []
    @State private var savedSearches: [String] = []
    @State private var loadedQuery: GalleryQuery?
    @State private var loadedSite: String?
    private struct InitialRequest: Hashable { let query: GalleryQuery; let site: String }
    @State private var loader: GalleryFeedLoader

    init(artist: String? = nil, initialQuery: String = "", source: any ContentProviding, images: PageImageStore, startup: LaunchFeedWarmup? = nil, navigate: @escaping (ContentRoute) -> Void) {
        self.artist = artist
        self.source = source
        self.images = images
        _loader = State(initialValue: GalleryFeedLoader(source: source, images: images, startup: startup))
        self.navigate = navigate
        _query = State(initialValue: GalleryQuery(language: artist == nil && initialQuery.isEmpty ? L10n.contentLanguage : "all", artist: artist, text: initialQuery))
        _searchText = State(initialValue: initialQuery)
    }

    private var effectiveQuery: GalleryQuery {
        query.applyingDefaults(tags: env.defaultTags, excluded: env.defaultExcludedTags)
    }

    private var isActive: Bool { env.mode == .manga && scenePhase == .active }

    var body: some View {
        ZStack(alignment: .top) {
        ScrollView {
            LazyVStack(spacing: 16) {
                HStack {
                BrowseFilterMenu(title: L10n.text(query.language.capitalized), icon: "globe") {
                Picker(L10n.text("Language"), selection: $query.language) {
                    Text(L10n.text("Korean")).tag("korean")
                    Text(L10n.text("Japanese")).tag("japanese")
                    Text(L10n.text("English")).tag("english")
                    Text(L10n.text("All")).tag("all")
                }
                }.accessibilityIdentifier("content.language")
                Spacer()
                BrowseFilterMenu(title: query.sort.title, icon: "arrow.up.arrow.down") {
                Picker(L10n.text("Sort"), selection: $query.sort) {
                    ForEach(GallerySort.allCases) { Text($0.title).tag($0) }
                }
                }.accessibilityIdentifier("content.sort")
                }
                LazyVGrid(columns: WorkGridLayout.columns(env.gridColumns), spacing: 16) {
                    let prefetchColumns = env.gridColumns > 0 ? env.gridColumns : 2
                    let lookahead = prefetchColumns * 2
                    let prefetchThresholdIndex = max(0, loader.ids.count - lookahead)
                    ForEach(Array(loader.ids.enumerated()), id: \.element) { index, id in
                        GalleryGridCard(id: id, preview: loader.previews[id], isBookmarked: bookmarkedIDs.contains(id), source: source, images: images, open: { navigate(.discoveredGallery(id, discovery)) }) { gallery in
                            saveFeedback = .perform { try ContentBookmarkAction.toggle(id: id, gallery: gallery, env: env, images: images, context: discovery) }
                        }
                        .onAppear {
                            if index.isMultiple(of: prefetchColumns) {
                                loader.prioritizeCovers(startingAt: index, count: lookahead)
                            }
                            if index >= prefetchThresholdIndex && loader.hasMore && !loader.loading && loader.error == nil {
                                loader.load(effectiveQuery, reset: false)
                            }
                        }
                    }
                }.accessibilityIdentifier("content.grid")
                // Keep one lazy footer alive across loading changes. Recreating
                // a non-lazy button here starts another page as soon as each request ends.
                VStack {
                    if loader.loading { ProgressView(L10n.text("Loading")).accessibilityIdentifier("content.loading") }
                    else if let error = loader.error { ContentFailureView(message: error) { loader.retry(effectiveQuery) } }
                    else if loader.ids.isEmpty { ContentUnavailableView.search(text: query.text) }
                    else if loader.hasMore {
                        Button(L10n.text("Load More")) { loader.load(effectiveQuery, reset: false) }
                            .frame(maxWidth: .infinity).accessibilityIdentifier("content.more")
                    }
                }.onGeometryChange(for: CGRect.self) { proxy in
                    proxy.frame(in: .named("gallery.feedViewport"))
                } action: { frame in
                    paginationViewport.footer = frame
                    updateFooterVisibility()
                }
            }.padding(16).padding(.top, 56)
        }
        .coordinateSpace(name: "gallery.feedViewport")
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            paginationViewport.height = height
            updateFooterVisibility()
        }
        .scrollDismissesKeyboard(.interactively)
        .trackScrollGeometry { oldY, newY in
            if let visible = searchScroll.update(oldY: oldY, newY: newY, focused: isSearchFocused) {
                isSearchBarVisible = visible
            }
        }
        VStack(spacing: 0) {
            ScrollSearchBar(text: $searchText, focused: $isSearchFocused, prompt: L10n.text("Search, number, or link"), identifier: "content.search", submit: submitSearch)
            if isSearchFocused && searchText.isEmpty {
                List {
                    SearchHistorySection(history: history, saved: savedSearches, open: { searchText = $0; submitSearch() }, star: { query in
                        do { try env.database.toggleSavedSearch(query); reloadSearches() } catch { toast = error.localizedDescription }
                    }, remove: { query in
                        do { try env.database.deleteSearch(query); reloadSearches() } catch { toast = error.localizedDescription }
                    }, clear: {
                        do { try env.database.clearSearchHistory(); reloadSearches() } catch { toast = error.localizedDescription }
                    })
                    if !savedSearches.isEmpty {
                        Section(L10n.text("Saved Searches")) {
                            ForEach(savedSearches, id: \.self) { value in
                                Button { searchText = value; submitSearch() } label: { Label(value, systemImage: "star.fill") }
                                    .swipeActions { Button(L10n.text("Remove"), role: .destructive) { try? env.database.toggleSavedSearch(value); reloadSearches() } }
                            }
                        }
                    }
                }.listStyle(.plain).scrollContentBackground(.hidden).searchResultsPanel(height: 260)
            } else if isSearchFocused, !suggestions.isEmpty {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(suggestions) { item in
                            Button {
                                guard let context = TagCompletionContext(searchText) else { return }
                                searchText = context.inserting(item)
                                suggestions = []
                            } label: {
                                HStack(spacing: 8) {
                                    Text(item.namespace).font(.caption.monospaced()).foregroundStyle(.secondary)
                                    Text(item.name).font(.subheadline).foregroundStyle(.primary).lineLimit(1)
                                    Spacer(minLength: 4)
                                    Text(item.count.formatted()).font(.caption).foregroundStyle(.secondary)
                                }.frame(minHeight: 46).padding(.horizontal, 12).contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityIdentifier("content.suggestion.\(item.token)")
                            if item.id != suggestions.last?.id { Divider() }
                        }
                    }
                }.searchResultsPanel(height: min(280, CGFloat(suggestions.count) * 47))
            } else if isSearchFocused && suggesting {
                ProgressView().frame(maxWidth: .infinity).searchResultsPanel(height: 60)
                    .accessibilityLabel(L10n.text("Finding tags"))
            }
        }
        .offset(y: isSearchBarVisible ? 0 : -60).opacity(isSearchBarVisible ? 1 : 0)
        .allowsHitTesting(isSearchBarVisible).accessibilityHidden(!isSearchBarVisible)
        }
        .animation(isSearchBarVisible ? .spring(response: 0.35, dampingFraction: 0.86) : .easeInOut(duration: 0.32), value: isSearchBarVisible)
        .onChange(of: isSearchFocused) { _, focused in if focused { isSearchBarVisible = true; reloadSearches() } }
        .task(id: "\(isSearchFocused):\(searchText)") {
            suggestions = []; suggesting = false
            guard isSearchFocused, let context = TagCompletionContext(searchText) else { return }
            do {
                try await Task.sleep(for: .milliseconds(300))
                suggesting = true
                let result = try await source.suggestions(for: context.token)
                try Task.checkCancellation()
                suggestions = Array(result.prefix(8)); suggesting = false
            } catch { if !Task.isCancelled { suggesting = false } }
        }
        .overlay(alignment: .bottom) {
            if let toast { Text(toast).font(.subheadline.bold()).padding(14).background(.regularMaterial, in: Capsule()).padding().accessibilityIdentifier("content.toast") }
        }
        .workSaveFeedback($saveFeedback, identifier: "content.toast")
        .task(id: toast) {
            guard toast != nil else { return }
            do { try await Task.sleep(for: .seconds(2)); toast = nil } catch {}
        }
        .navigationTitle("")
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar { ToolbarItem(placement: .topBarLeading) {
            LiquidGlassTitleCapsule(artist ?? (query.text.isEmpty ? L10n.text("Explore") : L10n.text("Search Results")))
        } }
        .navigationBarTitleDisplayMode(.inline)
        .task(id: isActive) {
            guard isActive else { return }
            do {
                let observation = ValueObservation.tracking { db in
                    Set(try Int64.fetchAll(db, sql: "SELECT gallery_id FROM works"))
                }
                for try await ids in observation.values(in: env.database.dbWriter) { bookmarkedIDs = ids }
            } catch { /* Preserve the last known bookmark state if observation is interrupted. */ }
        }
        .task(id: InitialRequest(query: effectiveQuery, site: env.mangaSiteAddress)) {
            guard isActive else { return }
            loader.resume()
            guard loadedQuery != effectiveQuery || loadedSite != env.mangaSiteAddress || (!loader.didLoad && !loader.loading) else { return }
            let initial = !loader.didLoad && (loadedQuery == nil || loadedQuery == effectiveQuery) && (loadedSite == nil || loadedSite == env.mangaSiteAddress)
            loadedQuery = effectiveQuery
            loadedSite = env.mangaSiteAddress
            await loader.load(effectiveQuery, reset: true, useLaunchPage: initial, site: env.mangaSiteAddress).value
        }
        .task(id: "\(footerVisible):\(loader.loading):\(loader.ids.count):\(isActive):\(isVisible)") {
            guard footerVisible, isActive, isVisible, !loader.loading, loader.hasMore, loader.error == nil else { return }
            // Give appended rows time to move the footer below the viewport.
            // Recheck after refresh/resume even when the first IDs stay unchanged.
            do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
            guard footerVisible, isActive, isVisible, !loader.loading, loader.hasMore, loader.error == nil else { return }
            loader.load(effectiveQuery, reset: false)
        }
        .onAppear {
            isVisible = true
            if isActive { resumeFeed() } else { loader.suspend() }
        }
        .onDisappear { isVisible = false; loader.suspend() }
        .onChange(of: isActive) { _, active in
            guard isVisible else { return }
            if active { resumeFeed() } else { loader.suspend() }
        }
        .refreshable {
            let text = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            if query.text != text { query.text = text }
            else { await loader.load(effectiveQuery, reset: true).value }
        }
    }

    private func resumeFeed() {
        loader.resume()
        if (loadedQuery != effectiveQuery || loadedSite != env.mangaSiteAddress || !loader.didLoad) && !loader.loading {
            let initial = !loader.didLoad && (loadedQuery == nil || loadedQuery == effectiveQuery) && (loadedSite == nil || loadedSite == env.mangaSiteAddress)
            loadedQuery = effectiveQuery
            loadedSite = env.mangaSiteAddress
            loader.load(effectiveQuery, reset: true, useLaunchPage: initial, site: env.mangaSiteAddress)
        }
    }

    private func updateFooterVisibility() {
        let visible = paginationViewport.footer.map { $0.maxY > 0 && $0.minY < paginationViewport.height } ?? false
        if footerVisible != visible { footerVisible = visible }
    }

    private func submitSearch() {
        isSearchFocused = false
        suggestions = []
        submitted = true; tasteSession = UUID().uuidString
        let text = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if ReaderPreferences.defaults.object(forKey: "search.rememberHistory") as? Bool ?? true {
            try? env.database.recordSearch(text)
            try? env.database.recordTasteSearch(DiscoveryContext(origin: .search, query: text, defaults: env.defaultTags + " " + env.defaultExcludedTags, session: tasteSession))
        }
        reloadSearches()
        if let route = ContentRoute.initial(text) { navigate(route) }
        else if !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }), let id = Int64(text), id > 0 { navigate(.gallery(id)) }
        else {
            if query.text == text { loader.load(effectiveQuery, reset: true) }
            else { query.text = text }
        }
    }
    private func reloadSearches() {
        history = (try? env.database.searchHistory()) ?? []
        savedSearches = (try? env.database.savedSearches()) ?? []
    }

}

private final class GalleryPaginationViewport {
    var footer: CGRect?
    var height: CGFloat = 0
}
private struct GalleryGridCard: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.scenePhase) private var scenePhase
    private struct LoadKey: Hashable { let preview: ObjectIdentifier?; let active: Bool }
    let id: Int64
    let isBookmarked: Bool
    let open: () -> Void
    let bookmark: (NativeGallery?) -> Void
    private let suppliedPreview: GalleryFeedPreview?
    @State private var preview: GalleryFeedPreview
    private var gallery: NativeGallery? { preview.gallery }
    private var image: UIImage? { preview.image }

    init(id: Int64, preview: GalleryFeedPreview?, isBookmarked: Bool, source: any ContentProviding, images: PageImageStore, open: @escaping () -> Void, bookmark: @escaping (NativeGallery?) -> Void) {
        self.id = id
        self.isBookmarked = isBookmarked
        self.suppliedPreview = preview
        self.open = open
        self.bookmark = bookmark
        _preview = State(initialValue: preview ?? GalleryFeedPreview(id: id, source: source, images: images))
    }

    var body: some View {
        GalleryCardLayout(title: gallery?.title ?? L10n.text("Work %@", String(describing: id)), artists: gallery?.artists.joined(separator: ", ") ?? "", language: gallery?.language ?? "") {
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else { Rectangle().fill(Color.secondary.opacity(0.12)).overlay { Image(systemName: "book.closed").foregroundStyle(.secondary) } }
        }
        .overlay(alignment: .topLeading) {
            if isBookmarked {
                Image(systemName: "bookmark.fill").font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.yellow).padding(8).background(.black.opacity(0.72), in: Circle())
                    .padding(7).accessibilityHidden(true).allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onLongPressGesture(minimumDuration: 0.55) { bookmark(gallery) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("content.gallery.\(id)")
        .accessibilityValue(isBookmarked ? L10n.text("Bookmarked") : L10n.text("Not bookmarked"))
        .accessibilityAction { open() }
        .accessibilityAction(named: WorkSaveResult.actionTitle(saved: isBookmarked, mode: .comics)) { bookmark(gallery) }
        .task(id: LoadKey(preview: suppliedPreview.map(ObjectIdentifier.init), active: env.mode == .manga && scenePhase == .active)) {
            guard env.mode == .manga, scenePhase == .active else { return }
            if let suppliedPreview { preview = suppliedPreview }
            await preview.load()
        }
        .onDisappear { preview.discardDisplayContent() }
    }
}

private struct RemoteGalleryView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.discoveryContext) private var discovery
    let galleryID: Int64
    let source: any ContentProviding
    let images: PageImageStore
    @State private var gallery: NativeGallery?
    @State private var cover: UIImage?
    @State private var coverFinished = false
    @State private var error: String?
    @State private var retry = 0
    @State private var bookmark: ContentBookmark?
    var read: (Int64, Int, DiscoveryContext) -> Void

    var body: some View {
        Group {
            if let gallery {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        WorkDetailCover(image: cover, loading: !coverFinished)
                        Text(gallery.title).font(.title2.bold()).textSelection(.enabled).accessibilityIdentifier("content.detail.title")
                        Text(L10n.text("%@ · %@ · %@ pages", String(describing: gallery.language), String(describing: gallery.type), String(describing: gallery.pages.count)))
                            .font(.subheadline).foregroundStyle(.secondary)
                        Button { read(galleryID, 1, discovery) } label: {
                            Label(L10n.text("Read"), systemImage: "book.pages").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8)
                        }.buttonStyle(.borderedProminent).accessibilityIdentifier("content.read")
                        Button { bookmark = ContentBookmark(id: galleryID) } label: {
                            Label(L10n.text("Save to Library"), systemImage: "bookmark").frame(maxWidth: .infinity)
                        }.buttonStyle(.bordered).accessibilityIdentifier("content.bookmark")
                        if !gallery.artists.isEmpty {
                            Text(L10n.text("Artists")).font(.headline)
                            ForEach(gallery.artists, id: \.self) { name in
                                NavigationLink(name, value: ContentRoute.artist(name)).buttonStyle(.bordered)
                            }
                        }
                        NavigationLink(gallery.language, value: ContentRoute.query("language:" + gallery.language))
                            .buttonStyle(.bordered)
                        if !gallery.tags.isEmpty {
                            Text(L10n.text("Tags")).font(.headline)
                            FlowLayout(spacing: 8) {
                                ForEach(Array(Set(gallery.tags)).sorted(), id: \.self) { tag in
                                    NavigationLink(value: ContentRoute.query(tag.replacingOccurrences(of: " ", with: "_"))) {
                                        Text(tag).font(.caption).padding(.horizontal, 10).padding(.vertical, 7)
                                            .background(.quaternary, in: Capsule())
                                    }
                                }
                            }
                        }
                    }.padding(20)
                }
            } else if let error { ContentFailureView(message: error) { retry += 1 } }
            else { ProgressView(L10n.text("Loading work details")) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground).ignoresSafeArea())
        .toolbar(.visible, for: .navigationBar)
        .navigationTitle(L10n.text("Work Details"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $bookmark) { target in AddWorkSheet(initialText: String(target.id)).environment(\.discoveryContext, discovery) }
        .task(id: retry) {
            error = nil
            do {
                let value = try await source.gallery(galleryID)
                try Task.checkCancellation()
                gallery = value
                try? env.database.observeTaste(value, context: discovery)
                if let page = value.pages.first {
                    let loaded = try? await images.load(page, galleryID: galleryID, thumbnail: true)
                    try Task.checkCancellation()
                    cover = loaded
                }
                coverFinished = true
            } catch { if !Task.isCancelled { self.error = ContentError.message(error) } }
        }
    }
}

/// One observable cover per card: prefetch and visible cells share the same request and updates.
@MainActor @Observable
final class GalleryFeedPreview {
    let id: Int64
    private(set) var gallery: NativeGallery?
    private(set) var image: UIImage?
    @ObservationIgnored private let source: any ContentProviding
    @ObservationIgnored private let images: PageImageStore
    @ObservationIgnored private var request: Task<Void, Never>?
    @ObservationIgnored private var requestID = UUID()
    @ObservationIgnored private var waiters = Set<UUID>()
    @ObservationIgnored private var cancelled = false

    init(id: Int64, source: any ContentProviding, images: PageImageStore) {
        self.id = id
        self.source = source
        self.images = images
        gallery = source.cachedGallery(id)
        image = gallery?.pages.first.flatMap { images.cachedImage(hash: $0.hash, thumbnail: true) }
    }

    func load() async {
        guard !cancelled, !Task.isCancelled else { return }
        guard image == nil else { return }
        let waiter = UUID()
        waiters.insert(waiter)
        let request = request ?? makeRequest()
        await withTaskCancellationHandler {
            defer { release(waiter) }
            await request.value
        } onCancel: {
            Task { @MainActor [weak self] in self?.release(waiter) }
        }
    }

    private func makeRequest() -> Task<Void, Never> {
        let token = UUID()
        requestID = token
        let request = Task { [weak self] in
            guard let self else { return }
            defer { if self.requestID == token { self.request = nil } }
            do {
                let gallery: NativeGallery
                if let cached = self.gallery { gallery = cached }
                else { gallery = try await source.gallery(id) }
                try Task.checkCancellation()
                self.gallery = gallery
                if let page = gallery.pages.first {
                    let image = try await images.load(page, galleryID: id, thumbnail: true)
                    try Task.checkCancellation()
                    self.image = image
                }
            } catch { /* Keep metadata usable when a cover fails; detail provides an explicit retry. */ }
        }
        self.request = request
        return request
    }

    private func release(_ waiter: UUID) {
        guard waiters.remove(waiter) != nil else { return }
        // A visible cell and speculative lookahead can share a request. Stop it
        // only after both have left, including when SwiftUI cancels a lazy cell.
        if waiters.isEmpty { pause() }
    }

    func pause() {
        request?.cancel(); request = nil; requestID = UUID()
        waiters.removeAll()
    }

    func discardDisplayContent() {
        pause()
        // Lazy cell state can outlive its onscreen view. Keep decoded images
        // and full gallery documents in the bounded caches, not every old row.
        image = nil
        gallery = nil
    }

    func cancel() { cancelled = true; pause() }
}

/// Pagination completes as soon as IDs arrive. Cover prefetch never holds up the next page.
@MainActor @Observable
final class GalleryFeedLoader {
    private let source: any ContentProviding
    private let images: PageImageStore?
    private let startup: LaunchFeedWarmup?
    private var task: Task<Void, Never>?
    private(set) var previews: [Int64: GalleryFeedPreview] = [:]
    private struct CoverFlight { let token: UUID; let task: Task<Void, Never> }
    @ObservationIgnored private var prefetchTasks: [Int64: CoverFlight] = [:]
    @ObservationIgnored private var prefetchQueue: [Int64] = []
    @ObservationIgnored private var prefetchWindow: [Int64] = []
    @ObservationIgnored private var suspended = false
    private var generation = UUID()
    private var nextOffset = 0
    private var currentQuery: GalleryQuery?
    private var currentSite: String?
    private var lastReset = true
    private(set) var ids: [Int64] = []
    private(set) var didLoad = false
    private(set) var loading = false
    private(set) var hasMore = false
    private(set) var error: String?

    init(source: any ContentProviding, images: PageImageStore? = nil, startup: LaunchFeedWarmup? = nil) {
        self.source = source
        self.images = images
        self.startup = startup
    }

    /// Only the rows near the viewport merit speculation. Never drain a whole
    /// page of full gallery documents and covers just because its IDs arrived.
    func prioritizeCovers(startingAt index: Int, count: Int) {
        guard !suspended, ids.indices.contains(index), count > 0 else { return }
        let end = index + min(count, ids.count - index)
        prefetchWindow = Array(ids[index..<end])
        let priority = Set(prefetchWindow)
        for (id, flight) in prefetchTasks where !priority.contains(id) { flight.task.cancel() }
        prefetchQueue = prefetchWindow.filter { previews[$0]?.image == nil && previews[$0] != nil }
        startPrefetch()
    }

    private func startPrefetch() {
        guard !suspended, CoverQueuePolicy.allowsBackfill else { return }
        while prefetchTasks.count < 2,
              let index = prefetchQueue.firstIndex(where: { prefetchTasks[$0] == nil }) {
            let id = prefetchQueue.remove(at: index)
            guard let preview = previews[id], preview.image == nil else { continue }
            let token = UUID()
            let task = Task(priority: .utility) { [weak self] in
                await preview.load()
                guard let self, self.prefetchTasks[id]?.token == token else { return }
                self.prefetchTasks.removeValue(forKey: id)
                self.startPrefetch()
            }
            prefetchTasks[id] = CoverFlight(token: token, task: task)
        }
    }

    private func stopPrefetch(cancelCovers: Bool) {
        // Canceled work retains its slot until it actually finishes.
        for flight in prefetchTasks.values { flight.task.cancel() }
        prefetchQueue.removeAll()
        if cancelCovers { for preview in previews.values { preview.cancel() } }
    }

    @discardableResult func load(_ query: GalleryQuery, reset: Bool, useLaunchPage: Bool = false, site: String? = nil) -> Task<Void, Never> {
        guard !suspended else { return Task {} }
        let site = site ?? currentSite ?? MangaUrls.configuredHost
        if !reset, loading, currentQuery == query, let task { return task }
        task?.cancel()
        let changedQuery = currentQuery != query || currentSite != site
        if changedQuery {
            stopPrefetch(cancelCovers: true)
            prefetchWindow.removeAll()
            ids = []; nextOffset = 0; hasMore = false; previews.removeAll(); didLoad = false
        }
        currentQuery = query
        currentSite = site
        let reset = reset || changedQuery
        lastReset = reset
        let token = UUID()
        generation = token
        loading = true
        error = nil
        let offset = reset ? 0 : nextOffset
        let source = source
        let startup = startup
        let request = Task { [weak self] in
            do {
                let batch: GalleryBatch
                if reset, useLaunchPage, let startup {
                    batch = try await startup.mangaPage(query: query, site: site, initialConsumer: true)
                } else {
                    if reset, let startup { await startup.invalidateManga(query: query, site: site) }
                    try Task.checkCancellation()
                    batch = try await source.list(query, offset: offset, count: 24)
                }
                try Task.checkCancellation()
                guard let self, self.generation == token else { return }
                var seen = Set(reset ? [] : self.ids)
                let incoming = batch.ids.filter { seen.insert($0).inserted }
                let updatedIDs = (reset ? [] : self.ids) + incoming
                if reset { self.stopPrefetch(cancelCovers: false) }
                // Retain only three pages of covers; lazy cells own any older covers still on screen.
                let retained = Set(updatedIDs.suffix(72))
                self.previews = (reset ? [:] : self.previews).filter { retained.contains($0.key) }
                if let images = self.images {
                    for id in incoming { self.previews[id] = GalleryFeedPreview(id: id, source: source, images: images) }
                }
                self.ids = updatedIDs
                self.didLoad = true
                if reset && useLaunchPage { startup?.didPublishManga(query: query, site: site) }
                self.nextOffset = offset + batch.ids.count
                self.hasMore = batch.hasMore && !batch.ids.isEmpty && (reset || !incoming.isEmpty)
                self.prefetchQueue = self.prefetchQueue.filter { retained.contains($0) }
                self.startPrefetch()
            } catch {
                if !Task.isCancelled, let self, self.generation == token { self.error = ContentError.message(error) }
            }
            if let self, self.generation == token { self.loading = false }
        }
        task = request
        return request
    }

    @discardableResult func retry(_ query: GalleryQuery) -> Task<Void, Never> { load(query, reset: lastReset) }

    /// Hidden tabs keep their results, but stop downloading and decoding covers.
    func suspend() {
        suspended = true
        task?.cancel(); generation = UUID(); loading = false
        stopPrefetch(cancelCovers: false)
        for preview in previews.values { preview.pause() }
    }

    func resume() {
        guard suspended else { return }
        suspended = false
        // Restore the small viewport window, never all retained pages.
        prefetchQueue = prefetchWindow.filter { previews[$0] != nil && previews[$0]?.image == nil }
        startPrefetch()
    }

    func cancel() {
        task?.cancel(); generation = UUID(); loading = false
        stopPrefetch(cancelCovers: true)
    }
}
