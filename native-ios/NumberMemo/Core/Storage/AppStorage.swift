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
import ImageIO

/// Bounded, coalesced thumbnail decoding. View evaluation only reads memory;
/// ImageIO opens and downsamples files on the operation queue.
public final class LocalThumbnailCache: @unchecked Sendable {
    public static let shared = LocalThumbnailCache()
    static let didInvalidate = Notification.Name("localThumbnailCacheDidInvalidate")
    private let cache = NSCache<NSString, UIImage>()
    private let lock = NSLock()
    private let decodeQueue: OperationQueue
    private struct Request {
        let id: UUID
        let operation: BlockOperation
        var waiters: [UUID: CheckedContinuation<UIImage?, Never>] = [:]
        var prefetched = false
    }
    private var pending: [String: Request] = [:]
    let maximumPixelSize: Int

    init(maximumPixelSize: Int = 768, decodeQueue: OperationQueue = OperationQueue()) {
        self.maximumPixelSize = max(1, maximumPixelSize)
        cache.countLimit = 128
        cache.totalCostLimit = 64 * 1024 * 1024
        self.decodeQueue = decodeQueue
        decodeQueue.name = "work-thumbnail-decode"
        decodeQueue.qualityOfService = .userInitiated
        decodeQueue.maxConcurrentOperationCount = 2
    }

    /// A cache miss never opens a file on the caller's thread.
    public func image(forPath path: String) -> UIImage? {
        cache.object(forKey: path as NSString)
    }

    public func load(forPath path: String) async -> UIImage? {
        if Task.isCancelled { return nil }
        let waiterID = UUID()
        let image = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                enqueue(path: path, waiterID: waiterID, waiter: continuation)
            }
        } onCancel: { cancelLoad(path: path, waiterID: waiterID) }
        return Task.isCancelled ? nil : image
    }

    private func enqueue(path: String, waiterID: UUID? = nil, waiter: CheckedContinuation<UIImage?, Never>? = nil) {
        lock.lock()
        // Check under the same lock used by cancellation so a cancellation
        // arriving before registration cannot leave an orphaned waiter.
        if waiter != nil && Task.isCancelled {
            lock.unlock(); waiter?.resume(returning: nil); return
        }
        if let image = cache.object(forKey: path as NSString) {
            lock.unlock()
            waiter?.resume(returning: image)
            return
        }
        if var request = pending[path] {
            if let waiter, let waiterID { request.waiters[waiterID] = waiter }
            else { request.prefetched = true }
            pending[path] = request
            lock.unlock()
            return
        }
        let requestID = UUID(), operation = BlockOperation()
        var request = Request(id: requestID, operation: operation, prefetched: waiter == nil)
        if let waiter, let waiterID { request.waiters[waiterID] = waiter }
        operation.addExecutionBlock { [self] in
            lock.lock()
            let active = pending[path]?.id == requestID
            lock.unlock()
            guard active else { return }
            let image = autoreleasepool { decode(path: path) }
            lock.lock()
            guard pending[path]?.id == requestID else { lock.unlock(); return }
            let waiters = pending.removeValue(forKey: path)?.waiters.values.map { $0 } ?? []
            if let image, let cgImage = image.cgImage {
                cache.setObject(image, forKey: path as NSString, cost: cgImage.bytesPerRow * cgImage.height)
            }
            lock.unlock()
            for waiter in waiters { waiter.resume(returning: image) }
        }
        pending[path] = request
        lock.unlock()
        decodeQueue.addOperation(operation)
    }

    private func cancelLoad(path: String, waiterID: UUID) {
        lock.lock()
        guard var request = pending[path], let waiter = request.waiters.removeValue(forKey: waiterID) else {
            lock.unlock(); return
        }
        let orphaned = request.waiters.isEmpty && !request.prefetched
        if orphaned { pending.removeValue(forKey: path) }
        else { pending[path] = request }
        lock.unlock()
        // Cancelled queued operations never decode. If ImageIO has already
        // started, OperationQueue retains its physical slot until it returns.
        if orphaned { request.operation.cancel() }
        waiter.resume(returning: nil)
    }

    /// Allows cancellation tests to await registration without timing sleeps.
    func pendingConsumerCount(forPath path: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return pending[path]?.waiters.count ?? 0
    }

    private func decode(path: String) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, sourceOptions) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }

    public func invalidate(path: String) {
        lock.lock()
        cache.removeObject(forKey: path as NSString)
        let request = pending.removeValue(forKey: path)
        lock.unlock()
        request?.operation.cancel()
        for waiter in request?.waiters.values.map({ $0 }) ?? [] { waiter.resume(returning: nil) }
        NotificationCenter.default.post(name: Self.didInvalidate, object: self, userInfo: ["path": path])
    }

    public func prefetch(paths: [String]) {
        for path in Set(paths) { enqueue(path: path) }
    }

    public func clear() {
        lock.lock()
        cache.removeAllObjects()
        let requests = Array(pending.values)
        pending.removeAll()
        lock.unlock()
        for request in requests {
            request.operation.cancel()
            for waiter in request.waiters.values { waiter.resume(returning: nil) }
        }
        NotificationCenter.default.post(name: Self.didInvalidate, object: self)
    }
}
