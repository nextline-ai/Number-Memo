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

    private var hitomiTabs: some View {
        ZStack(alignment: .bottomTrailing) {
            TabView(selection: $selectedTab) {
                NavigationStack {
                    FoldersView()
                        .safeAreaInset(edge: .top) { if !env.isSiteVerified { ComicsConnectionCard().padding(.horizontal) } }
                }
                .tabItem {
                    Label(L10n.text("Saved"), systemImage: selectedTab == .folders ? "folder.fill" : "folder")
                }
                .tag(AppTab.folders)

                exploration
                .tabItem {
                    Label(L10n.text("Explore"), systemImage: "globe")
                }
                .tag(AppTab.works)

                NavigationStack {
                    ArtistsListView()
                }
                .tabItem {
                    Label(L10n.text("Artists"), systemImage: selectedTab == .artists ? "person.2.fill" : "person.2")
                }
                .tag(AppTab.artists)

                NavigationStack {
                    SettingsView()
                }
                .tabItem {
                    Label(L10n.text("Settings"), systemImage: selectedTab == .settings ? "gearshape.fill" : "gearshape")
                }
                .tag(AppTab.settings)
            }
            .adaptableTabStyleIfAvailable()

        }
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
        selected = mode
        if hosts[mode] == nil {
            let host = UIHostingController(rootView: mode == .hitomi ? hitomi : booru)
            addChild(host); view.addSubview(host.view); host.didMove(toParent: self)
            hosts[mode] = host
        }
        for (key, host) in hosts {
            host.rootView = key == .hitomi ? hitomi : booru
            host.view.isHidden = key != mode
            host.view.accessibilityElementsHidden = key != mode
            host.view.frame = view.bounds
        }
        setNeedsStatusBarAppearanceUpdate()
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        for host in hosts.values { host.view.frame = view.bounds }
    }
}
