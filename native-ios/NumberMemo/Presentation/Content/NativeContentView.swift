import SwiftUI
import GRDB

/// One entry point for library links and Explore, including the website fallback.
struct ContentEntryView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    var initialUrl: String = HitomiUrls.home
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
                NavigationStack { InAppHitomiBrowserView(initialUrl: initialUrl, embedded: true).appRootHeader("Explore") }
            } else { InAppHitomiBrowserView(initialUrl: initialUrl, embedded: false) }
        } else {
            #if DEBUG
            if ContentUITestSupport.enabled {
                NativeContentView(initialUrl: initialUrl, source: ContentUITestSupport.source, savesProgress: false, embedded: embedded)
            } else { NativeContentView(initialUrl: initialUrl, embedded: embedded) }
            #else
            NativeContentView(initialUrl: initialUrl, embedded: embedded)
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
    @State private var images: PageImageStore
    @State private var path: [ContentRoute] = []

    public init(initialUrl: String = HitomiUrls.home, embedded: Bool = false) {
        self.init(initialUrl: initialUrl, source: HitomiContentSource.shared, embedded: embedded)
    }

    init(initialUrl: String = HitomiUrls.home, source: any ContentProviding, savesProgress: Bool = true, embedded: Bool = false) {
        self.embedded = embedded
        initialRoute = ContentRoute.initial(initialUrl)
        self.source = source
        self.savesProgress = savesProgress
        _images = State(initialValue: PageImageStore(source: source))
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
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder private var root: some View {
        if embedded && savesProgress && !env.isSiteVerified {
            ContentUnavailableView(L10n.text("Connect a Website"), systemImage: "globe", description: Text(L10n.text("Connect the website address in Settings.")))
                .navigationTitle("").navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.hidden, for: .navigationBar)
                .toolbar { ToolbarItem(placement: .topBarLeading) { LiquidGlassTitleCapsule(L10n.text("Explore")) } }
        } else if let initialRoute { destination(initialRoute) }
        else { GalleryFeedView(source: source, images: images, navigate: { path.append($0) }) }
    }

    @ViewBuilder private func destination(_ route: ContentRoute) -> some View {
        switch route {
        case .reader(let id, let page):
            NativeReaderView(galleryID: id, initialPage: page, source: source, images: images, savesProgress: savesProgress, search: { text in
                if !path.isEmpty { path.removeLast() }
                path.append(.query(text))
            }, exit: { if path.isEmpty { dismiss() } else { path.removeLast() } })
        case .gallery(let id):
            RemoteGalleryView(galleryID: id, source: source, images: images)
        case .artist(let name):
            GalleryFeedView(artist: name, source: source, images: images, navigate: { path.append($0) })
        case .query(let text):
            GalleryFeedView(initialQuery: text, source: source, images: images, navigate: { path.append($0) })
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
    @Environment(AppEnvironment.self) private var env
    @State private var toast: String?
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
    @State private var bookmarkedIDs = Set<Int64>()
    @State private var history: [String] = []
    @State private var savedSearches: [String] = []
    @State private var loadedQuery: GalleryQuery?
    @State private var loader: GalleryFeedLoader

    init(artist: String? = nil, initialQuery: String = "", source: any ContentProviding, images: PageImageStore, navigate: @escaping (ContentRoute) -> Void) {
        self.artist = artist
        self.source = source
        _loader = State(initialValue: GalleryFeedLoader(source: source))
        self.images = images
        self.navigate = navigate
        _query = State(initialValue: GalleryQuery(language: artist == nil && initialQuery.isEmpty ? L10n.contentLanguage : "all", artist: artist, text: initialQuery))
        _searchText = State(initialValue: initialQuery)
    }

    private var effectiveQuery: GalleryQuery {
        query.applyingDefaults(tags: env.defaultTags, excluded: env.defaultExcludedTags)
    }

    var body: some View {
        ZStack(alignment: .top) {
        ScrollView {
            VStack(spacing: 16) {
                HStack {
                Picker(L10n.text("Language"), selection: $query.language) {
                    Text(L10n.text("Korean")).tag("korean")
                    Text(L10n.text("Japanese")).tag("japanese")
                    Text(L10n.text("English")).tag("english")
                    Text(L10n.text("All")).tag("all")
                }.pickerStyle(.menu).accessibilityIdentifier("content.language")
                Spacer()
                Picker(L10n.text("Sort"), selection: $query.sort) {
                    ForEach(GallerySort.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.menu).accessibilityIdentifier("content.sort")
                }
                LazyVGrid(columns: WorkGridLayout.columns(env.gridColumns), spacing: 16) {
                    ForEach(loader.ids, id: \.self) { id in
                        GalleryGridCard(id: id, isBookmarked: bookmarkedIDs.contains(id), source: source, images: images, open: { navigate(.gallery(id)) }) { gallery in
                            do { toast = try ContentBookmarkAction.toggle(id: id, gallery: gallery, env: env, images: images) }
                            catch { toast = L10n.text("Unable to save. Please try again.") }
                        }
                    }
                }.accessibilityIdentifier("content.grid")
                if loader.loading { ProgressView(L10n.text("Loading")) }
                else if let error = loader.error { ContentFailureView(message: error) { loader.retry(effectiveQuery) } }
                else if loader.ids.isEmpty { ContentUnavailableView.search(text: query.text) }
                else if loader.hasMore {
                    Button(L10n.text("Load More")) { loader.load(effectiveQuery, reset: false) }.frame(maxWidth: .infinity).accessibilityIdentifier("content.more")
                }
            }.padding(16).padding(.top, 56)
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
                }.listStyle(.plain).frame(height: 260).clipShape(RoundedRectangle(cornerRadius: 16)).padding(.horizontal, 16)
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
                }.frame(height: min(280, CGFloat(suggestions.count) * 47))
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal, 16).shadow(color: .black.opacity(0.12), radius: 8, y: 4)
            } else if isSearchFocused && suggesting {
                ProgressView().padding(8).background(.regularMaterial, in: Capsule())
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
        .onChange(of: searchText) { _, value in if value.isEmpty { query.text = "" } }
        .task {
            do {
                let observation = ValueObservation.tracking { db in
                    Set(try Int64.fetchAll(db, sql: "SELECT gallery_id FROM works"))
                }
                for try await ids in observation.values(in: env.database.dbWriter) { bookmarkedIDs = ids }
            } catch { /* Preserve the last known bookmark state if observation is interrupted. */ }
        }
        .task(id: effectiveQuery) {
            guard loadedQuery != effectiveQuery else { return }
            loadedQuery = effectiveQuery
            await loader.load(effectiveQuery, reset: true).value
        }
        .refreshable {
            let text = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            if query.text != text { query.text = text }
            else { await loader.load(effectiveQuery, reset: true).value }
        }
    }

    private func submitSearch() {
        isSearchFocused = false
        suggestions = []
        let text = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if ReaderPreferences.defaults.object(forKey: "search.rememberHistory") as? Bool ?? true { try? env.database.recordSearch(text) }
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

private struct GalleryGridCard: View {
    let id: Int64
    let isBookmarked: Bool
    let source: any ContentProviding
    let images: PageImageStore
    let open: () -> Void
    let bookmark: (NativeGallery?) -> Void
    @State private var gallery: NativeGallery?
    @State private var image: UIImage?

    var body: some View {
        GalleryCardLayout(title: gallery?.title ?? L10n.text("Work %@", String(describing: id)), artists: gallery?.artists.joined(separator: ", ") ?? "", language: gallery?.language ?? "") {
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else { Rectangle().fill(Color.secondary.opacity(0.12)).overlay { Image(systemName: "book.closed").foregroundStyle(.secondary) } }
        }
        .overlay(alignment: .topLeading) {
            if isBookmarked {
                Image(systemName: "bookmark.fill").font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white).padding(8).background(.black.opacity(0.72), in: Circle())
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
        .accessibilityAction(named: L10n.text("Bookmark")) { bookmark(gallery) }
        .task(id: id) {
            do {
                let value = try await source.gallery(id)
                try Task.checkCancellation()
                gallery = value
                if let page = value.pages.first { image = try await images.load(page, galleryID: id, thumbnail: true) }
            } catch { /* The detail screen provides an explicit retry. */ }
        }
    }
}

private struct RemoteGalleryView: View {
    let galleryID: Int64
    let source: any ContentProviding
    let images: PageImageStore
    @State private var gallery: NativeGallery?
    @State private var cover: UIImage?
    @State private var error: String?
    @State private var retry = 0
    @State private var bookmark: ContentBookmark?

    var body: some View {
        Group {
            if let gallery {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if let cover {
                            Image(uiImage: cover).resizable().scaledToFit()
                                .frame(maxWidth: .infinity, maxHeight: 300).clipShape(RoundedRectangle(cornerRadius: 16))
                        }
                        Text(gallery.title).font(.title2.bold()).textSelection(.enabled)
                        Text(L10n.text("%@ · %@ · %@ pages", String(describing: gallery.language), String(describing: gallery.type), String(describing: gallery.pages.count)))
                            .font(.subheadline).foregroundStyle(.secondary)
                        NavigationLink(value: ContentRoute.reader(galleryID, 1)) {
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
        .navigationTitle(L10n.text("Work Details"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $bookmark) { target in AddWorkSheet(initialText: String(target.id)) }
        .task(id: retry) {
            error = nil
            do {
                let value = try await source.gallery(galleryID)
                try Task.checkCancellation()
                gallery = value
                if let page = value.pages.first { cover = try? await images.load(page, galleryID: galleryID, thumbnail: true) }
            } catch { if !Task.isCancelled { self.error = ContentError.message(error) } }
        }
    }
}

/// Owns requests independently of SwiftUI's short-lived refresh task. Replace data only after success.
@MainActor @Observable
final class GalleryFeedLoader {
    private let source: any ContentProviding
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var nextOffset = 0
    private var currentQuery: GalleryQuery?
    private var lastReset = true
    private(set) var ids: [Int64] = []
    private(set) var loading = false
    private(set) var hasMore = false
    private(set) var error: String?

    init(source: any ContentProviding) { self.source = source }

    @discardableResult func load(_ query: GalleryQuery, reset: Bool) -> Task<Void, Never> {
        task?.cancel()
        let changedQuery = currentQuery != query
        if changedQuery { ids = []; nextOffset = 0; hasMore = false }
        currentQuery = query
        let reset = reset || changedQuery
        lastReset = reset
        let token = UUID()
        generation = token
        loading = true
        error = nil
        let offset = reset ? 0 : nextOffset
        let source = source
        let request = Task { [weak self] in
            do {
                let batch = try await source.list(query, offset: offset, count: 24)
                try Task.checkCancellation()
                guard let self, self.generation == token else { return }
                var seen = Set(reset ? [] : self.ids)
                let incoming = batch.ids.filter { seen.insert($0).inserted }
                self.ids = (reset ? [] : self.ids) + incoming
                self.nextOffset = offset + batch.ids.count
                self.hasMore = batch.hasMore
            } catch {
                if !Task.isCancelled, let self, self.generation == token { self.error = ContentError.message(error) }
            }
            if let self, self.generation == token { self.loading = false }
        }
        task = request
        return request
    }

    @discardableResult func retry(_ query: GalleryQuery) -> Task<Void, Never> { load(query, reset: lastReset) }

    func cancel() { task?.cancel(); generation = UUID(); loading = false }
}
