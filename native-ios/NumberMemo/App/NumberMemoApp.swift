import SwiftUI
import UIKit

// MARK: - Bulletproof UIKit Privacy Cover Manager (Guaranteed App Switcher Snapshot Privacy)

#if os(iOS) && !targetEnvironment(macCatalyst)
@MainActor
final class PrivacyCoverManager {
    static let shared = PrivacyCoverManager()
    private var privacyWindow: UIWindow?

    private init() {}

    func show() {
        if let window = privacyWindow {
            window.layer.removeAllAnimations()
            window.transform = .identity
            window.alpha = 1
            return
        }
        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive }) else {
            return
        }

        let window = UIWindow(windowScene: windowScene)
        window.windowLevel = .alert + 10
        window.backgroundColor = .black

        let imageView = UIImageView(frame: window.bounds)
        imageView.image = UIImage(named: "splash_kr")
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        imageView.backgroundColor = .black

        window.addSubview(imageView)
        window.isHidden = false
        self.privacyWindow = window
        // The opaque background covers content immediately for the switcher snapshot.
        // Only the artwork animates; privacy never depends on an animation finishing.
        if !UIAccessibility.isReduceMotionEnabled {
            imageView.transform = CGAffineTransform(translationX: 0, y: 24)
            UIView.animate(withDuration: 0.25) { imageView.transform = .identity }
        }
    }

    func hide() {
        guard let window = privacyWindow else { return }
        let reduced = UIAccessibility.isReduceMotionEnabled
        UIView.animate(withDuration: reduced ? 0.15 : 0.45, delay: 0, options: [.curveEaseInOut, .beginFromCurrentState]) {
            if reduced { window.alpha = 0 }
            else { window.transform = CGAffineTransform(translationX: 0, y: -window.bounds.height) }
        } completion: { [weak self] finished in
            guard finished, self?.privacyWindow === window else { return }
            window.isHidden = true
            self?.privacyWindow = nil
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
                guard !isContentUITest, env.sync.enabled, scenePhase == .active else { return }
                while !Task.isCancelled {
                    await env.sync.synchronize(env: env)
                    do { try await Task.sleep(for: .seconds(15)) } catch { return }
                }
            }
            .onChange(of: scenePhase, initial: true) { _, phase in
                if phase == .active { env.pruneSearchHistory() }
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
