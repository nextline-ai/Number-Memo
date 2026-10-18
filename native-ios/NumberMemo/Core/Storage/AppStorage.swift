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

import UIKit

/// High-performance thread-safe in-memory cache for local work thumbnails.
/// Prevents redundant synchronous disk I/O and JPEG decoding during SwiftUI view body evaluations.
public final class LocalThumbnailCache: @unchecked Sendable {
    public static let shared = LocalThumbnailCache()
    private let cache = NSCache<NSString, UIImage>()

    private init() {
        // Cache up to 128 thumbnails or 64MB of decoded images
        cache.countLimit = 128
        cache.totalCostLimit = 64 * 1024 * 1024
    }

    public func image(forPath path: String) -> UIImage? {
        let key = path as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        guard let image = UIImage(contentsOfFile: path) else { return nil }
        let cost = (image.cgImage?.bytesPerRow ?? 0) * (image.cgImage?.height ?? 0)
        cache.setObject(image, forKey: key, cost: cost > 0 ? cost : 1024)
        return image
    }

    public func invalidate(path: String) {
        cache.removeObject(forKey: path as NSString)
    }

    public func prefetch(paths: [String]) {
        guard !paths.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            for path in paths {
                let key = path as NSString
                if self.cache.object(forKey: key) != nil { continue }
                guard let image = UIImage(contentsOfFile: path) else { continue }
                let cost = (image.cgImage?.bytesPerRow ?? 0) * (image.cgImage?.height ?? 0)
                self.cache.setObject(image, forKey: key, cost: cost > 0 ? cost : 1024)
            }
        }
    }

    public func clear() {
        cache.removeAllObjects()
    }
}
