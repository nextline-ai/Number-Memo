import SwiftUI

struct SearchHistorySection: View {
    let history: [String]
    let saved: [String]
    let open: (String) -> Void
    let star: (String) -> Void
    let remove: (String) -> Void
    let clear: () -> Void
    var identifierPrefix = "history.query."
    @State private var confirmingClear = false
    var body: some View {
        Section {
            ForEach(history, id: \.self) { query in
                HStack {
                    Button { open(query) } label: { Label(query, systemImage: "clock").frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()) }.accessibilityIdentifier(identifierPrefix + query)
                    Button { star(query) } label: { Image(systemName: saved.contains(query) ? "star.fill" : "star").foregroundStyle(.yellow).frame(width: 36, height: 36) }
                        .accessibilityLabel(L10n.text("Saved Searches")).accessibilityIdentifier("history.star." + query)
                }.buttonStyle(.borderless)
                    .swipeActions { Button(L10n.text("Remove"), role: .destructive) { remove(query) } }
            }
        } header: {
            HStack {
                Text(L10n.text("Search History"))
                Spacer()
                Button { confirmingClear = true } label: { Image(systemName: "trash") }
                    .disabled(history.isEmpty).accessibilityLabel(L10n.text("Clear History")).accessibilityIdentifier("history.clear")
            }
        }
        .alert(L10n.text("Clear History?"), isPresented: $confirmingClear) {
            Button(L10n.text("Clear History"), role: .destructive, action: clear)
            Button(L10n.text("Cancel"), role: .cancel) {}
        } message: { Text(L10n.text("Search history will be deleted. Saved searches will be kept.")) }
    }
}

struct SearchHistorySettings: View {
    let booru: Bool
    @SwiftUI.AppStorage private var days: Int
    init(booru: Bool = false) {
        self.booru = booru
        _days = .init(wrappedValue: 3, "search.retentionDays", store: booru ? ReaderPreferences.booruDefaults : ReaderPreferences.defaults)
    }
    var body: some View {
        Section(L10n.text("Search History")) {
            Picker(L10n.text("Keep History"), selection: $days) {
                Text(L10n.text("3 Days")).tag(3)
                Text(L10n.text("7 Days")).tag(7)
                Text(L10n.text("30 Days")).tag(30)
                Text(L10n.text("Always")).tag(0)
            }
        }
    }
}
