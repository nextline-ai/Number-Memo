import SwiftUI

/// Bindings resolve to the current mode; the two libraries keep independent preferences.
struct ModeAppearanceSettings: View {
    @Environment(AppEnvironment.self) private var env
    var body: some View {
        @Bindable var env = env
        Section(L10n.text("Appearance")) {
            Picker(L10n.text("Appearance"), selection: $env.appTheme) {
                ForEach(AppTheme.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).labelsHidden()
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.text("Grid columns: %@", String(env.gridColumns))).font(.subheadline)
                Picker(L10n.text("Grid Columns"), selection: $env.gridColumns) {
                    ForEach(1...5, id: \.self) { Text(String($0)).tag($0) }
                }.pickerStyle(.segmented).accessibilityIdentifier("settings.gridColumns")
            }.padding(.vertical, 4)
        }
    }
}
