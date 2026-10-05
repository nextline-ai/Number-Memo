import UIKit
import ImageIO

actor PageImageStore {
    private let source: any ContentProviding
    private let cache = NSCache<NSString, UIImage>()
    private struct Flight {
        let task: Task<UIImage, Error>
        var waiters: Set<UUID>
    }
    private var flights: [String: Flight] = [:]

    init(source: any ContentProviding) {
        self.source = source
        cache.totalCostLimit = 96 * 1024 * 1024
        cache.countLimit = 48
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
                return UIImage(cgImage: cgImage)
            }
            flights[key] = Flight(task: task, waiters: [waiter])
        }
        return try await withTaskCancellationHandler {
            defer { release(key, waiter: waiter) }
            let image = try await task.value
            try Task.checkCancellation()
            let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
            cache.setObject(image, forKey: key as NSString, cost: cost)
            return image
        } onCancel: { Task { await self.release(key, waiter: waiter) } }
    }

    /// Decode the original at a higher bounded resolution only for zoom OCR; never OCR translated pixels.
    func translationCrop(_ page: GalleryPage, galleryID: Int64, rect: CGRect) async throws -> UIImage {
        let data = try await source.image(page, galleryID: galleryID, thumbnail: false)
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { throw ContentError.unsupportedFormat }
        return try ReaderTranslationImage.decode(source: source, rect: rect)
    }

    private func release(_ key: String, waiter: UUID) {
        guard var flight = flights[key], flight.waiters.remove(waiter) != nil else { return }
        if flight.waiters.isEmpty { flight.task.cancel(); flights.removeValue(forKey: key) }
        else { flights[key] = flight }
    }

    /// Current page wins. At most two speculative downloads run concurrently and cancel on navigation.
    func prefetch(_ gallery: NativeGallery, current: Int, count: Int, visibleCount: Int = 1) async {
        guard gallery.pages.indices.contains(current), count > 0 else { return }
        do {
            _ = try await load(gallery.pages[current], galleryID: gallery.id)
            try Task.checkCancellation()
            var indices = Array((current + 1)..<min(gallery.pages.count, current + ReaderLayout.count(visibleCount) + min(count, 5)))
            if current > 0 { indices.append(current - 1) }
            await withTaskGroup(of: Void.self) { group in
                var iterator = indices.makeIterator()
                func enqueue(_ index: Int) {
                    group.addTask { _ = try? await self.load(gallery.pages[index], galleryID: gallery.id) }
                }
                for _ in 0..<2 { if let index = iterator.next() { enqueue(index) } }
                while await group.next() != nil {
                    if Task.isCancelled { group.cancelAll(); break }
                    if let index = iterator.next() { enqueue(index) }
                }
            }
        } catch { /* Visible page owns error reporting. */ }
    }
}
