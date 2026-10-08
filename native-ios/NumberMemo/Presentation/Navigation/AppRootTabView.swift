import SwiftUI

public struct AppRootTabView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selectedTab: AppTab = .folders
    @State private var didSetup = false

    public init() {}

    public var body: some View {
        RetainedModeContainer(mode: env.mode,
            hitomi: AnyView(hitomiTabs.environment(env).environment(env.booru).environment(\.locale, Locale(identifier: L10n.language)).clearTopScrollEdge()),
            booru: AnyView(BooruRootView(selectedTab: $selectedTab).environment(env).environment(env.booru).environment(\.locale, Locale(identifier: L10n.language)).clearTopScrollEdge()))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .clearTopScrollEdge()
        .toolbarBackground(.hidden, for: .navigationBar)
        .onAppear {
            guard !didSetup else { return }
            didSetup = true
            setupApp()
        }
        .onChange(of: env.isSiteVerified) { _, verified in
            if verified {
                #if DEBUG
                if ContentUITestSupport.enabled { return }
                #endif
                env.startCoverQueue()
            }
        }
    }

    private var hitomiTabs: some View { ComicsRootTabs(selection: $selectedTab) }

    private func setupApp() {
        #if DEBUG
        if ContentUITestSupport.enabled { return }
        #endif
        env.database.syncFoldersToAppGroup()
        env.startCoverQueue()
        observeShareNotifications()
        consumePendingShare()
    }

    private func syncFoldersToAppGroup() {
        env.database.syncFoldersToAppGroup()
    }

    private func observeShareNotifications() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterAddObserver(
            center,
            nil,
            { _, _, _, _, _ in
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .didReceiveShareExtensionNotification, object: nil)
                }
            },
            AppStorage.darwinNotificationName,
            nil,
            .deliverImmediately
        )

        NotificationCenter.default.addObserver(forName: .didReceiveShareExtensionNotification, object: nil, queue: .main) { _ in
            consumePendingShare()
        }
    }

    private func consumePendingShare() {
        let pendingURL = AppStorage.pendingShareURL
        guard FileManager.default.fileExists(atPath: pendingURL.path),
              let data = try? Data(contentsOf: pendingURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String else {
            return
        }

        try? FileManager.default.removeItem(at: pendingURL)

        var folderId = json["folder_id"] as? Int64
        if let newFolderName = json["new_folder_name"] as? String, !newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let created = try? env.database.createFolder(name: newFolderName) {
                folderId = created.id
            }
        }

        let ids = GalleryIDParser.parse(text)
        guard !ids.isEmpty else { return }

        Task {
            for id in ids {
                _ = try? env.database.upsertWork(
                    galleryId: id,
                    folderId: folderId,
                    metadataSource: nil,
                    catalogMatched: false
                )
            }
            env.startCoverQueue()
        }
    }
}

public extension Notification.Name {
    static let didReceiveShareExtensionNotification = Notification.Name("didReceiveShareExtensionNotification")
}

extension View {
    @ViewBuilder
    func adaptableTabStyleIfAvailable() -> some View {
        #if !targetEnvironment(macCatalyst)
        if #available(iOS 18.0, visionOS 2.0, *) {
            self.tabViewStyle(.sidebarAdaptable)
        } else {
            self
        }
        #else
        self
        #endif
    }
}


/// Hide the inactive UIKit tab controller as well as its SwiftUI content. Opacity
/// alone leaves a second tab bar in the accessibility tree on recent iOS versions.
private struct RetainedModeContainer: UIViewControllerRepresentable {
    let mode: AppMode
    let hitomi: AnyView
    let booru: AnyView
    func makeUIViewController(context: Context) -> RetainedModeController { RetainedModeController() }
    func sizeThatFits(_ proposal: ProposedViewSize, uiViewController: RetainedModeController, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height else { return nil }
        return CGSize(width: width, height: height)
    }
    func updateUIViewController(_ controller: RetainedModeController, context: Context) {
        controller.update(mode: mode, hitomi: hitomi, booru: booru)
    }
}

private final class RetainedModeController: UIViewController {
    private var hosts: [AppMode: UIHostingController<AnyView>] = [:]
    private var selected: AppMode = .booru
    override var childForStatusBarHidden: UIViewController? { hosts[selected] }
    override var childForStatusBarStyle: UIViewController? { hosts[selected] }
    func update(mode: AppMode, hitomi: AnyView, booru: AnyView) {
        let changed = selected != mode && hosts[selected] != nil
        selected = mode
        if hosts[mode] == nil {
            let host = UIHostingController(rootView: mode == .hitomi ? hitomi : booru)
            addChild(host)
            host.view.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(host.view)
            NSLayoutConstraint.activate([
                host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                host.view.topAnchor.constraint(equalTo: view.topAnchor),
                host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
            ])
            host.didMove(toParent: self)
            hosts[mode] = host
        }
        if changed && !UIAccessibility.isReduceMotionEnabled {
            UIView.transition(with: view, duration: 0.2, options: [.transitionCrossDissolve, .allowUserInteraction, .beginFromCurrentState]) {
                for (key, host) in self.hosts { host.view.isHidden = key != mode }
            }
        }
        for (key, host) in hosts {
            host.view.isHidden = key != mode
            host.view.accessibilityElementsHidden = key != mode
        }
        setNeedsStatusBarAppearanceUpdate()
    }
}

/// Both libraries share the same destinations, including a persistent recommendation workspace.
struct AppTabLayout<Saved: View, Explore: View, Collections: View, Settings: View>: View {
    @Binding var selection: AppTab
    @Environment(AppEnvironment.self) private var env
    @State private var showingRecap = false
    let mode: AppMode
    let saved: Saved
    let explore: Explore
    let collections: Collections
    let settings: Settings
    private var collectionsTitle: String { L10n.text(mode == .booru ? "Tags" : "Artists") }
    private var collectionsIcon: String { mode == .booru ? "tag" : "person.2" }
    private var settingsTitle: String { L10n.text(mode == .booru ? "More" : "Settings") }
    private var settingsIcon: String { mode == .booru ? "ellipsis" : "gearshape" }
    private var insights: some View {
        NavigationStack { TasteDashboard(mode: mode == .booru ? .booru : .comics, isRoot: true, explore: { selection = .works }) }
    }
    var body: some View {
        VStack(spacing: 0) {
            if let date = env.taste.pendingRecap(tasteMode) {
                TasteRecapBanner(mode: tasteMode, date: date, open: { showingRecap = true }, dismiss: { env.taste.dismissRecap(tasteMode) })
                    .environment(\.timeZone, TimeZone(identifier: env.taste.control.timeZone) ?? .gmt)
                    .fixedSize(horizontal: false, vertical: true)
            }
            tabContent
        }
        .sheet(isPresented: $showingRecap, onDismiss: { env.taste.dismissRecap(tasteMode) }) {
            NavigationStack {
                TasteReportsView(mode: tasteMode, period: .month)
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(L10n.text("Done")) { showingRecap = false } } }
            }
        }
    }
    private var tabContent: some View {
        Group {
            if #available(iOS 18.0, *) {
                TabView(selection: $selection) {
                    Tab(L10n.text("Saved"), systemImage: "folder.fill", value: .folders) { saved }
                    Tab(L10n.text("Explore"), systemImage: "globe", value: .works) { explore }
                    Tab(collectionsTitle, systemImage: collectionsIcon, value: .artists) { collections }
                    Tab(settingsTitle, systemImage: settingsIcon, value: .settings) { settings }
                    Tab(L10n.text("Smart"), systemImage: "apple.intelligence", value: .insights, role: insightsRole) { insights }
                }
            } else {
                TabView(selection: $selection) {
                    saved.tabItem { Label(L10n.text("Saved"), systemImage: "folder.fill") }.tag(AppTab.folders)
                    explore.tabItem { Label(L10n.text("Explore"), systemImage: "globe") }.tag(AppTab.works)
                    collections.tabItem { Label(collectionsTitle, systemImage: collectionsIcon) }.tag(AppTab.artists)
                    settings.tabItem { Label(settingsTitle, systemImage: settingsIcon) }.tag(AppTab.settings)
                    insights.tabItem { Label(L10n.text("Smart"), systemImage: "apple.intelligence") }.tag(AppTab.insights)
                }
            }
        }.adaptableTabStyleIfAvailable()
    }

    private var tasteMode: TasteMode { mode == .booru ? .booru : .comics }
    @available(iOS 18.0, *)
    private var insightsRole: TabRole? {
        #if compiler(>=6.4)
        if #available(iOS 27.0, *) { return .prominent }
        #endif
        // iOS 26 gives the search role the separate trailing glass circle.
        if #available(iOS 26.0, *) { return .search }
        return nil
    }
}

private struct ComicsRootTabs: View {
    @Environment(AppEnvironment.self) private var env
    @Binding var selection: AppTab
    var body: some View {
        AppTabLayout(selection: $selection, mode: .hitomi,
            saved: NavigationStack {
                FoldersView()
                    .safeAreaInset(edge: .top) { if !env.isSiteVerified { ComicsConnectionCard().padding(.horizontal) } }
            },
            explore: exploration,
            collections: NavigationStack { ArtistsListView() },
            settings: NavigationStack { SettingsView() })
    }

    @ViewBuilder private var exploration: some View {
        if env.isSiteVerified { ContentEntryView(embedded: true) }
        else {
            NavigationStack {
                Group {
                    if env.booru.servers.isEmpty { ComicsSetupView() }
                    else { ComicsPoolsView() }
                }.appRootHeader("Explore")
            }
        }
    }

}
