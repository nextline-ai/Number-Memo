import SwiftUI

private enum ReaderSheet: String, Identifiable {
    case settings, preview, details, help
    var id: String { rawValue }
}

struct NativeReaderView: View {
    @Environment(AppEnvironment.self) private var env
    let galleryID: Int64
    let initialPage: Int
    let source: any ContentProviding
    let images: PageImageStore
    let savesProgress: Bool
    let search: (String) -> Void
    let exit: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var translationRequest: ReaderTranslationRequest?
    @State private var zoomed = false
    @State private var zoomedPages: Set<Int> = []
    @State private var exitDrag: CGFloat = 0
    @State private var pendingSearch: String?
    @SwiftUI.AppStorage("reader.pagesPerSpread", store: ReaderPreferences.defaults) private var pagesPerSpread = 1
    @SwiftUI.AppStorage("reader.autoAdvance", store: ReaderPreferences.defaults) private var autoAdvance = false
    @SwiftUI.AppStorage("reader.autoSeconds", store: ReaderPreferences.defaults) private var autoSeconds = 10.0
    @SwiftUI.AppStorage("reader.helpHidden", store: ReaderPreferences.defaults) private var helpHidden = false
    @State private var gallery: NativeGallery?
    @State private var currentPage = 0
    @State private var error: String?
    @State private var retry = 0
    @State private var menuVisible = false
    @State private var sheet: ReaderSheet?
    @State private var viewports: [Int: CGRect] = [:]
    @State private var toast: String?
    @State private var showJump = false
    @State private var jumpText = ""
    @State private var previousIdleTimer = false
    @SwiftUI.AppStorage("reader.mode", store: ReaderPreferences.defaults) private var mode = ReaderMode.horizontal.rawValue
    @SwiftUI.AppStorage("reader.rtl", store: ReaderPreferences.defaults) private var rtl = false
    @SwiftUI.AppStorage("reader.bottomMenu", store: ReaderPreferences.defaults) private var bottomMenu = false
    @SwiftUI.AppStorage("reader.pageNumber", store: ReaderPreferences.defaults) private var pageNumber = false
    @SwiftUI.AppStorage("reader.keepAwake", store: ReaderPreferences.defaults) private var keepAwake = true
    @SwiftUI.AppStorage("reader.prefetch", store: ReaderPreferences.defaults) private var prefetch = 3
    @SwiftUI.AppStorage("reader.dimming", store: ReaderPreferences.defaults) private var dimming = 0.0
    @SwiftUI.AppStorage("reader.tapNavigation", store: ReaderPreferences.defaults) private var tapNavigation = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let gallery {
                reader(gallery).ignoresSafeArea().offset(y: exitDrag)
                    .overlay(Color.black.opacity(min(0.65, max(0, dimming))).allowsHitTesting(false))
            } else if let error {
                ContentFailureView(message: error) { retry += 1 }.preferredColorScheme(.dark)
            } else { ProgressView(L10n.text("Loading page")).tint(.white).foregroundStyle(.white) }

            VStack {
                if let toast {
                    Text(toast).font(.subheadline.bold()).padding(12).background(.regularMaterial, in: Capsule())
                        .accessibilityIdentifier("reader.toast")
                }
                Spacer()
                if menuVisible || gallery == nil { quickMenu }
                else if pageNumber, let gallery {
                    Text("\(currentPage + 1) / \(gallery.pages.count)")
                        .font(.caption.monospacedDigit()).padding(6).background(.black.opacity(0.5), in: Capsule()).foregroundStyle(.white)
                }
            }.padding(16)
        }
        .overlay(alignment: .top) {
            VStack {
                Capsule().fill(.white).frame(width: 96, height: 2)
                    .shadow(color: .black.opacity(0.7), radius: 1)
                    .padding(.top, 2).accessibilityIdentifier("reader.exitHandle")
                    .accessibilityLabel(L10n.text("Swipe down to exit the work"))
                    .accessibilityAddTraits(.isButton).accessibilityAction { exit() }
                Spacer()
            }.ignoresSafeArea(edges: .top).allowsHitTesting(false)
        }
        .background(ReaderExitGesture(enabled: sheet == nil && !showJump && !zoomed && translationRequest == nil, progress: { distance in
            if distance == 0 { withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) { exitDrag = 0 } }
            else { exitDrag = distance }
        }, exit: exit))
        .overlay(alignment: .topTrailing) {
            if let request = translationRequest, let gallery, gallery.pages.indices.contains(request.index) {
                ReaderTranslationView(page: gallery.pages[request.index], galleryID: galleryID, images: images, rect: request.rect, finished: {
                    guard translationRequest?.id == request.id else { return }
                    translationRequest = nil
                }, failed: { message in
                    guard translationRequest?.id == request.id else { return }
                    toast = message; translationRequest = nil
                })
                .id(request.id)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if bottomMenu && !menuVisible && gallery != nil { menuActions(compact: true).padding(.horizontal, 12).padding(.vertical, 8)
                    .modifier(ReaderMenuGlass()).padding(.horizontal, 12).padding(.bottom, 6) }
        }
        .overlay(alignment: .topTrailing) {
            if translationRequest == nil {
                HStack(spacing: 8) {
                    Button(action: exit) { Image(systemName: "xmark").frame(width: 44, height: 44).glassCircle() }
                        .accessibilityLabel(L10n.text("Exit")).accessibilityIdentifier("reader.pointerClose").keyboardShortcut(.cancelAction)
                    Button { menuVisible.toggle() } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44).glassCircle() }
                        .accessibilityLabel(L10n.text("Quick Menu"))
                }.foregroundStyle(.white).padding(12)
            }
        }
        .background(ReaderKeyboardCommands(enabled: sheet == nil && !showJump, action: shortcut))
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .navigationBarBackButtonHidden(true)
        .interactiveDismissDisabled()
        .sheet(item: $sheet, onDismiss: {
            if let pendingSearch { self.pendingSearch = nil; search(pendingSearch) }
        }) { item in
            switch item {
            case .settings: ReaderSettingsView()
            case .preview:
                if let gallery { ReaderPreviewView(gallery: gallery, images: images, current: $currentPage) }
            case .details:
                if let gallery { ReaderDetailsView(search: { pendingSearch = $0; sheet = nil }, gallery: gallery) }
            case .help: ReaderHelpView()
            }
        }
        .alert(L10n.text("Go to Page"), isPresented: $showJump) {
            TextField(L10n.text("Page Number"), text: $jumpText).keyboardType(.numberPad)
            Button(L10n.text("Go")) {
                if let page = Int(jumpText), let gallery { currentPage = ReaderLayout.start(min(max(page - 1, 0), gallery.pages.count - 1), count: pagesPerSpread) }
            }
            Button(L10n.text("Cancel"), role: .cancel) {}
        }
        .task(id: retry) { await loadGallery() }
        .task(id: "\(currentPage):\(pagesPerSpread):\(prefetch):\(gallery?.id ?? 0)") {
            if let gallery { await images.prefetch(gallery, current: currentPage, count: prefetch, visibleCount: pagesPerSpread) }
        }
        .task(id: toast) {
            guard toast != nil else { return }
            do { try await Task.sleep(for: .seconds(2)); toast = nil } catch {}
        }
        .task(id: autoTaskID) {
            guard autoAdvance, scenePhase == .active, sheet == nil, !menuVisible, !showJump,
                  !zoomed, exitDrag == 0, translationRequest == nil, let gallery else { return }
            do {
                try await Task.sleep(for: .seconds(min(120, max(2, autoSeconds))))
                try Task.checkCancellation()
                let next = ReaderLayout.next(currentPage, delta: 1, count: pagesPerSpread, total: gallery.pages.count)
                if next == currentPage { autoAdvance = false } else { currentPage = next }
            } catch {}
        }
        .onChange(of: "\(mode):\(rtl):\(pagesPerSpread)") { _, _ in
            viewports = [:]; zoomedPages = []; zoomed = false
        }
        .onChange(of: pagesPerSpread) { _, count in currentPage = ReaderLayout.start(currentPage, count: count) }
        .onChange(of: currentPage) { _, page in
            let start = ReaderLayout.start(page, count: pagesPerSpread)
            if start != page { currentPage = start }
            translationRequest = nil; viewports = [:]; zoomed = false; zoomedPages = []
            if savesProgress { UserDefaults.standard.set(page + 1, forKey: "reader_page_\(galleryID)") }
        }
        .onAppear { previousIdleTimer = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = keepAwake }
        .onChange(of: keepAwake) { _, value in UIApplication.shared.isIdleTimerDisabled = value }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = previousIdleTimer }
    }

    @ViewBuilder private func reader(_ gallery: NativeGallery) -> some View {
        if mode == ReaderMode.continuous.rawValue {
            ReaderContinuousView(gallery: gallery, images: images, current: $currentPage, tap: tapped, bookmark: bookmark, count: ReaderLayout.count(pagesPerSpread), rtl: rtl, viewport: viewportChanged)
                .id("continuous:\(pagesPerSpread)")
        } else {
            ReaderPager(gallery: gallery, images: images, vertical: mode == ReaderMode.vertical.rawValue, rtl: rtl,
                        current: $currentPage, tap: tapped, bookmark: bookmark, count: ReaderLayout.count(pagesPerSpread), viewport: viewportChanged)
                .id("\(mode):\(rtl):\(pagesPerSpread)")
        }
    }

    private var quickMenu: some View {
        VStack(spacing: 16) {
            HStack {
                Button { move(-1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                    .disabled(currentPage == 0).accessibilityLabel(L10n.text("Previous Page")).accessibilityIdentifier("reader.previous")
                Spacer()
                Button { jumpText = String(currentPage + 1); showJump = true } label: {
                    Text("\(currentPage + 1) / \(gallery?.pages.count ?? 0)").monospacedDigit().font(.headline)
                }.accessibilityLabel(L10n.text("Page %@ / %@", String(describing: currentPage + 1), String(describing: gallery?.pages.count ?? 0))).accessibilityIdentifier("reader.position")
                Spacer()
                Button { move(1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }
                    .disabled(currentPage + ReaderLayout.count(pagesPerSpread) >= (gallery?.pages.count ?? 1)).accessibilityLabel(L10n.text("Next Page")).accessibilityIdentifier("reader.next")
                Button { menuVisible = false } label: { Image(systemName: "xmark.circle.fill").frame(width: 44, height: 44) }
                    .accessibilityLabel(L10n.text("Close Menu")).accessibilityIdentifier("reader.menu.close")
            }
            menuActions(compact: false)
        }
        .padding(16).foregroundStyle(.white).tint(.white).buttonStyle(.plain)
        .modifier(ReaderMenuGlass())
    }

    private func menuActions(compact: Bool) -> some View {
        let columns = Array(repeating: GridItem(.flexible()), count: compact ? 6 : 3)
        return LazyVGrid(columns: columns, spacing: 18) {
            menuButton(L10n.text("Bookmark"), icon: "bookmark", id: "bookmark", compact: compact, action: bookmark)
            menuButton(L10n.text("Exit"), icon: "rectangle.portrait.and.arrow.right", id: "exit", compact: compact, action: exit)
            menuButton(L10n.text("Translate"), icon: "translate", id: "translate", compact: compact) { translationRequest = ReaderTranslationRequest(index: currentPage, rect: viewports[currentPage] ?? CGRect(x: 0, y: 0, width: 1, height: 1)); menuVisible = false }
            menuButton(L10n.text("Details"), icon: "info.circle", id: "details", compact: compact) { sheet = .details }
            menuButton(L10n.text("Preview"), icon: "square.grid.3x3", id: "preview", compact: compact) { sheet = .preview }
            menuButton(L10n.text("More Settings"), icon: "slider.horizontal.3", id: "settings", compact: compact) { sheet = .settings }
        }
    }

    private func menuButton(_ title: String, icon: String, id: String, compact: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 21))
                Text(title).font(compact ? .system(size: 9, weight: .medium) : .caption).lineLimit(1).minimumScaleFactor(0.8)
            }.frame(maxWidth: .infinity, minHeight: 44)
        }
        .foregroundStyle(.white).tint(.white).buttonStyle(.plain)
        .disabled(gallery == nil && id != "exit" && id != "settings")
        .accessibilityLabel(title).accessibilityIdentifier("reader.\(id)")
    }

    private var autoTaskID: String {
        "\(autoAdvance):\(autoSeconds):\(currentPage):\(pagesPerSpread):\(menuVisible):\(sheet?.rawValue ?? ""):\(showJump):\(zoomed):\(exitDrag > 0):\(translationRequest?.id.uuidString ?? ""):\(scenePhase):\(gallery?.id ?? 0)"
    }
    private func viewportChanged(_ index: Int, rect: CGRect, scale: CGFloat) {
        if scale > 1.01 { zoomedPages.insert(index) } else { zoomedPages.remove(index) }
        zoomed = !zoomedPages.isEmpty
        guard rect.width > 0.01, rect.height > 0.01 else { return }
        if scale > 1.01 { viewports[index] = rect } else { viewports.removeValue(forKey: index) }
    }

    private func shortcut(_ command: ReaderShortcut) {
        guard sheet == nil, !showJump else { return }
        if command == .exit {
            if translationRequest != nil { translationRequest = nil } else { exit() }
            return
        }
        guard translationRequest == nil else { return }
        switch command {
        case .previous: move(rtl ? 1 : -1)
        case .next: move(rtl ? -1 : 1)
        case .menu: menuVisible.toggle()
        case .favorite: bookmark()
        case .details: sheet = .details
        case .exit: break
        }
    }
    private func tapped(_ x: CGFloat) {
        if (0.3...0.7).contains(x) { menuVisible.toggle() }
        else if tapNavigation { move((x < 0.3 ? -1 : 1) * (rtl ? -1 : 1)) }
    }
    private func move(_ delta: Int) {
        guard let gallery else { return }
        currentPage = ReaderLayout.next(currentPage, delta: delta, count: pagesPerSpread, total: gallery.pages.count)
    }
    private func bookmark() {
        do { toast = try ContentBookmarkAction.toggle(id: galleryID, gallery: gallery, env: env, images: images) }
        catch { toast = L10n.text("Unable to save. Please try again.") }
    }
    private func loadGallery() async {
        error = nil
        // Even an unavailable gallery must retain a visible way out.
        menuVisible = false
        do {
            let value = try await source.gallery(galleryID)
            try Task.checkCancellation()
            let saved = savesProgress ? UserDefaults.standard.integer(forKey: "reader_page_\(galleryID)") : 0
            currentPage = min(max((initialPage > 1 ? initialPage : max(initialPage, saved)) - 1, 0), value.pages.count - 1)
            currentPage = ReaderLayout.start(currentPage, count: pagesPerSpread)
            gallery = value
            if !helpHidden { sheet = .help }
            if savesProgress { try? env.database.markOpened(galleryId: galleryID) }
        } catch {
            if !Task.isCancelled { self.error = ContentError.message(error); menuVisible = true }
        }
    }
}

struct ReaderMenuGlass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.glassEffect(.regular.tint(.black.opacity(0.3)).interactive(), in: .rect(cornerRadius: 24))
                .environment(\.colorScheme, .dark)
        } else {
            content.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
                .environment(\.colorScheme, .dark)
        }
    }
}
