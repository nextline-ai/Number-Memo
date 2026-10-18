import SwiftUI

struct BooruViewerBatch {
    let posts: [BooruPost]
    let hasMore: Bool
    var failure: String? = nil
}

/// Keep activity in shared state so an in-flight response reads the latest
/// lifecycle, rather than the scenePhase captured by its starting View value.
@MainActor @Observable final class BooruViewerPagination {
    var isActive = false
    private(set) var isLoading = false
    var hasMore = true
    private(set) var requestedFromID: String?
    var wantsNext: Bool { requestedFromID != nil }

    func requestAdvance(from id: String) { requestedFromID = id }
    func cancelAdvance() { requestedFromID = nil }
    func beginRequest() -> Bool {
        guard isActive, !isLoading, hasMore else { return false }
        isLoading = true
        return true
    }
    func finishRequest() { isLoading = false }
    func takeAdvance(currentID: String, nextExists: Bool) -> Bool {
        guard let requestedFromID else { return false }
        guard requestedFromID == currentID else { cancelAdvance(); return false }
        guard isActive else { return false }
        guard nextExists else {
            if !isLoading { cancelAdvance() }
            return false
        }
        cancelAdvance()
        return true
    }
}

struct BooruViewerAccessNavigation {
    enum Destination: Equatable { case post(Int), loadMore, close }
    private(set) var restrictedIDs = Set<String>()
    private(set) var pendingID: String?
    private(set) var direction = 1
    private var requestedMore = false

    mutating func moved(_ delta: Int) {
        if delta != 0 { direction = delta < 0 ? -1 : 1 }
        pendingID = nil; requestedMore = false
    }
    mutating func restrict(_ id: String) {
        restrictedIDs.insert(id)
        guard pendingID != id else { return }
        pendingID = id; requestedMore = false
    }
    func candidate(in ids: [String], startingAt index: Int, direction: Int, excluding: Set<String>) -> Int? {
        var index = index
        while ids.indices.contains(index) {
            if !restrictedIDs.contains(ids[index]), !excluding.contains(ids[index]) { return index }
            index += direction < 0 ? -1 : 1
        }
        return nil
    }
    mutating func destination(in ids: [String], current: Int, canLoadMore: Bool, excluding: Set<String>) -> Destination {
        if let next = candidate(in: ids, startingAt: current + direction, direction: direction, excluding: excluding) { return .post(next) }
        if direction > 0, canLoadMore, !requestedMore { requestedMore = true; return .loadMore }
        if let previous = candidate(in: ids, startingAt: current - direction, direction: -direction, excluding: excluding) { return .post(previous) }
        if canLoadMore, !requestedMore { requestedMore = true; return .loadMore }
        return .close
    }
}

struct BooruPostView: View {
    @Environment(\.discoveryContext) private var discovery
    @State private var posts: [BooruPost]
    var loadMore: (() async -> BooruViewerBatch)?
    var positionChanged: (BooruPost) -> Void
    var contextForPost: ((BooruPost) -> DiscoveryContext)?
    private var activeDiscovery: DiscoveryContext { contextForPost?(post) ?? discovery }
    @State private var pagination = BooruViewerPagination()
    @State private var accessNavigation = BooruViewerAccessNavigation()
    @State private var pagingTask: Task<Void, Never>?
    private var loadingMore: Bool { pagination.isLoading }
    private var wantsNext: Bool { pagination.wantsNext }
    private var hasMorePages: Bool { pagination.hasMore }
    private let initialServer: BooruServer
    private var server: BooruServer { store.servers.first { $0.id == post.serverID } ?? initialServer }
    let source: any BooruProviding
    var challenge: ChallengeSessionController?
    @Environment(BooruStore.self) private var store
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var post: BooruPost
    @State private var notes: [BooruNote] = []
    @State private var notesError: String?
    @State private var loadedNotesKey: String?
    @Environment(\.scenePhase) private var scenePhase
    @State private var menuVisible = false
    @SwiftUI.AppStorage("booru.videoMenuHintSeen", store: ReaderPreferences.booruDefaults) private var videoMenuHintSeen = false
    @State private var readerSettings = false
    @State private var filing = false
    @State private var translation: ReaderTranslationRequest?
    @State private var viewport = BooruViewerViewport()
    @State private var zoomed = false
    @State private var toast: String?
    @State private var saveFeedback: WorkSaveFeedback?
    @State private var exiting = false
    @State private var showJump = false
    @State private var jumpText = ""
    @State private var previousIdleTimer = false
    @SwiftUI.AppStorage("reader.rtl", store: ReaderPreferences.booruDefaults) private var rtl = false
    @SwiftUI.AppStorage("reader.bottomMenu", store: ReaderPreferences.booruDefaults) private var bottomMenu = false
    @SwiftUI.AppStorage("reader.pageNumber", store: ReaderPreferences.booruDefaults) private var pageNumber = false
    @SwiftUI.AppStorage("reader.keepAwake", store: ReaderPreferences.booruDefaults) private var keepAwake = true
    @SwiftUI.AppStorage("reader.dimming", store: ReaderPreferences.booruDefaults) private var dimming = 0.0
    @SwiftUI.AppStorage("reader.tapNavigation", store: ReaderPreferences.booruDefaults) private var tapNavigation = true
    @SwiftUI.AppStorage("reader.autoAdvance", store: ReaderPreferences.booruDefaults) private var autoAdvance = false
    @SwiftUI.AppStorage("reader.autoSeconds", store: ReaderPreferences.booruDefaults) private var autoSeconds = 10.0
    @SwiftUI.AppStorage("booru.original", store: ReaderPreferences.booruDefaults) private var loadOriginal = false
    @SwiftUI.AppStorage("booru.showNotes", store: ReaderPreferences.booruDefaults) private var defaultNotes = true
    @State private var showNotes = true
    @State private var original = false
    @State private var info = false
    @State private var selectedNote: BooruNote?
    @State private var mediaStatus = "loading"
    @State private var loadingIndicatorID: String?
    @State private var retry = 0
    @State private var refreshedMediaID: String?
    init(post: BooruPost, posts: [BooruPost], server: BooruServer, source: any BooruProviding, loadMore: (() async -> BooruViewerBatch)? = nil, positionChanged: @escaping (BooruPost) -> Void = { _ in }, contextForPost: ((BooruPost) -> DiscoveryContext)? = nil, challenge: ChallengeSessionController? = nil) {
        self.challenge = challenge
        _posts = State(initialValue: posts); self.loadMore = loadMore; self.positionChanged = positionChanged; self.contextForPost = contextForPost; self.initialServer = server; self.source = source; _post = State(initialValue: post)
        _original = State(initialValue: ReaderPreferences.booruDefaults.bool(forKey: "booru.original"))
        _showNotes = State(initialValue: ReaderPreferences.booruDefaults.object(forKey: "booru.showNotes") as? Bool ?? true)
    }
    private var index: Int { posts.firstIndex(where: { $0.id == post.id }) ?? 0 }
    private var isActive: Bool { !exiting && env.mode == .booru && scenePhase == .active }
    private var mediaActive: Bool {
        isActive && store.isVisible(post) && !accessNavigation.restrictedIDs.contains(post.id) && translation == nil && !info && !readerSettings && !filing && !showJump && selectedNote == nil
    }
    private var resolvesMissingMedia: Bool { server.engine.usesGelbooruPages || server.engine == .danbooru }
    private var mediaReady: Bool { ["ready", "playing", "ended"].contains(mediaStatus) }
    private var waitingForMedia: Bool { mediaStatus == "loading" || loadingMore && wantsNext }
    private var mayLoadNotes: Bool { isActive && (mediaReady || info) }
    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if post.viewerURL(original: original) != nil || resolvesMissingMedia && mediaStatus != "unavailable" {
                    BooruMediaView(post: post, server: server, original: original, active: mediaActive, failed: mediaStatus == "error", notes: notes, showNotes: showNotes,
                                   onNote: { selectedNote = $0 }, onStatus: { [postID = post.id] status in
                                       if post.id == postID, !accessNavigation.restrictedIDs.contains(postID) { mediaStatus = status }
                                   }, onGesture: gesture, onGoldRequired: { [postID = post.id] in skipGoldRestricted(postID) })
                        .ignoresSafeArea().id("\(server.id)-\(retry)")
                    #if DEBUG
                    if BooruUITestSupport.enabled || BooruUITestSupport.liveEnabled {
                        Text("\(post.postID):\(zoomed ? "zoomed" : "fit")").font(.caption2).foregroundStyle(.white).accessibilityIdentifier("booru.viewerState").frame(maxHeight: .infinity, alignment: .bottom).allowsHitTesting(false)
                        Text(mediaStatus).font(.caption2).foregroundStyle(.white).accessibilityIdentifier("booru.mediaStatus")
                            .accessibilityValue(post.fileURL?.absoluteString ?? "unresolved")
                            .frame(maxHeight: .infinity, alignment: .top)
                            .allowsHitTesting(false)
                    }
                    #endif
                    if loadingIndicatorID == post.id && waitingForMedia && isActive { ProgressView().tint(.white).allowsHitTesting(false) }
                    if mediaStatus == "error" {
                        ContentUnavailableView {
                            Label(L10n.text("Unable to Load"), systemImage: "photo.badge.exclamationmark")
                        } description: { Text(L10n.text("The media could not be loaded or its format is unavailable on this device.")) } actions: {
                            Button(L10n.text("Try Again")) { mediaStatus = "loading"; retry += 1 }
                            Link(L10n.text("Open on Website"), destination: server.pageURL(postID: post.postID))
                        }.padding(.bottom, 240).background(.black.opacity(0.8))
                    }
                } else {
                    ContentUnavailableView(L10n.text("Media Unavailable"), systemImage: "lock", description: Text(L10n.text("The server did not provide a media URL. Check your server account access.")))
                }
                Color.black.opacity(min(0.65, max(0, dimming))).ignoresSafeArea().allowsHitTesting(false)
                VStack {
                    if let toast { Text(toast).font(.subheadline.bold()).padding(12).background(.regularMaterial, in: Capsule()).accessibilityIdentifier("booru.toast") }
                    Spacer()
                    if menuVisible || mediaStatus == "error" || mediaStatus == "unavailable" || post.viewerURL(original: original) == nil && !resolvesMissingMedia { quickMenu }
                    else if pageNumber { Text("\(index + 1) / \(posts.count)").font(.caption.monospacedDigit()).padding(6).background(.black.opacity(0.5), in: Capsule()) }
                }.padding(16)
            }
            .overlay {
                if let translation {
                    ReaderTranslationView(loadImage: {
                        try await BooruThumbnailCache.shared.translationImage(post: post, server: server, rect: translation.rect)
                    }, booru: true, finished: { self.translation = nil }, failed: { message in self.translation = nil; toast = message })
                        .id(translation.id).frame(maxWidth: .infinity, maxHeight: .infinity).background(.black).transition(.opacity)
                }
            }
            .foregroundStyle(.white).tint(.white).preferredColorScheme(.dark)
            .overlay(alignment: .top) {
                ReaderDismissHandle(identifier: "booru.exitHandle", dismiss: closeViewer)
                    .ignoresSafeArea(edges: .top)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if bottomMenu && !menuVisible && translation == nil { menuActions(compact: true).padding(12).modifier(ReaderMenuGlass()).padding(.horizontal, 12).padding(.bottom, 6) }
            }
            .overlay(alignment: .top) {
                if let challenge, translation == nil { ChallengeViewerControls(controller: challenge) }
            }
            .onChange(of: challenge?.session.phase) { _, phase in
                if phase == .idle || phase == .ended { closeViewer() }
            }
            .background(VideoMenuGesture(enabled: post.isVideo && !info && !readerSettings && !filing && translation == nil && selectedNote == nil && !showJump) { menuVisible.toggle() })
            .accessibilityAction(named: L10n.text("Open Menu")) { menuVisible = true }
            .background(ReaderExitGesture(enabled: !exiting && !zoomed && !menuVisible && !info && !readerSettings && !filing && !showJump && translation == nil && selectedNote == nil, progress: { _ in }, exit: { closeViewer() }))
            .background(ReaderKeyboardCommands(enabled: !info && !readerSettings && !filing && !showJump && selectedNote == nil, action: shortcut))
            .statusBarHidden(true)
            .persistentSystemOverlays(.hidden)
            .toolbar(.hidden, for: .navigationBar).toolbar(.hidden, for: .tabBar)
            .interactiveDismissDisabled()
            .task(id: post.id) {
                if store.confirmedGoldRestrictedIDs.contains(post.id) { skipGoldRestricted(post.id); return }
                try? store.observeTaste(post, context: activeDiscovery)
                positionChanged(post)
            }
            .task(id: "\(post.id):\(waitingForMedia):\(isActive)") {
                loadingIndicatorID = nil
                guard isActive, waitingForMedia else { return }
                do { try await Task.sleep(for: .milliseconds(150)); try Task.checkCancellation() }
                catch { return }
                loadingIndicatorID = post.id
            }
            .task(id: "\(post.id):\(posts.count):\(loadOriginal):\(mediaActive):\(mediaReady)") { await preloadNeighbors() }
            .task(id: "\(post.id):\(mediaReady):\(isActive)") {
                guard isActive, mediaReady, index >= posts.count - 5 else { return }
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                requestMore()
            }
            .sheet(isPresented: $filing) { BooruFolderPicker(post: post).environment(\.discoveryContext, activeDiscovery) }
            .sheet(isPresented: $readerSettings) { ReaderSettingsView(booru: true) }
            .alert(L10n.text("Go to Page"), isPresented: $showJump) {
                TextField(L10n.text("Page Number"), text: $jumpText).keyboardType(.numberPad)
                Button(L10n.text("Go")) { if let number = Int(jumpText), posts.indices.contains(number - 1) { move(number - 1 - index) } }
                Button(L10n.text("Cancel"), role: .cancel) {}
            }
            .onAppear { previousIdleTimer = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = keepAwake }
            .onChange(of: isActive, initial: true) { _, active in
                pagination.isActive = active
                if active { completePendingAdvance() }
            }
            .onChange(of: store.confirmedGoldRestrictedIDs) { _, ids in
                if ids.contains(post.id) { skipGoldRestricted(post.id) }
            }
            .onChange(of: keepAwake) { _, value in UIApplication.shared.isIdleTimerDisabled = value }
            .onDisappear {
                UIApplication.shared.isIdleTimerDisabled = previousIdleTimer
                pagination.isActive = false; pagination.cancelAdvance(); pagingTask?.cancel()
            }
            .onChange(of: loadOriginal) { _, value in original = value }
            .onChange(of: original) { previous, value in
                if post.viewerURL(original: previous) != post.viewerURL(original: value) { mediaStatus = "loading" }
            }
            .onChange(of: defaultNotes) { _, value in showNotes = value }
            .onChange(of: post.isVideo, initial: true) { _, video in
                if video && !videoMenuHintSeen { videoMenuHintSeen = true; toast = L10n.text("Tap with two fingers for the video menu") }
            }
            .workSaveFeedback($saveFeedback, identifier: "booru.toast")
            .task(id: toast) {
                guard toast != nil else { return }
                do { try await Task.sleep(for: .seconds(2)); toast = nil } catch {}
            }
            .task(id: "\(translation?.id.uuidString ?? ""):\(filing):\(autoAdvance):\(autoSeconds):\(post.id):\(menuVisible):\(readerSettings):\(info):\(showJump):\(selectedNote?.id ?? 0):\(zoomed):\(isActive):\(mediaStatus)") {
                guard autoAdvance, isActive, translation == nil, !filing, !menuVisible, !readerSettings, !info, !showJump, selectedNote == nil, !zoomed, ["ready", "ended"].contains(mediaStatus) else { return }
                do {
                    try await Task.sleep(for: .seconds(min(120, max(2, autoSeconds))))
                    try Task.checkCancellation()
                    if index < posts.count - 1 || loadMore != nil && hasMorePages { move(1) } else { autoAdvance = false }
                } catch {}
            }
            .task(id: mediaStatus == "error" ? post.id : "") {
                guard mediaStatus == "error", server.engine.usesGelbooruPages, refreshedMediaID != post.id else { return }
                refreshedMediaID = post.id
                do {
                    let resolved = try await source.details(server: server, post: post)
                    try Task.checkCancellation()
                    if resolved.fileURL != post.fileURL || resolved.sampleURL != post.sampleURL {
                        post = resolved; mediaStatus = "loading"
                        if let folder = store.folderID(for: post) { try store.saveFavorite(post, folderID: folder) }
                    }
                } catch { if !Task.isCancelled { toast = BooruConnectionMessage.describe(error) } }
            }
            .task(id: post.id + ":\(retry)") {
                notes = []; notesError = nil
                if resolvesMissingMedia && post.viewerURL(original: original) == nil {
                    do {
                        let resolved = try await source.details(server: server, post: post)
                        try Task.checkCancellation()
                        post = resolved; positionChanged(resolved)
                        if let i = posts.firstIndex(where: { $0.id == resolved.id }) { posts[i] = resolved }
                        if resolved.viewerURL(original: original) == nil { mediaStatus = "unavailable" }
                        if let folder = store.folderID(for: post) { try store.saveFavorite(post, folderID: folder) }
                    } catch {
                        if !Task.isCancelled {
                            if error as? BooruPostAccessError == .goldRequired { skipGoldRestricted(post.id) }
                            else { mediaStatus = "error"; toast = BooruConnectionMessage.describe(error) }
                        }
                    }
                }
            }
            .task(id: "\(post.id):\(retry):\(mayLoadNotes)") {
                let key = "\(post.id):\(retry)"
                guard mayLoadNotes, loadedNotesKey != key else { return }
                do {
                    let result = try await source.notes(server: server, postID: post.postID)
                    try Task.checkCancellation()
                    notes = result; loadedNotesKey = key
                } catch {
                    if !Task.isCancelled { notesError = error.localizedDescription; loadedNotesKey = key }
                }
            }
            .sheet(isPresented: $info) { details }
            .sheet(item: $selectedNote) { note in
                NavigationStack {
                    ScrollView { Text(note.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(24) }
                        .navigationTitle(L10n.text("Notes")).navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) {
                            Button(L10n.text("Done")) { selectedNote = nil }.accessibilityIdentifier("booru.noteClose").keyboardShortcut(.cancelAction)
                        } }
                }
                    .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
            }
        }
    }
    private func shortcut(_ command: ReaderShortcut) {
        guard !info, !readerSettings, !filing, !showJump, selectedNote == nil else { return }
        if command == .exit {
            if translation != nil { translation = nil } else { closeViewer() }
            return
        }
        guard translation == nil else { return }
        switch command {
        case .previous: move(rtl ? 1 : -1)
        case .next: move(rtl ? -1 : 1)
        case .menu: menuVisible.toggle()
        case .favorite: gesture(.hold)
        case .details: info = true
        case .exit: break
        }
    }
    private var quickMenu: some View {
        VStack(spacing: 16) {
            HStack {
                Button { move(-1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                    .disabled(index == 0).accessibilityLabel(L10n.text("Previous")).accessibilityIdentifier("booru.previous")
                Spacer()
                Button { jumpText = String(index + 1); showJump = true } label: { Text("\(index + 1) / \(posts.count)").font(.headline.monospacedDigit()) }.accessibilityIdentifier("booru.position")
                Spacer()
                Button { move(1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }
                    .disabled(index >= posts.count - 1 && (loadMore == nil || !hasMorePages)).accessibilityLabel(L10n.text("Next")).accessibilityIdentifier("booru.next")
                Button { menuVisible = false } label: { Image(systemName: "xmark.circle.fill").frame(width: 44, height: 44) }
                    .accessibilityLabel(L10n.text("Close Menu")).accessibilityIdentifier("booru.menuClose")
            }
            menuActions(compact: false)
        }.padding(16).buttonStyle(.plain).modifier(ReaderMenuGlass())
    }
    private func menuActions(compact: Bool) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: compact ? 4 : 3), spacing: 18) {
            menuButton(L10n.text(store.isFavorite(post) ? "Remove Favorite" : "Add Favorite"), icon: store.isFavorite(post) ? "heart.fill" : "heart", id: "favorite", compact: compact) { toggleFavorite() }
            menuButton(L10n.text("Save to Folder"), icon: "folder", id: "folder", compact: compact) { filing = true }
            menuButton(L10n.text("Translate"), icon: "translate", id: "translate", compact: compact) {
                menuVisible = false; translation = .init(index: index, rect: viewport.rect)
            }.disabled(post.isVideo || mediaStatus != "ready")
            menuButton(L10n.text("Exit"), icon: "rectangle.portrait.and.arrow.right", id: "close", compact: compact) { closeViewer() }
            menuButton(L10n.text("Notes"), icon: showNotes ? "text.bubble.fill" : "text.bubble", id: "notes", compact: compact) { showNotes.toggle() }
            menuButton(L10n.text("Details"), icon: "info.circle", id: "info", compact: compact) { info = true }
            ShareLink(item: server.pageURL(postID: post.postID)) { menuLabel(L10n.text("Share"), icon: "square.and.arrow.up", compact: compact) }
            menuButton(L10n.text("More Settings"), icon: "slider.horizontal.3", id: "readerSettings", compact: compact) { readerSettings = true }
        }.buttonStyle(.plain).foregroundStyle(.white).tint(.white)
    }
    private func menuLabel(_ title: String, icon: String, compact: Bool) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 21))
            Text(title).font(compact ? .system(size: 9, weight: .medium) : .caption).lineLimit(1).minimumScaleFactor(0.8)
        }.frame(maxWidth: .infinity, minHeight: 44)
    }
    private func menuButton(_ title: String, icon: String, id: String, compact: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { menuLabel(title, icon: icon, compact: compact) }.accessibilityLabel(title).accessibilityIdentifier("booru." + id)
    }
    private func toggleFavorite() {
        saveFeedback = .perform { try BooruFavoriteAction.toggle(post, store: store, context: activeDiscovery) }
    }
    private func closeViewer() {
        guard !exiting else { return }
        exiting = true
        pagination.isActive = false; pagination.cancelAdvance()
        dismiss()
    }
    private func gesture(_ gesture: BooruMediaGesture) {
        guard !info, !readerSettings, !filing, translation == nil, selectedNote == nil, !showJump else { return }
        switch gesture {
        case .shortcut(let command): shortcut(command)
        case .tap(let x):
            if (0.3...0.7).contains(x) { menuVisible.toggle() }
            else if tapNavigation { move((x < 0.3 ? -1 : 1) * (rtl ? -1 : 1)) }
        case .swipe(let delta): if !zoomed { move(delta * (rtl ? -1 : 1)) }
        case .hold:
            toggleFavorite()
        case .dismiss: if !zoomed { closeViewer() }
        case .zoom(let value): if zoomed != value { zoomed = value }
        case .viewport(let rect): viewport.rect = rect
        }
    }
    private var details: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("ID") {
                        HStack {
                            Text(String(post.postID)).textSelection(.enabled).accessibilityIdentifier("booru.postID")
                            Button { UIPasteboard.general.string = String(post.postID) } label: { Image(systemName: "doc.on.doc") }
                                .accessibilityLabel(L10n.text("Copy ID")).accessibilityIdentifier("booru.copyID")
                        }
                    }
                    LabeledContent(L10n.text("Server"), value: server.displayName)
                    LabeledContent(L10n.text("Resolution"), value: "\(post.width) × \(post.height)")
                    LabeledContent(L10n.text("Format"), value: post.fileExtension.uppercased())
                    LabeledContent(L10n.text("Score"), value: String(post.score))
                    if !post.isVideo && !post.isAnimated {
                        Toggle(L10n.text("Original Image"), isOn: $original)
                    }
                    Link(L10n.text("Open on Website"), destination: server.pageURL(postID: post.postID))
                }
                Section(L10n.text("Content Controls")) {
                    NavigationLink { ContentReportView(page: server.pageURL(postID: post.postID)) } label: {
                        Label(L10n.text("Report Content"), systemImage: "flag")
                    }.accessibilityIdentifier("booru.report")
                    Button(L10n.text("Hide This Post"), systemImage: "eye.slash") { hideContent(rule: "id:\(post.postID)") }
                        .accessibilityIdentifier("booru.hidePost")
                    if !post.artists.isEmpty {
                        Menu(L10n.text("Block Artist"), systemImage: "person.crop.circle.badge.xmark") {
                            ForEach(post.artists, id: \.self) { artist in
                                Button(artist) { hideContent(rule: "artist:" + artist) }
                            }
                        }
                    }
                }
                if !post.artists.isEmpty {
                    Section(L10n.text("Artists")) { ForEach(post.artists, id: \.self) { tag in tagRow(tag, artist: true) } }
                }
                Section(L10n.text("Tags")) { ForEach(post.tags, id: \.self) { tag in tagRow(tag, artist: false) } }
                if !post.poolIDs.isEmpty {
                    Section(L10n.text("Pools")) {
                        ForEach(post.poolIDs, id: \.self) { id in
                            NavigationLink("Pool #\(id)") { BooruFeedView(server: server, source: source, pool: .init(id: id, name: "Pool #\(id)", count: 0)) }
                        }
                    }
                }
                Section(L10n.text("Notes")) {
                    if let notesError {
                        Text(notesError).foregroundStyle(.secondary)
                        Button(L10n.text("Try Again")) { retry += 1 }
                    } else if notes.isEmpty { Text(L10n.text("No Notes")).foregroundStyle(.secondary) }
                    ForEach(Array(notes.enumerated()), id: \.element.id) { index, note in
                        VStack(alignment: .leading, spacing: 6) { Text("#\(index + 1)").font(.caption).foregroundStyle(.secondary); Text(note.body).textSelection(.enabled) }
                    }
                }
            }.navigationTitle(L10n.text("Details")).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.text("Done")) { info = false }.keyboardShortcut(.cancelAction) } }
        }.presentationDragIndicator(.visible)
    }
    private func hideContent(rule: String) {
        store.perform {
            let old = store.blacklist(serverID: server.id)
            try store.setBlacklist(old.isEmpty ? rule : old + "\n" + rule, serverID: server.id)
            info = false
            closeViewer()
        }
    }

    private func tagRow(_ tag: String, artist: Bool) -> some View {
        HStack {
            NavigationLink { BooruFeedView(server: server, source: source, initialQuery: tag) } label: { Text(tag.replacingOccurrences(of: "_", with: " ")) }
            Menu {
                Button(L10n.text("Save Tag"), systemImage: "tag") { saveTag(tag, kind: "tag") }
                Button(L10n.text("Save Artist"), systemImage: "person") { saveTag(tag, kind: "artist") }
                Button(L10n.text("Blacklist Tag"), systemImage: "eye.slash") {
                    store.perform {
                        let old = store.blacklist(serverID: server.id)
                        try store.setBlacklist(old.isEmpty ? tag : old + "\n" + tag, serverID: server.id)
                        info = false
                        closeViewer()
                    }
                }
            } label: {
                Image(systemName: store.savedTags(serverID: server.id, kind: artist ? "artist" : "tag").contains(tag) ? "bookmark.fill" : "ellipsis.circle")
            }.buttonStyle(.borderless)
        }
    }
    private func saveTag(_ tag: String, kind: String) {
        if !store.savedTags(serverID: server.id, kind: kind).contains(tag) { store.perform { try store.toggleTag(tag, serverID: server.id, kind: kind) } }
    }
    private func move(_ delta: Int) {
        guard pagination.isActive else { return }
        let next = accessNavigation.candidate(in: posts.map(\.id), startingAt: index + delta,
                                             direction: delta < 0 ? -1 : 1, excluding: store.confirmedGoldRestrictedIDs)
        guard let next else {
            if delta > 0, loadMore != nil, hasMorePages { pagination.requestAdvance(from: post.id); requestMore() }
            else { pagination.cancelAdvance() }
            return
        }
        pagination.cancelAdvance()
        accessNavigation.moved(delta)
        // The jump alert dismisses independently. Retain the ready document,
        // crop and notes when its selected page has not changed.
        guard next != index else { return }
        selectPost(at: next)
    }
    private func selectPost(at next: Int) {
        viewport.rect = CGRect(x: 0, y: 0, width: 1, height: 1); translation = nil
        post = posts[next]; original = loadOriginal; mediaStatus = "loading"; zoomed = false; notes = []; loadedNotesKey = nil
        positionChanged(post)
    }
    private func skipGoldRestricted(_ id: String) {
        guard !exiting, post.id == id else { return }
        store.recordGoldRestriction(post)
        accessNavigation.restrict(id)
        pagination.cancelAdvance()
        mediaStatus = "restricted"
        continueAfterRestriction()
    }
    private func continueAfterRestriction() {
        guard pagination.isActive, !pagination.isLoading, accessNavigation.pendingID == post.id else { return }
        let destination = accessNavigation.destination(in: posts.map(\.id), current: index,
                                                       canLoadMore: loadMore != nil && hasMorePages,
                                                       excluding: store.confirmedGoldRestrictedIDs)
        switch destination {
        case .post(let next):
            let direction = accessNavigation.direction
            accessNavigation.moved(direction)
            selectPost(at: next)
        case .loadMore: requestMore()
        case .close: closeViewer()
        }
    }
    private func requestMore() {
        guard loadMore != nil, pagination.beginRequest() else { return }
        pagingTask = Task {
            await extendFeed()
            pagination.finishRequest()
            guard !Task.isCancelled else { return }
            completePendingAdvance()
        }
    }
    private func extendFeed() async {
        guard let loadMore else { return }
        let batch = await loadMore()
        guard !Task.isCancelled else { return }
        var seen = Set(posts.map(\.id))
        posts += batch.posts.filter { seen.insert($0.id).inserted }
        pagination.hasMore = batch.hasMore
        if let failure = batch.failure { toast = failure }
    }
    private func completePendingAdvance() {
        if accessNavigation.pendingID == post.id { continueAfterRestriction(); return }
        let next = accessNavigation.candidate(in: posts.map(\.id), startingAt: index + 1, direction: 1,
                                             excluding: store.confirmedGoldRestrictedIDs)
        if pagination.takeAdvance(currentID: post.id, nextExists: next != nil), let next { move(next - index) }
    }
    private func preloadNeighbors() async {
        #if DEBUG
        if BooruUITestSupport.enabled { return }
        #endif
        guard mediaActive, mediaReady, !ProcessInfo.processInfo.isLowPowerModeEnabled,
              ProcessInfo.processInfo.thermalState == .nominal || ProcessInfo.processInfo.thermalState == .fair else { return }
        // Wait for a settled page; fast swipes should not fetch four originals.
        try? await Task.sleep(for: .milliseconds(200))
        guard !Task.isCancelled else { return }
        let next = index + 1
        guard posts.indices.contains(next) else { return }
        var item = posts[next]
        guard let host = store.servers.first(where: { $0.id == item.serverID }) else { return }
        if item.viewerURL(original: loadOriginal) == nil, host.engine.usesGelbooruPages,
           let resolved = try? await source.details(server: host, post: item) {
            guard !Task.isCancelled else { return }
            item = resolved
            if let i = posts.firstIndex(where: { $0.id == item.id }) { posts[i] = item }
        }
        if !item.isVideo, let url = item.viewerURL(original: loadOriginal) {
            await BooruViewerImageCache.shared.prefetch(url: url, server: host)
        }
    }

}

/// Panning updates the next translation crop without rebuilding the viewer.
private final class BooruViewerViewport {
    var rect = CGRect(x: 0, y: 0, width: 1, height: 1)
}

/// Two fingers reach the app menu without intercepting a video's native play,
/// seek, mute, or fullscreen controls. Single taps outside video still work.
private struct VideoMenuGesture: UIViewRepresentable {
    var enabled: Bool
    var action: () -> Void
    func makeUIView(context: Context) -> VideoMenuGestureView { VideoMenuGestureView() }
    func updateUIView(_ view: VideoMenuGestureView, context: Context) { view.action = action; view.tap.isEnabled = enabled }
    static func dismantleUIView(_ view: VideoMenuGestureView, coordinator: ()) { view.tap.view?.removeGestureRecognizer(view.tap) }
}
private final class VideoMenuGestureView: UIView, UIGestureRecognizerDelegate {
    var action: () -> Void = {}
    lazy var tap: UITapGestureRecognizer = {
        let value = UITapGestureRecognizer(target: self, action: #selector(openMenu))
        value.numberOfTouchesRequired = 2; value.cancelsTouchesInView = false; value.delegate = self
        return value
    }()
    override func didMoveToWindow() {
        super.didMoveToWindow(); tap.view?.removeGestureRecognizer(tap); window?.addGestureRecognizer(tap)
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    @objc private func openMenu() { action() }
}
