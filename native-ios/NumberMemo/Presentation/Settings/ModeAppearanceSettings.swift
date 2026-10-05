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
            columnPicker("Folder Columns", selection: $env.folderColumns, identifier: "settings.folderColumns")
            columnPicker("Grid Columns", selection: $env.gridColumns, identifier: "settings.gridColumns")
            Text(L10n.text("Automatic adjusts to the window width. Folder and artwork layouts are saved separately on this device."))
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
    private func columnPicker(_ title: String, selection: Binding<Int>, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text(title)).font(.subheadline)
            Picker(L10n.text(title), selection: selection) {
                Text(L10n.text("Automatic")).tag(0)
                ForEach(1...5, id: \.self) { Text(String($0)).tag($0) }
            }.pickerStyle(.segmented).accessibilityIdentifier(identifier)
        }.padding(.vertical, 4)
    }
}
