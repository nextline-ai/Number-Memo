import Foundation

/// Uses the app's supported system language, with English as the development fallback.
enum L10n {
    static var appLanguage = UserDefaults.standard.string(forKey: "app.language") ?? "system"
    static var language: String { ["en", "ko", "ja"].contains(appLanguage) ? appLanguage : Bundle.main.preferredLocalizations.first ?? "en" }
    static var systemLanguage: String { Locale.preferredLanguages.first ?? "en" }
    static var contentLanguage: String {
        switch language { case "ko": return "korean"; case "ja": return "japanese"; default: return "english" }
    }
    static func text(_ key: String, _ arguments: String...) -> String {
        let bundle = Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
        let format = bundle.localizedString(forKey: key, value: key, table: nil)
        return arguments.isEmpty ? format : String(format: format, locale: Locale(identifier: language), arguments: arguments)
    }
    /// Keep the historical database sentinel intact; never rename user data on locale changes.
    static func folderName(_ storedName: String) -> String {
        storedName == "미분류" ? text("Unfiled") : storedName
    }
}
