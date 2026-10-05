import Foundation

public enum AppStorage {
    public static let appGroup = "group.com.deaum.numbermemo"
    public static let iCloudContainerId = "iCloud.com.deaum.numbermemo"
    public static let darwinNotificationName = "com.deaum.numbermemo.share" as CFString

    /// Returns the App Group shared container directory if available, or application support directory as fallback.
    public static var sharedContainerURL: URL {
        if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) {
            return container
        }
        let fallback = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("numbermemo", isDirectory: true)
        try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
    }

    public static var localDbURL: URL {
        sharedContainerURL.appendingPathComponent("memo.sqlite")
    }

    public static var thumbsDirURL: URL {
        let dir = sharedContainerURL.appendingPathComponent("thumbs", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutable = dir
            try? mutable.setResourceValues(values)
        }
        return dir
    }

    public static var pendingShareURL: URL {
        sharedContainerURL.appendingPathComponent("pending_share.json")
    }

    public static var foldersJSONURL: URL {
        sharedContainerURL.appendingPathComponent("folders.json")
    }

    /// Exclude item from iCloud backup (for cache/thumbs)
    public static func excludeFromBackup(_ url: URL) {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = url
        try? mutable.setResourceValues(values)
    }
}
