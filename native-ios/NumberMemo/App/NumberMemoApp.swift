import SwiftUI
import UIKit

// Animation is a single compositor transform, independent of SwiftUI feed updates.
struct SplashTiming: Equatable {
    let hold: TimeInterval
    let slide: TimeInterval
    static let launch = SplashTiming(hold: 1.2, slide: 1.8)
    static let resume = SplashTiming(hold: 0.6, slide: 0.9)
    var total: TimeInterval { hold + slide }
}

@MainActor private enum SplashArtwork {
    // Decode once, before motion starts; resume reuses the prepared image.
    static let image: UIImage? = {
        let image = UIImage(named: "splash_kr")
        return image?.preparingForDisplay() ?? image
    }()
    static func make(frame: CGRect, identifier: String) -> UIView {
        let cover = UIView(frame: frame)
        cover.backgroundColor = .black; cover.isOpaque = true; cover.clipsToBounds = true
        cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        cover.accessibilityIdentifier = identifier
        if L10n.language == "ko" {
            let artwork = UIImageView(image: image)
            artwork.frame = cover.bounds; artwork.contentMode = .scaleAspectFill
            artwork.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            cover.addSubview(artwork)
        } else {
            let label = UILabel(frame: cover.bounds)
            label.text = L10n.text("Number Memo"); label.textColor = .white
            label.font = .systemFont(ofSize: 48, weight: .bold)
            label.textAlignment = .center; label.adjustsFontSizeToFitWidth = true
            label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            cover.addSubview(label)
        }
        return cover
    }
    static func slide(_ cover: UIView, duration: TimeInterval) {
        UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0.15 : duration,
                       delay: 0, options: [.curveEaseInOut, .beginFromCurrentState]) {
            if UIAccessibility.isReduceMotionEnabled { cover.alpha = 0 }
            else { cover.transform = CGAffineTransform(translationX: 0, y: -cover.bounds.height - 1) }
        }
    }
}

// MARK: - App switcher privacy cover and resume splash
#if os(iOS) && !targetEnvironment(macCatalyst)
@MainActor final class PrivacyCoverManager {
    static let shared = PrivacyCoverManager()
    private var covers: [ObjectIdentifier: UIView] = [:]
    private var generation = 0
    private var cleanup: Task<Void, Never>?
    init() {}
    func show() {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).filter { !$0.isHidden && $0.rootViewController != nil }
        show(in: windows)
    }
    func show(in windows: [UIWindow]) {
        cleanup?.cancel(); cleanup = nil; generation += 1
        UIView.performWithoutAnimation {
            for window in windows {
                let key = ObjectIdentifier(window)
                let cover = covers[key] ?? SplashArtwork.make(frame: window.bounds, identifier: "privacy.cover")
                cover.layer.removeAllAnimations(); cover.transform = .identity; cover.alpha = 1
                cover.frame = window.bounds; cover.isUserInteractionEnabled = true
                cover.accessibilityElementsHidden = false
                window.addSubview(cover); covers[key] = cover
            }
        }
    }
    func hide(timing: SplashTiming = .resume, completion: @escaping @MainActor () -> Void = {}) {
        // Both scenePhase and UIKit notifications can fire for the same activation.
        guard cleanup == nil else { return }
        guard !covers.isEmpty else { completion(); return }
        generation += 1; let current = generation
        cleanup = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(timing.hold))
                guard let self, self.generation == current else { return }
                for cover in self.covers.values {
                    cover.isUserInteractionEnabled = false; cover.accessibilityElementsHidden = true
                    SplashArtwork.slide(cover, duration: timing.slide)
                }
                try await Task.sleep(for: .seconds(UIAccessibility.isReduceMotionEnabled ? 0.2 : timing.slide + 0.05))
                guard self.generation == current else { return }
                for cover in self.covers.values { cover.removeFromSuperview() }
                self.covers.removeAll(); self.cleanup = nil; completion()
            } catch { }
        }
    }
}
#else
@MainActor final class PrivacyCoverManager {
    static let shared = PrivacyCoverManager()
    private init() {}
    func show() {}
    func hide(timing: SplashTiming = .resume, completion: @escaping @MainActor () -> Void = {}) { completion() }
}
#endif

// SwiftUI owns the host's frame/transform. Animate only its child so layout
// updates cannot reinterpret the exit transform as a new placement.
@MainActor final class SplashContainerView: UIView {
    let artwork = SplashArtwork.make(frame: .zero, identifier: "splash.artwork")
    init() {
        super.init(frame: .zero)
        accessibilityIdentifier = "splash.launch"
        addSubview(artwork)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        artwork.bounds = CGRect(origin: .zero, size: bounds.size)
        artwork.center = CGPoint(x: bounds.midX, y: bounds.midY)
    }
}

private struct SplashScreenOverlay: UIViewRepresentable {
    @Binding var isVisible: Bool
    let active: Bool
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> SplashContainerView { SplashContainerView() }
    func updateUIView(_ view: SplashContainerView, context: Context) {
        if active { context.coordinator.start(view.artwork, finished: { isVisible = false }) }
        else { context.coordinator.cancel(view.artwork) }
    }
    static func dismantleUIView(_ view: SplashContainerView, coordinator: Coordinator) { coordinator.cancel(view.artwork) }
    @MainActor final class Coordinator {
        var work: Task<Void, Never>?
        func start(_ view: UIView, finished: @escaping @MainActor () -> Void) {
            guard work == nil else { return }
            work = Task { [weak view] in
                do {
                    try await Task.sleep(for: .seconds(SplashTiming.launch.hold))
                    guard let view else { return }
                    SplashArtwork.slide(view, duration: SplashTiming.launch.slide)
                    try await Task.sleep(for: .seconds(UIAccessibility.isReduceMotionEnabled ? 0.2 : SplashTiming.launch.slide + 0.05))
                    finished()
                } catch { }
            }
        }
        func cancel(_ view: UIView) {
            work?.cancel(); work = nil
            view.layer.removeAllAnimations(); view.transform = .identity; view.alpha = 1
        }
    }
}

// MARK: - Main Application

@MainActor private final class BackgroundLibrarySync {
    private var task: Task<Void, Never>?
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    private var generation = UUID()

    func start(env: AppEnvironment) {
        guard task == nil else { return }
        identifier = UIApplication.shared.beginBackgroundTask(withName: "Save library to iCloud") { [weak self] in
            Task { @MainActor in self?.cancel() }
        }
        guard identifier != .invalid else { return }
        let token = UUID(); generation = token
        task = Task { [weak self] in
            defer { self?.finish(generation: token) }
            do {
                // The foreground task is being cancelled by scenePhase; let it
                // release its sync lock before saving the final local changes.
                while env.sync.syncing { try await Task.sleep(for: .milliseconds(100)) }
                try Task.checkCancellation()
                await env.sync.synchronize(env: env)
            } catch { }
        }
    }
    func cancel() { task?.cancel(); finish() }
    private func finish(generation token: UUID? = nil) {
        guard token == nil || token == generation else { return }
        generation = UUID()
        task = nil
        if identifier != .invalid {
            UIApplication.shared.endBackgroundTask(identifier)
            identifier = .invalid
        }
    }
}

@main
struct NumberMemoApp: App {

    @Environment(\.scenePhase) private var scenePhase
    #if DEBUG
    @State private var env = ContentUITestSupport.enabled || ContentUITestSupport.unitTestsEnabled ? ContentUITestSupport.environment() : AppEnvironment.standard()
    #else
    @State private var env = AppEnvironment.standard()
    #endif

    private var isContentUITest: Bool {
        #if DEBUG
        ContentUITestSupport.enabled || ContentUITestSupport.unitTestsEnabled
        #else
        false
        #endif
    }

    @State private var isSplashScreenVisible = true
    @State private var isResumeSplashVisible = false
    @State private var showChargingSplash = false
    @State private var backgroundSync = BackgroundLibrarySync()
    @State private var launchThermalAllowed = ProcessInfo.processInfo.thermalState != .serious && ProcessInfo.processInfo.thermalState != .critical
    @SwiftUI.AppStorage("booru.rating", store: ReaderPreferences.booruDefaults) private var launchRating: BooruRating = .all
    private struct LaunchRequest: Hashable {
        let active: Bool
        let query: GalleryQuery?
        let site: String
        let servers: [BooruServer]
        let rating: BooruRating
    }
    private var launchRequest: LaunchRequest {
        let enabled = !isContentUITest || ProcessInfo.processInfo.arguments.contains("--launch-warmup-test")
        let servers = env.booru.selectedServers
        let rating = BooruRating.options(for: servers).contains(launchRating) ? launchRating : .all
        return LaunchRequest(active: enabled && scenePhase == .active && launchThermalAllowed && env.isOnboardingCompleted,
                             query: env.isSiteVerified ? env.launchMangaQuery : nil, site: env.mangaSiteAddress,
                             servers: servers, rating: rating)
    }
    private var splashEnabled: Bool { !isContentUITest || ProcessInfo.processInfo.arguments.contains("--splash-ui-test") }
    #if os(iOS) && !targetEnvironment(macCatalyst)
    @State private var previousBatteryState: UIDevice.BatteryState = .unknown
    #endif

    public init() {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        UIDevice.current.isBatteryMonitoringEnabled = true
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                #if DEBUG
                if ContentUITestSupport.libraryJumpTest {
                    NavigationStack {
                        WorksGridView(folder: try? env.database.listFolders().first(where: { $0.name == "이동 테스트" }))
                    }.environment(env)
                } else if isContentUITest && (ProcessInfo.processInfo.arguments.contains("--native-content-tab-test") || BooruUITestSupport.enabled || BooruUITestSupport.liveEnabled) {
                    AppRootTabView().environment(env)
                } else if isContentUITest {
                    NativeContentView(source: ContentUITestSupport.source, savesProgress: false)
                        .environment(env)
                } else {
                    AppRootTabView()
                        .environment(env)
                }
                #else
                AppRootTabView().environment(env)
                #endif

                // White Liquid Charging Splash Animation
                ChargingSplashAnimationView(isTriggered: $showChargingSplash)

                // Cold launch holds 1.2 seconds and slides for 1.8 seconds while active.
                if isSplashScreenVisible && splashEnabled {
                    SplashScreenOverlay(isVisible: $isSplashScreenVisible, active: scenePhase == .active)
                        .zIndex(9999)
                        .ignoresSafeArea()
                }


                #if targetEnvironment(macCatalyst)
                if scenePhase != .active && !isSplashScreenVisible {
                    ZStack { Color.black; Image("splash_kr").resizable().scaledToFill() }
                        .clipped().ignoresSafeArea().zIndex(9998)
                }
                #endif
            }
            .task(id: launchRequest) {
                let request = launchRequest
                guard request.active else { return }
                await env.launchFeeds.run(mangaQuery: request.query, site: request.site, servers: request.servers,
                                          rating: request.rating, preferredMode: env.mode)
            }
            .task(id: "\(scenePhase):\(env.sync.enabled):\(isSplashScreenVisible):\(isResumeSplashVisible)") {
                guard !isContentUITest, scenePhase == .active, !isSplashScreenVisible, !isResumeSplashVisible else { return }
                env.pruneSearchHistory()
                var prepareReports = true
                while !Task.isCancelled {
                    if env.sync.enabled {
                        await env.sync.synchronize(env: env)
                        guard !Task.isCancelled else { return }
                        await env.taste.synchronize(env: env)
                    }
                    if prepareReports { await env.taste.prepareCompletedReports(); prepareReports = false }
                    guard env.sync.enabled else { return }
                    do { try await Task.sleep(for: .seconds(60)) } catch { return }
                }
            }
            .onChange(of: scenePhase, initial: true) { _, phase in
                guard !isContentUITest else { return }
                env.setCoverQueueActive(phase == .active)
                if phase == .active { backgroundSync.cancel() }
                else if phase == .background, env.sync.enabled { backgroundSync.start(env: env) }
            }
            .onChange(of: env.mode) { _, _ in env.setCoverQueueActive(scenePhase == .active) }
            .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
                env.setCoverQueueActive(scenePhase == .active)
            }
            .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)) { _ in
                launchThermalAllowed = ProcessInfo.processInfo.thermalState != .serious && ProcessInfo.processInfo.thermalState != .critical
                env.setCoverQueueActive(scenePhase == .active)
            }
            .preferredColorScheme(env.appTheme.colorScheme)
            .environment(\.locale, Locale(identifier: L10n.language))
            .id(env.appLanguage)
            .task {
                #if os(iOS) && !targetEnvironment(macCatalyst)
                UIDevice.current.isBatteryMonitoringEnabled = true
                previousBatteryState = UIDevice.current.batteryState
                #endif
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
                if !isSplashScreenVisible || !splashEnabled { isResumeSplashVisible = true }
                PrivacyCoverManager.shared.show()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                let timing: SplashTiming = splashEnabled && !isSplashScreenVisible ? .resume : .init(hold: 0, slide: 0)
                PrivacyCoverManager.shared.hide(timing: timing) { isResumeSplashVisible = false }
            }
            #if os(iOS) && !targetEnvironment(macCatalyst)
            .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryStateDidChangeNotification)) { _ in
                let current = UIDevice.current.batteryState
                if (current == .charging || current == .full) && previousBatteryState != .charging && previousBatteryState != .full {
                    if (!isSplashScreenVisible || !splashEnabled) && !isResumeSplashVisible { showChargingSplash = true }
                }
                previousBatteryState = current
            }
            #endif
            .fullScreenCover(isPresented: Binding(
                get: {
                    let allowsOnboarding = !isContentUITest || ProcessInfo.processInfo.arguments.contains("--onboarding-test")
                    return allowsOnboarding && !env.isOnboardingCompleted && (!isSplashScreenVisible || !splashEnabled)
                },
                set: { _ in }
            )) {
                OnboardingView()
                    .environment(env)
            }
        }
    }
}
