import SwiftUI
import UIKit

// MARK: - App switcher privacy cover

#if os(iOS) && !targetEnvironment(macCatalyst)
@MainActor
final class PrivacyCoverManager {
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
        cleanup?.cancel(); cleanup = nil
        generation += 1
        // Attach to the actual app windows: their contents are what UIKit snapshots.
        UIView.performWithoutAnimation {
            for window in windows {
                let key = ObjectIdentifier(window)
                let cover: UIView
                if let existing = covers[key] { cover = existing }
                else {
                    cover = UIView(frame: window.bounds)
                    let artwork = UIImageView(image: UIImage(named: "splash_kr"))
                    artwork.frame = cover.bounds
                    artwork.contentMode = .scaleAspectFill
                    artwork.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                    cover.addSubview(artwork)
                }
                cover.layer.removeAllAnimations()
                cover.transform = .identity
                cover.alpha = 1
                cover.frame = window.bounds
                cover.backgroundColor = .black
                cover.isOpaque = true
                cover.contentMode = .scaleAspectFill
                cover.clipsToBounds = true
                cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                cover.isUserInteractionEnabled = true
                cover.accessibilityElementsHidden = false
                cover.accessibilityIdentifier = "privacy.cover"
                window.addSubview(cover)
                covers[key] = cover
                window.layoutIfNeeded()
            }
        }
    }

    func hide() {
        generation += 1
        let current = generation
        cleanup?.cancel()
        let reduced = UIAccessibility.isReduceMotionEnabled
        for cover in covers.values {
            // The return animation must never intercept the resumed viewer.
            cover.isUserInteractionEnabled = false
            cover.accessibilityElementsHidden = true
            UIView.animate(withDuration: reduced ? 0.15 : 0.35, delay: 0, options: [.curveEaseInOut, .beginFromCurrentState, .allowUserInteraction]) {
                cover.alpha = 0
            }
        }
        // UIKit can interrupt the animation without completing it when a modal
        // viewer resumes. Cleanup is independent of the completion's finished flag.
        cleanup = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            guard let self, self.generation == current else { return }
            for cover in self.covers.values { cover.removeFromSuperview() }
            self.covers.removeAll(); self.cleanup = nil
        }
    }

}

#else
@MainActor
final class PrivacyCoverManager {
    static let shared = PrivacyCoverManager()
    private init() {}
    func show() {}
    func hide() {}
}
#endif

// MARK: - Dedicated Splash Screen Overlay (Guaranteed Surge Animation)

private struct SplashScreenOverlay: View {
    @Binding var isVisible: Bool
    @State private var offset: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                Color.black.ignoresSafeArea()

                if L10n.language == "ko" {
                    Image("splash_kr").resizable().scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottom).clipped()
                } else {
                    Text(L10n.text("Number Memo")).font(.system(size: 48, weight: .bold, design: .rounded))
                        .foregroundStyle(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .offset(y: offset)
            .ignoresSafeArea()
            .task {
                // 1. Hold firmly for 0.6 seconds so the user visibly sees the splash screen
                try? await Task.sleep(nanoseconds: 600_000_000)
                // 2. Rocket / surge upwards off the top of the screen
                withAnimation(.easeInOut(duration: 0.9)) {
                    offset = -proxy.size.height - 200
                }
                // 3. Wait for the surge animation to finish
                try? await Task.sleep(nanoseconds: 950_000_000)
                // 4. Remove splash screen
                isVisible = false
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - Main Application

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
    @State private var showChargingSplash = false
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

                // 100% Guaranteed Splash Screen Overlay (Waits for active foreground, holds 0.6s, surges 1.0s)
                if isSplashScreenVisible && !isContentUITest {
                    SplashScreenOverlay(isVisible: $isSplashScreenVisible)
                        .zIndex(9999)
                        .ignoresSafeArea()
                }

                // App Switcher Privacy Screen (SwiftUI Fallback layer)
                if scenePhase != .active && !isSplashScreenVisible {
                    ZStack(alignment: .bottom) {
                        Color.black.ignoresSafeArea()

                        Image("splash_kr")
                            .resizable()
                            .scaledToFill()
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                            .clipped()
                            .ignoresSafeArea()
                    }
                    .zIndex(9998)
                    .ignoresSafeArea()
                }
            }
            .task(id: "\(scenePhase):\(env.sync.enabled)") {
                guard !isContentUITest, scenePhase == .active else { return }
                var prepareReports = true
                while !Task.isCancelled {
                    if env.sync.enabled {
                        await env.sync.synchronize(env: env)
                        await env.taste.synchronize(env: env)
                    }
                    if prepareReports { await env.taste.prepareCompletedReports(); prepareReports = false }
                    guard env.sync.enabled else { return }
                    do { try await Task.sleep(for: .seconds(15)) } catch { return }
                }
            }
            .onChange(of: scenePhase, initial: true) { _, phase in
                if phase == .active { PrivacyCoverManager.shared.hide(); env.pruneSearchHistory() }
                guard !isContentUITest, phase == .background, env.sync.enabled else { return }
                let taskID = UIApplication.shared.beginBackgroundTask(withName: "Save library to iCloud", expirationHandler: nil)
                Task { await env.sync.synchronize(env: env); if taskID != .invalid { UIApplication.shared.endBackgroundTask(taskID) } }
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
                PrivacyCoverManager.shared.show()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                PrivacyCoverManager.shared.hide()
            }
            #if os(iOS) && !targetEnvironment(macCatalyst)
            .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryStateDidChangeNotification)) { _ in
                let current = UIDevice.current.batteryState
                if (current == .charging || current == .full) && previousBatteryState != .charging && previousBatteryState != .full {
                    showChargingSplash = true
                }
                previousBatteryState = current
            }
            #endif
            .fullScreenCover(isPresented: Binding(
                get: {
                    let allowsOnboarding = !isContentUITest || ProcessInfo.processInfo.arguments.contains("--onboarding-test")
                    return allowsOnboarding && !env.isOnboardingCompleted && (!isSplashScreenVisible || isContentUITest)
                },
                set: { _ in }
            )) {
                OnboardingView()
                    .environment(env)
            }
        }
    }
}
