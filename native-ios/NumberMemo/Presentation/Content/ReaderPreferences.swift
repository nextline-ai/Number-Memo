import SwiftUI

// A separate defaults suite keeps UI tests from changing the reader preferences on the device.
enum ReaderPreferences {
    static var booruDefaults: UserDefaults {
        #if DEBUG
        if ContentUITestSupport.enabled { return testingBooruDefaults }
        #endif
        return persistentBooruDefaults
    }
    #if DEBUG
    private static let testingBooruDefaults = UserDefaults(suiteName: "com.numbermemo.booru-ui-tests")!
    #endif
    private static let persistentBooruDefaults: UserDefaults = {
        let store = UserDefaults(suiteName: "com.deaum.numbermemo.booru.preferences")!
        if !store.bool(forKey: "booru.preferencesSeparated") {
            // Preserve Booru-only options from the earlier shared store, without importing Hitomi reader options.
            for key in ["booru.original", "booru.showNotes", "booru.rememberHistory", "booru.autoLoad", "booru.fitThumbnails"] {
                if let value = UserDefaults.standard.object(forKey: key), store.object(forKey: key) == nil { store.set(value, forKey: key) }
            }
            store.set(true, forKey: "booru.preferencesSeparated")
        }
        return store
    }()

    static var defaults: UserDefaults {
        #if DEBUG
        if ContentUITestSupport.enabled { return ContentUITestSupport.defaults }
        #endif
        return .standard
    }
}

enum ReaderMode: String, CaseIterable, Identifiable {
    case horizontal, vertical, continuous
    var id: String { rawValue }
    var title: String {
        switch self {
        case .horizontal: return L10n.text("Horizontal Paging")
        case .vertical: return L10n.text("Vertical Paging")
        case .continuous: return L10n.text("Continuous Scroll")
        }
    }
}

struct ReaderSettingsView: View {
    var booru = false
    @Environment(\.dismiss) private var dismiss
    @State private var showHelp = false
    @SwiftUI.AppStorage("booru.original", store: ReaderPreferences.booruDefaults) private var original = false
    @SwiftUI.AppStorage("booru.showNotes", store: ReaderPreferences.booruDefaults) private var showNotes = true
    @SwiftUI.AppStorage("reader.pagesPerSpread", store: ReaderPreferences.defaults) private var pagesPerSpread = 1
    @SwiftUI.AppStorage("reader.autoAdvance", store: ReaderPreferences.defaults) private var autoAdvance = false
    @SwiftUI.AppStorage("reader.autoSeconds", store: ReaderPreferences.defaults) private var autoSeconds = 10.0
    @SwiftUI.AppStorage("reader.mode", store: ReaderPreferences.defaults) private var mode = ReaderMode.horizontal.rawValue
    @SwiftUI.AppStorage("reader.rtl", store: ReaderPreferences.defaults) private var rtl = false
    @SwiftUI.AppStorage("reader.bottomMenu", store: ReaderPreferences.defaults) private var bottomMenu = false
    @SwiftUI.AppStorage("reader.pageNumber", store: ReaderPreferences.defaults) private var pageNumber = false
    @SwiftUI.AppStorage("reader.keepAwake", store: ReaderPreferences.defaults) private var keepAwake = true
    @SwiftUI.AppStorage("reader.prefetch", store: ReaderPreferences.defaults) private var prefetch = 3
    @SwiftUI.AppStorage("reader.dimming", store: ReaderPreferences.defaults) private var dimming = 0.0
    @SwiftUI.AppStorage("reader.tapNavigation", store: ReaderPreferences.defaults) private var tapNavigation = true

    init(booru: Bool = false) {
        self.booru = booru
        let preferences = booru ? ReaderPreferences.booruDefaults : ReaderPreferences.defaults
        _pagesPerSpread = SwiftUI.AppStorage(wrappedValue: 1, "reader.pagesPerSpread", store: preferences)
        _autoAdvance = SwiftUI.AppStorage(wrappedValue: false, "reader.autoAdvance", store: preferences)
        _autoSeconds = SwiftUI.AppStorage(wrappedValue: 10.0, "reader.autoSeconds", store: preferences)
        _mode = SwiftUI.AppStorage(wrappedValue: ReaderMode.horizontal.rawValue, "reader.mode", store: preferences)
        _rtl = SwiftUI.AppStorage(wrappedValue: false, "reader.rtl", store: preferences)
        _bottomMenu = SwiftUI.AppStorage(wrappedValue: false, "reader.bottomMenu", store: preferences)
        _pageNumber = SwiftUI.AppStorage(wrappedValue: false, "reader.pageNumber", store: preferences)
        _keepAwake = SwiftUI.AppStorage(wrappedValue: true, "reader.keepAwake", store: preferences)
        _prefetch = SwiftUI.AppStorage(wrappedValue: 3, "reader.prefetch", store: preferences)
        _dimming = SwiftUI.AppStorage(wrappedValue: 0.0, "reader.dimming", store: preferences)
        _tapNavigation = SwiftUI.AppStorage(wrappedValue: true, "reader.tapNavigation", store: preferences)
    }

    var body: some View {
        NavigationStack {
            Form {
                if booru { Section(L10n.text("Media")) {
                    Toggle(L10n.text("Load Original Images"), isOn: $original)
                    Toggle(L10n.text("Show Notes on Images"), isOn: $showNotes)
                } }
                Section(L10n.text("Page Navigation")) {
                    if !booru { Picker(L10n.text("Reading Mode"), selection: $mode) {
                        ForEach(ReaderMode.allCases) { Text($0.title).tag($0.rawValue) }
                    }.accessibilityIdentifier("reader.settings.mode") }
                    Toggle(L10n.text("Read Right to Left"), isOn: $rtl).accessibilityIdentifier("reader.settings.rtl")
                    Toggle(L10n.text("Tap the Sides to Turn Pages"), isOn: $tapNavigation)
                }
                if !booru { Section(L10n.text("Multiple Pages at Once")) {
                    Picker(L10n.text("Pages per View"), selection: $pagesPerSpread) {
                        ForEach(1...4, id: \.self) { Text(L10n.text("Pages: %@", String(describing: $0))).tag($0) }
                    }.accessibilityIdentifier("reader.settings.spread")
                } }
                Section {
                    Toggle(L10n.text("Auto Advance"), isOn: $autoAdvance).accessibilityIdentifier("reader.settings.auto")
                    Stepper(L10n.text("Advance every %@ seconds", String(describing: Int(autoSeconds))), value: $autoSeconds, in: 2...120, step: 1)
                        .accessibilityIdentifier("reader.settings.seconds").disabled(!autoAdvance)
                } header: { Text(L10n.text("Auto Advance")) } footer: {
                    Text(L10n.text("Pauses while menus, settings, translation, or zoom are active. Stops at the last page."))
                }
                Section(L10n.text("Display")) {
                    Toggle(L10n.text("Show Quick Menu at Bottom"), isOn: $bottomMenu).accessibilityIdentifier("reader.settings.bottomMenu")
                    Toggle(L10n.text("Show Page Number"), isOn: $pageNumber)
                    Toggle(L10n.text("Keep Screen Awake While Reading"), isOn: $keepAwake)
                    VStack(alignment: .leading) {
                        Text(L10n.text("Dim Screen"))
                        Slider(value: $dimming, in: 0...0.65).accessibilityLabel(L10n.text("Dim Screen"))
                    }
                }
                if !booru { Section {
                    Picker(L10n.text("Prefetch Pages"), selection: $prefetch) {
                        Text(L10n.text("Off")).tag(0)
                        Text(L10n.text("2 Pages")).tag(2)
                        Text(L10n.text("3 Pages")).tag(3)
                        Text(L10n.text("5 Pages")).tag(5)
                    }
                } header: { Text(L10n.text("Loading Options")) } footer: {
                    Text(L10n.text("Prefetching reduces the wait for the next page and uses data. Images are kept only in app memory."))
                } }
                Section(L10n.text("Gesture Guide")) {
                    if booru { Text(L10n.text("For videos, tap with two fingers to open the quick menu. Playback controls remain available.")).font(.subheadline).foregroundStyle(.secondary) }
                    if !booru { Button(L10n.text("Reader Guide")) { showHelp = true }.accessibilityIdentifier("reader.settings.help") }
                    Text(L10n.text(booru ? "Tap the center: quick menu\nHold the center: favorite\nTap the sides or swipe: change image\nDouble tap or pinch: zoom\nTranslate: Apple image translation for the visible area\nSwipe down at original zoom: close" : "Tap the center: quick menu\nHold the center: bookmark\nDouble tap or pinch: zoom · Drag while zoomed: move image\nPage number in the quick menu: go to a page"))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color(uiColor: .systemGroupedBackground))
            .toolbarBackground(Color(uiColor: .systemGroupedBackground), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .navigationTitle(L10n.text("Reader Settings")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.text("Done")) { dismiss() }.accessibilityIdentifier("reader.settings.done") } }
        }
        .presentationBackground(Color(uiColor: .systemGroupedBackground))
        .sheet(isPresented: $showHelp) { ReaderHelpView() }
    }
}

struct ReaderHelpView: View {
    @Environment(\.dismiss) private var dismiss
    @SwiftUI.AppStorage("reader.helpHidden", store: ReaderPreferences.defaults) private var hidden = false
    @SwiftUI.AppStorage("reader.rtl", store: ReaderPreferences.defaults) private var rtl = false
    @State private var step = 0
    private let titles = [L10n.text("Read with Taps"), L10n.text("Zoom and Translate"), L10n.text("Exit the Work")]
    private let descriptions = [
        L10n.text("Tap either side to turn pages. Tap the center for the quick menu, or hold it to bookmark."),
        L10n.text("Double tap or pinch to zoom. Drag to position the area you want, then choose Translate in the quick menu."),
        L10n.text("At the original zoom level, swipe down to exit. While zoomed, dragging only moves the image. You can also exit from the quick menu.")
    ]
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Picker(L10n.text("Gesture Guide"), selection: $step) {
                        Text(L10n.text("Taps")).tag(0); Text(L10n.text("Zoom & Translate")).tag(1); Text(L10n.text("Exit")).tag(2)
                    }.pickerStyle(.segmented).accessibilityIdentifier("reader.help.steps")
                    guideImage
                    Text(titles[step]).font(.title3.bold())
                    Text(descriptions[step]).font(.subheadline).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack {
                        ForEach(0..<3) { index in
                            Circle().fill(index == step ? Color.accentColor : Color.secondary.opacity(0.25)).frame(width: 6, height: 6)
                        }
                        Spacer()
                        if step < 2 { Button(L10n.text("Next Tip"), systemImage: "arrow.right") { step += 1 }.accessibilityIdentifier("reader.help.next") }
                    }
                }.padding(16).frame(maxWidth: 460).frame(maxWidth: .infinity)
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 6) {
                    Button(L10n.text("Don't Show Again")) { hidden = true; dismiss() }
                        .buttonStyle(.bordered).accessibilityIdentifier("reader.help.never")
                    Text(L10n.text("You can reopen this guide in Reader Settings or Settings.")).font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity).padding(12).background(Color(uiColor: .systemBackground))
            }
            .navigationTitle(L10n.text("Reader Guide")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.text("Close")) { dismiss() }.accessibilityIdentifier("reader.help.close") } }
        }.presentationBackground(Color(uiColor: .systemBackground))
    }
    private var guideImage: some View {
        Image("ReaderGuide").resizable().aspectRatio(2.0 / 3.0, contentMode: .fit)
            .overlay {
                GeometryReader { geo in
                    let size = geo.size
                    ZStack {
                        if step == 0 {
                            HStack(spacing: 0) {
                                Color.blue.opacity(0.12).frame(width: size.width * 0.3)
                                Color.teal.opacity(0.12).frame(width: size.width * 0.4)
                                Color.blue.opacity(0.12).frame(width: size.width * 0.3)
                            }.padding(.vertical, size.height * 0.1)
                            tip(rtl ? L10n.text("Next") : L10n.text("Previous"), icon: "hand.tap.fill")
                                .position(x: size.width * 0.16, y: size.height * 0.43)
                            tip(L10n.text("Quick Menu"), icon: "hand.tap.fill")
                                .position(x: size.width * 0.5, y: size.height * 0.43)
                            tip(rtl ? L10n.text("Previous") : L10n.text("Next"), icon: "hand.tap.fill")
                                .position(x: size.width * 0.84, y: size.height * 0.43)
                            tip(L10n.text("Hold to bookmark"), icon: "bookmark.fill")
                                .position(x: size.width * 0.5, y: size.height * 0.68)
                        } else if step == 1 {
                            tip(L10n.text("Double tap or pinch to zoom"), icon: "arrow.up.left.and.arrow.down.right")
                                .position(x: size.width * 0.5, y: size.height * 0.27)
                            Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                                .font(.system(size: 56, weight: .light)).foregroundStyle(.white)
                                .padding(20).background(.black.opacity(0.65), in: Circle())
                                .position(x: size.width * 0.5, y: size.height * 0.5)
                            tip(L10n.text("Drag to position"), icon: "hand.draw.fill")
                                .position(x: size.width * 0.5, y: size.height * 0.7)
                            tip(L10n.text("Tap center → Translate"), icon: "translate")
                                .position(x: size.width * 0.5, y: size.height * 0.85)
                        } else {
                            tip(L10n.text("At original zoom"), icon: "arrow.down.right.and.arrow.up.left")
                                .position(x: size.width * 0.5, y: size.height * 0.2)
                            Image(systemName: "arrow.down").font(.system(size: 90, weight: .medium)).foregroundStyle(.white)
                                .padding(24).background(.black.opacity(0.65), in: Capsule())
                                .position(x: size.width * 0.5, y: size.height * 0.48)
                            tip(L10n.text("Swipe down to exit"), icon: "hand.draw.fill")
                                .position(x: size.width * 0.5, y: size.height * 0.77)
                        }
                    }
                }
            }.clipShape(RoundedRectangle(cornerRadius: 18))
            .accessibilityElement(children: .ignore).accessibilityLabel(descriptions[step])
            .accessibilityIdentifier("reader.help.visual")
    }
    private func tip(_ title: String, icon: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.title3)
            Text(title).font(.caption.bold()).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }.foregroundStyle(.white).padding(10).background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 12))
    }
}

enum ReaderLayout {
    static func count(_ value: Int) -> Int { min(4, max(1, value)) }
    static func start(_ page: Int, count: Int) -> Int { max(0, page) / Self.count(count) * Self.count(count) }
    static func next(_ page: Int, delta: Int, count: Int, total: Int) -> Int {
        min(max(0, start(page, count: count) + delta * Self.count(count)), start(max(0, total - 1), count: count))
    }
}

@MainActor
enum ContentBookmarkAction {
    static func toggle(id: Int64, gallery: NativeGallery?, env: AppEnvironment, images: PageImageStore? = nil, context: DiscoveryContext = .unknown) throws -> String {
        if try env.database.getWork(galleryId: id) != nil {
            try env.database.deleteWork(galleryId: id)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            return L10n.text("Bookmark removed")
        }
        return try save(id: id, gallery: gallery, env: env, images: images, context: context)
    }

    static func save(id: Int64, gallery: NativeGallery?, env: AppEnvironment, images: PageImageStore? = nil, context: DiscoveryContext = .unknown) throws -> String {
        if try env.database.getWork(galleryId: id) != nil { return L10n.text("Already bookmarked") }
        let folders = try env.database.listFolders()
        let folder = folders.first(where: { $0.name == "미분류" }) ?? folders.first
        _ = try env.database.upsertWork(galleryId: id, folderId: folder?.id,
            title: gallery?.title, artists: gallery?.artists.joined(separator: ", "),
            language: gallery?.language, type: gallery?.type, tags: gallery?.tags.joined(separator: ", "), metadataSource: "remote", discoveryContext: context)
        if let gallery, let page = gallery.pages.first, let images {
            Task {
                do {
                    let image = try await images.load(page, galleryID: id, thumbnail: true)
                    guard try env.database.getWork(galleryId: id) != nil, let data = image.jpegData(compressionQuality: 0.9) else { return }
                    let url = AppStorage.thumbsDirURL.appendingPathComponent("native_\(id).jpg")
                    try data.write(to: url, options: .atomic)
                    try env.database.setThumb(galleryId: id, status: "ready", path: url.path, page: 1)
                } catch { env.startCoverQueue() }
            }
        }
        #if DEBUG
        if !ContentUITestSupport.enabled && !ContentUITestSupport.unitTestsEnabled { env.startCoverQueue() }
        #else
        env.startCoverQueue()
        #endif
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        return L10n.text("Saved to bookmarks")
    }
}
