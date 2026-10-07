import SwiftUI

struct BooruPostView: View {
    @Environment(\.discoveryContext) private var discovery
    let posts: [BooruPost]
    private let initialServer: BooruServer
    private var server: BooruServer { store.servers.first { $0.id == post.serverID } ?? initialServer }
    let source: any BooruProviding
    @Environment(BooruStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var post: BooruPost
    @State private var notes: [BooruNote] = []
    @State private var notesError: String?
    @Environment(\.scenePhase) private var scenePhase
    @State private var menuVisible = false
    @SwiftUI.AppStorage("booru.videoMenuHintSeen", store: ReaderPreferences.booruDefaults) private var videoMenuHintSeen = false
    @State private var readerSettings = false
    @State private var filing = false
    @State private var translation: ReaderTranslationRequest?
    @State private var viewport = CGRect(x: 0, y: 0, width: 1, height: 1)
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
    @State private var retry = 0
    @State private var refreshedMediaID: String?
    init(post: BooruPost, posts: [BooruPost], server: BooruServer, source: any BooruProviding) {
        self.posts = posts; self.initialServer = server; self.source = source; _post = State(initialValue: post)
        _original = State(initialValue: ReaderPreferences.booruDefaults.bool(forKey: "booru.original"))
        _showNotes = State(initialValue: ReaderPreferences.booruDefaults.object(forKey: "booru.showNotes") as? Bool ?? true)
    }
    private var index: Int { posts.firstIndex(where: { $0.id == post.id }) ?? 0 }
    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if post.displayURL != nil {
                    BooruMediaView(post: post, server: server, original: original, notes: notes, showNotes: showNotes,
                                   onNote: { selectedNote = $0 }, onStatus: { mediaStatus = $0 }, onGesture: gesture).ignoresSafeArea().id("\(post.id)-\(post.fileURL?.absoluteString ?? "")-\(retry)")
                    #if DEBUG
                    if BooruUITestSupport.enabled || BooruUITestSupport.liveEnabled {
                        Text("\(post.postID):\(zoomed ? "zoomed" : "fit")").font(.caption2).foregroundStyle(.white).accessibilityIdentifier("booru.viewerState").frame(maxHeight: .infinity, alignment: .bottom).allowsHitTesting(false)
                        Text(mediaStatus).font(.caption2).foregroundStyle(.white).accessibilityIdentifier("booru.mediaStatus")
                            .accessibilityValue(post.fileURL?.absoluteString ?? "unresolved")
                            .frame(maxHeight: .infinity, alignment: .top)
                            .allowsHitTesting(false)
                    }
                    #endif
                    if mediaStatus == "loading" { ProgressView().tint(.white).allowsHitTesting(false) }
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
                    if menuVisible || mediaStatus == "error" || post.displayURL == nil { quickMenu }
                    else if pageNumber { Text("\(index + 1) / \(posts.count)").font(.caption.monospacedDigit()).padding(6).background(.black.opacity(0.5), in: Capsule()) }
                }.padding(16)
            }
            .overlay {
                if let translation {
                    ReaderTranslationView(loadImage: {
                        try await BooruThumbnailCache.shared.translationImage(post: post, server: server, rect: translation.rect)
                    }, booru: true, finished: { self.translation = nil }, failed: { message in self.translation = nil; toast = message })
                        .id(translation.id).background(.black).transition(.opacity)
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
            .background(VideoMenuGesture(enabled: post.isVideo && !info && !readerSettings && !filing && translation == nil && selectedNote == nil && !showJump) { menuVisible.toggle() })
            .accessibilityAction(named: L10n.text("Open Menu")) { menuVisible = true }
            .background(ReaderExitGesture(enabled: !exiting && !zoomed && !menuVisible && !info && !readerSettings && !filing && !showJump && translation == nil && selectedNote == nil, progress: { _ in }, exit: { closeViewer() }))
            .background(ReaderKeyboardCommands(enabled: !info && !readerSettings && !filing && !showJump && selectedNote == nil, action: shortcut))
            .statusBarHidden(true)
            .persistentSystemOverlays(.hidden)
            .toolbar(.hidden, for: .navigationBar).toolbar(.hidden, for: .tabBar)
            .interactiveDismissDisabled()
            .task(id: post.id) { try? store.observeTaste(post, context: discovery) }
            .sheet(isPresented: $filing) { BooruFolderPicker(post: post).environment(\.discoveryContext, discovery) }
            .sheet(isPresented: $readerSettings) { ReaderSettingsView(booru: true) }
            .alert(L10n.text("Go to Page"), isPresented: $showJump) {
                TextField(L10n.text("Page Number"), text: $jumpText).keyboardType(.numberPad)
                Button(L10n.text("Go")) { if let number = Int(jumpText), posts.indices.contains(number - 1) { move(number - 1 - index) } }
                Button(L10n.text("Cancel"), role: .cancel) {}
            }
            .onAppear { previousIdleTimer = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = keepAwake }
            .onChange(of: keepAwake) { _, value in UIApplication.shared.isIdleTimerDisabled = value }
            .onDisappear { UIApplication.shared.isIdleTimerDisabled = previousIdleTimer }
            .onChange(of: loadOriginal) { _, value in original = value; mediaStatus = "loading" }
            .onChange(of: defaultNotes) { _, value in showNotes = value }
            .onChange(of: post.isVideo, initial: true) { _, video in
                if video && !videoMenuHintSeen { videoMenuHintSeen = true; toast = L10n.text("Tap with two fingers for the video menu") }
            }
            .workSaveFeedback($saveFeedback, identifier: "booru.toast")
            .task(id: toast) {
                guard toast != nil else { return }
                do { try await Task.sleep(for: .seconds(2)); toast = nil } catch {}
            }
            .task(id: "\(translation?.id.uuidString ?? ""):\(filing):\(autoAdvance):\(autoSeconds):\(post.id):\(menuVisible):\(readerSettings):\(info):\(showJump):\(selectedNote?.id ?? 0):\(zoomed):\(scenePhase):\(mediaStatus)") {
                guard autoAdvance, translation == nil, !filing, scenePhase == .active, !menuVisible, !readerSettings, !info, !showJump, selectedNote == nil, !zoomed, ["ready", "ended"].contains(mediaStatus) else { return }
                do {
                    try await Task.sleep(for: .seconds(min(120, max(2, autoSeconds))))
                    try Task.checkCancellation()
                    if index < posts.count - 1 { move(1) } else { autoAdvance = false }
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
                if server.engine.usesGelbooruPages && post.fileURL == nil {
                    do {
                        let resolved = try await source.details(server: server, post: post)
                        try Task.checkCancellation()
                        post = resolved
                        if let folder = store.folderID(for: post) { try store.saveFavorite(post, folderID: folder) }
                    } catch { if !Task.isCancelled { toast = BooruConnectionMessage.describe(error) } }
                }
                do {
                    let result = try await source.notes(server: server, postID: post.postID)
                    try Task.checkCancellation()
                    notes = result
                } catch { if !Task.isCancelled { notesError = error.localizedDescription } }
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
                    .disabled(index >= posts.count - 1).accessibilityLabel(L10n.text("Next")).accessibilityIdentifier("booru.next")
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
                menuVisible = false; translation = .init(index: index, rect: viewport)
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
        saveFeedback = .perform { try BooruFavoriteAction.toggle(post, store: store, context: discovery) }
    }
    private func closeViewer() {
        guard !exiting else { return }
        exiting = true
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
        case .zoom(let value): zoomed = value
        case .viewport(let rect): viewport = rect
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
                        Toggle(L10n.text("Original Image"), isOn: $original).onChange(of: original) { _, _ in mediaStatus = "loading" }
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
        let next = index + delta
        guard posts.indices.contains(next) else { return }
        viewport = CGRect(x: 0, y: 0, width: 1, height: 1); translation = nil
        post = posts[next]; original = loadOriginal; mediaStatus = "loading"; zoomed = false; notes = []
    }
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
