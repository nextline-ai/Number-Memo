import SwiftUI

/// The same compact switch occupies the title area of every root navigation bar.
struct AppModeSwitch: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// A tutorial can preview the switch without changing the active library.
    var previewMode: Binding<AppMode>? = nil
    @State private var selection: AppMode?
    private var activeMode: AppMode { previewMode?.wrappedValue ?? env.mode }
    private var current: AppMode { selection ?? activeMode }
    var body: some View {
        HStack(spacing: 2) {
            mode(.hitomi, icon: "book")
            mode(.booru, icon: "photo")
        }
        .background(alignment: .leading) {
            Capsule().fill(.white)
                .frame(width: 42, height: 38)
                .offset(x: current == .hitomi ? 0 : 44)
        }
        .padding(3)
        .glassCapsule(isInteractive: true)
        .highPriorityGesture(DragGesture(minimumDistance: 12).onEnded { change($0.translation.width > 0 ? .booru : .hitomi) })
        .onChange(of: activeMode) { _, mode in selection = mode }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("app.mode")
    }
    private func mode(_ mode: AppMode, icon: String) -> some View {
        Button { change(mode) } label: {
            Image(systemName: current == mode ? icon + ".fill" : icon)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 42, height: 38)
                .foregroundStyle(current == mode ? Color.black : Color.secondary)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("app.mode." + mode.rawValue)
        .accessibilityLabel(mode.title)
        .accessibilityAddTraits(current == mode ? [.isSelected] : [])
    }
    private func change(_ mode: AppMode) {
        guard mode != current else { return }
        // Finish the thumb movement before revealing the other mode's retained navigation tree.
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.22), completionCriteria: .logicallyComplete) {
            selection = mode
        } completion: {
            guard selection == mode else { return }
            if let previewMode { previewMode.wrappedValue = mode }
            else { env.mode = mode }
        }
    }
}

extension View {
    @ViewBuilder func clearTopScrollEdge() -> some View {
        if #available(iOS 26.0, *) { self.scrollEdgeEffectHidden(true, for: .top) }
        else { self }
    }

    func appRootHeader(_ title: String) -> some View {
        self.safeAreaInset(edge: .top, spacing: 0) { ImportReminderBanner() }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { LiquidGlassTitleCapsule(L10n.text(title)) }
                ToolbarItem(placement: .principal) { AppModeSwitch().id(title) }
            }
    }
}

private struct ImportReminderBanner: View {
    @Environment(AppEnvironment.self) private var env
    @SwiftUI.AppStorage("onboarding.importReminderDismissed", store: ReaderPreferences.defaults) private var hidden = false
    @State private var showingImport = false
    var body: some View {
        Group {
            if env.isOnboardingCompleted && !hidden {
                HStack(spacing: 12) {
                    Button {
                        hidden = true
                        showingImport = true
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "square.and.arrow.down").font(.title3)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(L10n.text("Import from Other Apps")).font(.subheadline.weight(.semibold))
                                Text("Anime Boxes · Violet").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityIdentifier("importReminder.open")
                    Button { hidden = true } label: {
                        Image(systemName: "xmark").font(.caption.weight(.semibold)).frame(width: 32, height: 36)
                    }.buttonStyle(.plain).accessibilityLabel(L10n.text("Close")).accessibilityIdentifier("importReminder.close")
                }
                .padding(12).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, 16).padding(.bottom, 8)
            }
        }
        .sheet(isPresented: $showingImport) { OnboardingView(importsOnly: true).environment(env).environment(env.booru) }
    }
}
