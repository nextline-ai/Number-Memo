import SwiftUI
import Translation

struct LanguageSettingsSection: View {
    var booru = false
    @Environment(AppEnvironment.self) private var env
    var body: some View {
        @Bindable var env = env
        Section(L10n.text("Language")) {
            Picker(L10n.text("App Language"), selection: $env.appLanguage) {
                Text(L10n.text("System Language")).tag("system")
                Text("English").tag("en")
                Text("한국어").tag("ko")
                Text("日本語").tag("ja")
            }.accessibilityIdentifier("settings.appLanguage")
            NavigationLink { TranslationLanguageSettings(booru: booru) } label: {
                Label(L10n.text("Translation Language"), systemImage: "character.bubble")
            }.accessibilityIdentifier("settings.translationLanguage")
        }
    }
}

enum ReaderTranslationLanguage {
    static func preference(booru: Bool) -> String {
        (booru ? ReaderPreferences.booruDefaults : ReaderPreferences.defaults).string(forKey: "reader.translationLanguage") ?? "system"
    }
    static func resolved(_ value: String) -> String { value == "system" ? L10n.systemLanguage : value }
    static func name(_ identifier: String) -> String {
        Locale(identifier: L10n.language).localizedString(forIdentifier: identifier) ?? identifier
    }
}

struct TranslationLanguageSettings: View {
    @SwiftUI.AppStorage private var language: String
    @State private var languages: [String] = []
    init(booru: Bool) {
        _language = SwiftUI.AppStorage(wrappedValue: "system", "reader.translationLanguage", store: booru ? ReaderPreferences.booruDefaults : ReaderPreferences.defaults)
    }
    var body: some View {
        List {
            Section {
                option("system", title: L10n.text("System Language"))
            } footer: { Text(L10n.text("By default, images are translated into your device’s language. This preference is saved separately for each mode.")) }
            if #available(iOS 18.0, *) {
                Section(L10n.text("Choose a Language")) {
                    ForEach(languages, id: \.self) { option($0, title: ReaderTranslationLanguage.name($0)) }
                }
            }
        }
        .navigationTitle(L10n.text("Translation Language")).navigationBarTitleDisplayMode(.inline)
        .task {
            if #available(iOS 18.0, *) {
                languages = await LanguageAvailability().supportedLanguages.map(\.minimalIdentifier)
                    .sorted { ReaderTranslationLanguage.name($0).localizedStandardCompare(ReaderTranslationLanguage.name($1)) == .orderedAscending }
            }
        }
    }
    private func option(_ value: String, title: String) -> some View {
        Button { language = value } label: {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                if language == value { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }.contentShape(Rectangle())
        }.accessibilityIdentifier("translation.language." + value).accessibilityAddTraits(language == value ? [.isSelected] : [])
    }
}
