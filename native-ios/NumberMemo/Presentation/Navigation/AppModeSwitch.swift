import SwiftUI

/// The same compact switch occupies the title area of every root navigation bar.
struct AppModeSwitch: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selection: AppMode?
    private var current: AppMode { selection ?? env.mode }
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
        .onChange(of: env.mode) { _, mode in selection = mode }
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
            if selection == mode { env.mode = mode }
        }
    }
}

extension View {
    @ViewBuilder func clearTopScrollEdge() -> some View {
        if #available(iOS 26.0, *) { self.scrollEdgeEffectHidden(true, for: .top) }
        else { self }
    }

    func appRootHeader(_ title: String) -> some View {
        navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { LiquidGlassTitleCapsule(L10n.text(title)) }
                ToolbarItem(placement: .principal) { AppModeSwitch().id(title) }
            }
    }
}
