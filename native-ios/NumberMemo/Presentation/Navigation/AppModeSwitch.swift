import SwiftUI

/// Shared spacing for compact action groups in the navigation bar.
struct AppToolbarActions<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        HStack(spacing: 16) { content }
            .font(.system(size: 17, weight: .medium))
            .padding(.horizontal, 8)
    }
}

/// The same compact switch occupies the title area of every root navigation bar.
struct AppModeSwitch: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// A tutorial can preview the switch without changing the active library.
    var previewMode: Binding<AppMode>? = nil
    @State private var thumbPosition: CGFloat?
    @State private var dragOrigin: CGFloat?
    @GestureState private var dragging = false
    private var activeMode: AppMode { previewMode?.wrappedValue ?? env.mode }
    private var current: AppMode { activeMode }
    var body: some View {
        Button { change(current == .hitomi ? .booru : .hitomi) } label: {
            HStack(spacing: 2) {
                mode(.hitomi, icon: "book")
                mode(.booru, icon: "photo")
            }
            .background(alignment: .leading) {
                Capsule().fill(.white)
                    .frame(width: 42, height: 38)
                    .offset(x: thumbPosition ?? position(current))
            }
            .padding(3)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassCapsule(isInteractive: true)
        .highPriorityGesture(DragGesture(minimumDistance: 12)
            .updating($dragging) { _, state, _ in state = true }
            .onChanged { value in
                var transaction = Transaction(); transaction.disablesAnimations = true
                withTransaction(transaction) {
                    if dragOrigin == nil { dragOrigin = thumbPosition ?? position(current) }
                    thumbPosition = min(44, max(0, (dragOrigin ?? position(current)) + value.translation.width))
                }
            }
            .onEnded { value in
                let end = (dragOrigin ?? position(current)) + value.predictedEndTranslation.width
                dragOrigin = nil
                change(end > 22 ? .booru : .hitomi)
            })
        .onChange(of: dragging) { _, active in
            guard !active else { return }
            DispatchQueue.main.async {
                // Cancellation has no onEnded callback. Keep the absolute thumb
                // position until it can settle, rather than resetting a translation.
                if !dragging && dragOrigin != nil { dragOrigin = nil; settle(activeMode) }
            }
        }
        .onChange(of: activeMode) { _, mode in
            dragOrigin = nil
            var transaction = Transaction(); transaction.disablesAnimations = true
            withTransaction(transaction) { thumbPosition = position(mode) }
        }
        .onDisappear {
            dragOrigin = nil
            thumbPosition = nil
        }
        .accessibilityLabel(L10n.text("Switch Modes"))
        .accessibilityValue(current.title)
        .accessibilityIdentifier("app.mode")
    }
    private func mode(_ mode: AppMode, icon: String) -> some View {
        Image(systemName: current == mode ? icon + ".fill" : icon)
            .font(.system(size: 16, weight: .semibold))
            .frame(width: 42, height: 38)
            .foregroundStyle(current == mode ? Color.black : Color.secondary)
            .accessibilityHidden(true)
    }
    private func position(_ mode: AppMode) -> CGFloat { mode == .hitomi ? 0 : 44 }
    private func change(_ mode: AppMode) {
        // The shared selection is authoritative immediately. A disappearing
        // toolbar must never commit an older selection from an animation callback.
        if let previewMode { previewMode.wrappedValue = mode }
        else { env.mode = mode }
        settle(mode)
    }
    private func settle(_ mode: AppMode) {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
            thumbPosition = position(mode)
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
