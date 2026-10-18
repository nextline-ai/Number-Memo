import UIKit
import ImageIO

actor PageImageStore {
    private let source: any ContentProviding
    private let cache = NSCache<NSString, UIImage>()
    private var disk: BooruThumbnailDiskCache
    private struct Flight {
        let task: Task<(UIImage, Data), Error>
        var waiters: Set<UUID>
    }
    private var flights: [String: Flight] = [:]

    private static var isTesting: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil || NSClassFromString("XCTestCase") != nil
    }

    init(source: any ContentProviding, diskDirectory: URL? = nil, diskCapacity: Int = 512 * 1024 * 1024) {
        self.source = source
        let capacity = diskCapacity > 0 && !Self.isTesting ? diskCapacity : 0
        let dir = diskDirectory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("MangaPageCache", isDirectory: true)
        self.disk = BooruThumbnailDiskCache(directory: dir, capacity: capacity, fileExtension: "page")
        cache.totalCostLimit = 384 * 1024 * 1024
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
        if disk.capacity > 0, let data = disk.read(key),
           let source = CGImageSourceCreateWithData(data as CFData, nil),
           let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnail ? 480 : 3000,
            kCGImageSourceShouldCacheImmediately: true
           ] as CFDictionary) {
            let image = UIImage(cgImage: cgImage)
            let cost = cgImage.bytesPerRow * cgImage.height
            cache.setObject(image, forKey: key as NSString, cost: cost)
            return image
        }
        let waiter = UUID()
        let task: Task<(UIImage, Data), Error>
        if var flight = flights[key] {
            flight.waiters.insert(waiter)
            flights[key] = flight
            task = flight.task
        } else {
            let source = source
            task = Task.detached(priority: .userInitiated) {
                let data = try await source.image(page, galleryID: galleryID, thumbnail: thumbnail)
                try Task.checkCancellation()
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: thumbnail ? 480 : 3000,
                        kCGImageSourceShouldCacheImmediately: true
                      ] as CFDictionary) else { throw ContentError.unsupportedFormat }
                try Task.checkCancellation()
                return (UIImage(cgImage: cgImage), data)
            }
            flights[key] = Flight(task: task, waiters: [waiter])
        }
        return try await withTaskCancellationHandler {
            defer { release(key, waiter: waiter) }
            let (image, data) = try await task.value
            try Task.checkCancellation()
            let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
            cache.setObject(image, forKey: key as NSString, cost: cost)
            if disk.capacity > 0 { disk.write(data, key: key) }
            return image
        } onCancel: { Task { await self.release(key, waiter: waiter) } }
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
        guard gallery.pages.indices.contains(current), count > 0 else { return }
        let visible = ReaderLayout.count(visibleCount)
        let forwardIndices = Array((current + visible)..<min(gallery.pages.count, current + visible + count))
        var indices = [current] + forwardIndices
        if current > 0 { indices.append(current - 1) }

        await withTaskGroup(of: Void.self) { group in
            var iterator = indices.makeIterator()
            func enqueue(_ index: Int) {
                group.addTask { _ = try? await self.load(gallery.pages[index], galleryID: gallery.id) }
            }
            for _ in 0..<3 { if let index = iterator.next() { enqueue(index) } }
            while await group.next() != nil {
                if Task.isCancelled { group.cancelAll(); break }
                if let index = iterator.next() { enqueue(index) }
            }
        }
    }
}
