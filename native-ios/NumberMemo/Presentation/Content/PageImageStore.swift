import UIKit
import ImageIO

/// Limit CPU-heavy ImageIO work across every reader/feed store. Cancelling a
/// waiter removes queued work; an already running decode keeps its slot until
/// ImageIO returns, so rapid scrolling cannot bypass the limit.
actor PageImageDecodeQueue {
    static let shared = PageImageDecodeQueue()
    private let limit: Int
    private var active = Set<UUID>()
    private var waitingOrder: [UUID] = []
    private var waiting: [UUID: CheckedContinuation<Void, Error>] = [:]

    init(limit: Int = 2) { self.limit = max(1, limit) }

    func perform<Value: Sendable>(_ operation: @escaping @Sendable () throws -> Value) async throws -> Value {
        let id = UUID()
        try await acquire(id)
        defer { release(id) }
        try Task.checkCancellation()
        let task = Task.detached(priority: Task.currentPriority) {
            try Task.checkCancellation()
            return try operation()
        }
        return try await withTaskCancellationHandler {
            let value = try await task.value
            try Task.checkCancellation()
            return value
        } onCancel: { task.cancel() }
    }

    private func acquire(_ id: UUID) async throws {
        try Task.checkCancellation()
        if active.count < limit { active.insert(id); return }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                waitingOrder.append(id)
                waiting[id] = continuation
            }
        } onCancel: { Task { await self.cancelWaiting(id) } }
    }

    private func cancelWaiting(_ id: UUID) {
        guard let continuation = waiting.removeValue(forKey: id) else { return }
        waitingOrder.removeAll { $0 == id }
        continuation.resume(throwing: CancellationError())
    }

    private func release(_ id: UUID) {
        guard active.remove(id) != nil else { return }
        while !waitingOrder.isEmpty {
            let next = waitingOrder.removeFirst()
            guard let continuation = waiting.removeValue(forKey: next) else { continue }
            active.insert(next)
            continuation.resume()
            break
        }
    }
}

actor PageImageStore {
    private let source: any ContentProviding
    private let allowsPrefetch: @Sendable () -> Bool
    // NSCache supports concurrent access; synchronous reads never touch actor state.
    private nonisolated(unsafe) let cache = NSCache<NSString, UIImage>()
    private var disk: BooruThumbnailDiskCache
    private struct Flight {
        let id: UUID
        let task: Task<UIImage, Error>
        var waiters: Set<UUID>
    }
    private var flights: [String: Flight] = [:]

    private static var isTesting: Bool {
        #if DEBUG
        // UI-test app processes do not load XCTest. Their synthetic hashes are
        // reused by different page fixtures and must never share persistent bytes.
        if ContentUITestSupport.enabled { return true }
        #endif
        return ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil || NSClassFromString("XCTestCase") != nil
    }

    init(source: any ContentProviding, diskDirectory: URL? = nil, diskCapacity: Int = 512 * 1024 * 1024,
         allowsPrefetch: @escaping @Sendable () -> Bool = {
             let process = ProcessInfo.processInfo
             return !process.isLowPowerModeEnabled && process.thermalState != .serious && process.thermalState != .critical
         }) {
        self.source = source
        self.allowsPrefetch = allowsPrefetch
        let capacity = diskCapacity > 0 && (diskDirectory != nil || !Self.isTesting) ? diskCapacity : 0
        let dir = diskDirectory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("MangaPageCache", isDirectory: true)
        self.disk = BooruThumbnailDiskCache(directory: dir, capacity: capacity, fileExtension: "page")
        cache.totalCostLimit = 192 * 1024 * 1024
        cache.countLimit = 128
    }

    nonisolated func cachedImage(hash: String, thumbnail: Bool = false) -> UIImage? {
        let key = "\(hash):\(thumbnail)" as NSString
        return cache.object(forKey: key)
    }

    func load(_ page: GalleryPage, galleryID: Int64, thumbnail: Bool = false) async throws -> UIImage {
        try Task.checkCancellation()
        let key = "\(page.hash):\(thumbnail)"
        if let image = cache.object(forKey: key as NSString) { return image }
        let waiter = UUID()
        let task: Task<UIImage, Error>
        if var flight = flights[key] {
            flight.waiters.insert(waiter)
            flights[key] = flight
            task = flight.task
        } else {
            let source = source
            let flightID = UUID()
            task = Task.detached(priority: Task.currentPriority) {
                try Task.checkCancellation()
                let cachedData = await self.diskData(key)
                try Task.checkCancellation()
                if let data = cachedData, let image = try await PageImageDecodeQueue.shared.perform({ Self.decode(data, thumbnail: thumbnail) }) {
                    try Task.checkCancellation()
                    await self.store(image, data: nil, key: key, flightID: flightID)
                    return image
                }
                try Task.checkCancellation()
                let data = try await source.image(page, galleryID: galleryID, thumbnail: thumbnail)
                try Task.checkCancellation()
                guard let image = try await PageImageDecodeQueue.shared.perform({ Self.decode(data, thumbnail: thumbnail) }) else { throw ContentError.unsupportedFormat }
                try Task.checkCancellation()
                await self.store(image, data: data, key: key, flightID: flightID)
                return image
            }
            flights[key] = Flight(id: flightID, task: task, waiters: [waiter])
        }
        return try await withTaskCancellationHandler {
            defer { release(key, waiter: waiter) }
            let image = try await task.value
            try Task.checkCancellation()
            return image
        } onCancel: { Task { await self.release(key, waiter: waiter) } }
    }

    private func diskData(_ key: String) -> Data? {
        !Task.isCancelled && disk.capacity > 0 ? disk.read(key) : nil
    }

    private nonisolated static func decode(_ data: Data, thumbnail: Bool) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: thumbnail ? 480 : 3000,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }

    /// Persist once per shared request, regardless of how many visible/prefetch callers await it.
    private func store(_ image: UIImage, data: Data?, key: String, flightID: UUID) {
        guard flights[key]?.id == flightID, !Task.isCancelled else { return }
        let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
        cache.setObject(image, forKey: key as NSString, cost: cost)
        if disk.capacity > 0, let data { disk.write(data, key: key) }
    }

    /// Decode the original at a higher bounded resolution only for zoom OCR; never OCR translated pixels.
    func translationCrop(_ page: GalleryPage, galleryID: Int64, rect: CGRect) async throws -> UIImage {
        let key = "\(page.hash):false"
        let data: Data
        if disk.capacity > 0, let cached = disk.read(key) { data = cached }
        else {
            let downloaded = try await source.image(page, galleryID: galleryID, thumbnail: false)
            if disk.capacity > 0 { disk.write(downloaded, key: key) }
            data = downloaded
        }
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { throw ContentError.unsupportedFormat }
        return try ReaderTranslationImage.decode(source: source, rect: rect)
    }

    private func release(_ key: String, waiter: UUID) {
        guard var flight = flights[key], flight.waiters.remove(waiter) != nil else { return }
        if flight.waiters.isEmpty { flight.task.cancel(); flights.removeValue(forKey: key) }
        else { flights[key] = flight }
    }

    /// Current and adjacent/next pages are speculatively downloaded in parallel and cancel on navigation.
    func prefetch(_ gallery: NativeGallery, current: Int, count: Int, visibleCount: Int = 1) async {
        guard !Task.isCancelled, allowsPrefetch() else { return }
        let indices = Self.prefetchIndices(total: gallery.pages.count, current: current, count: count, visibleCount: visibleCount)

        await withTaskGroup(of: Void.self) { group in
            var iterator = indices.makeIterator()
            func enqueue(_ index: Int) {
                group.addTask(priority: .utility) { _ = try? await self.load(gallery.pages[index], galleryID: gallery.id) }
            }
            for _ in 0..<3 { if let index = iterator.next() { enqueue(index) } }
            while await group.next() != nil {
                if Task.isCancelled { group.cancelAll(); break }
                if let index = iterator.next() { enqueue(index) }
            }
        }
    }

    nonisolated static func prefetchIndices(total: Int, current: Int, count: Int, visibleCount: Int = 1) -> [Int] {
        guard current >= 0, current < total, count > 0 else { return [] }
        let start = current + min(ReaderLayout.count(visibleCount), total - current)
        let end = start + min(count, total - start)
        var indices = [current] + Array(start..<end)
        if current > 0 { indices.append(current - 1) }
        return indices
    }
}
