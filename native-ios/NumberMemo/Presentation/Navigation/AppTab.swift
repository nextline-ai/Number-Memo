import SwiftUI

public enum AppTab: String, CaseIterable, Identifiable, Hashable, Sendable {
    case folders = "folders"
    case works = "works"
    case artists = "artists"
    case settings = "settings"
    case insights = "insights"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .folders: return L10n.text("Folders")
        case .works: return L10n.text("Explore")
        case .artists: return L10n.text("Artists")
        case .settings: return L10n.text("Settings")
        case .insights: return L10n.text("Smart")
        }
    }

    public var icon: String {
        selectedIcon
    }

    public var selectedIcon: String {
        switch self {
        case .folders: return "folder.fill"
        case .works: return "globe"
        case .artists: return "person.2.fill"
        case .settings: return "gearshape.fill"
        case .insights: return "apple.intelligence"
        }
    }

    public var unselectedIcon: String {
        switch self {
        case .folders: return "folder"
        case .works: return "globe"
        case .artists: return "person.2"
        case .settings: return "gearshape"
        case .insights: return "apple.intelligence"
        }
    }
}
