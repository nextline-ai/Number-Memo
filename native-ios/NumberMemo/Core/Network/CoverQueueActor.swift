import Foundation
import SwiftUI

@Observable
public final class CoverQueueState: @unchecked Sendable {
    public var isRunning: Bool = false
    public var isPaused: Bool = false
    public var processed: Int = 0
    public var failed: Int = 0
    public var gone: Int = 0
    public var total: Int = 0

    public init() {}
}

public actor CoverQueueActor {
    private let database: AppDatabase
    private let thumbsDir: URL
    private let images = PageImageStore(source: HitomiContentSource.shared)
    private var isRunning: Bool = false
    private var isPaused: Bool = false
    private var kickAgain: Bool = false

    public init(database: AppDatabase, thumbsDir: URL = AppStorage.thumbsDirURL) {
        self.database = database
        self.thumbsDir = thumbsDir
    }

    public func pause() {
        isPaused = true
    }

    public func resume() {
        isPaused = false
    }

    public func start(state: CoverQueueState) async {
        isPaused = false
        if isRunning {
            kickAgain = true
            return
        }
        isRunning = true
        await MainActor.run {
            state.isRunning = true
            state.isPaused = false
            state.processed = 0
            state.failed = 0
            state.gone = 0
        }

        defer {
            isRunning = false
            Task { @MainActor in
                state.isRunning = false
            }
        }

        do {
            let total = try database.countNeedingFill()
            await MainActor.run { state.total = total }

            var attempted = Set<Int64>()

            repeat {
                kickAgain = false
                while !isPaused {
                    let batch = try database.worksNeedingFill(limit: 6, exclude: attempted)
                    if batch.isEmpty { break }

                    for work in batch {
                        if isPaused { break }
                        attempted.insert(work.galleryId)

                        do {
                            try await fetchOne(work.galleryId)
                            await MainActor.run { state.processed += 1 }
                        } catch let error as URLError where error.code == .fileDoesNotExist {
                            await MainActor.run { state.gone += 1 }
                            try? database.setThumb(galleryId: work.galleryId, status: "gone")
                        } catch {
                            await MainActor.run { state.failed += 1 }
                            if (try? database.getWork(galleryId: work.galleryId)?.hasThumb) != true {
                                try? database.setThumb(galleryId: work.galleryId, status: "failed")
                            }
                        }

                        // Politeness delay
                        try? await Task.sleep(nanoseconds: 150_000_000)
                    }
                }
            } while kickAgain && !isPaused
        } catch {
            // Error handling
        }
    }

    public func fetchOne(_ galleryId: Int64) async throws {
        var existing = try database.getWork(galleryId: galleryId)

        // If title or tags are missing, check offline catalog first
        if existing == nil || !existing!.hasTitle || (existing?.tags ?? "").isEmpty {
            if let catalog = try database.getCatalog(galleryId: galleryId) {
                _ = try database.upsertWork(
                    galleryId: galleryId,
                    title: catalog.title,
                    artists: catalog.artists,
                    language: catalog.language,
                    type: catalog.type,
                    series: catalog.series,
                    groups: catalog.groups,
                    tags: catalog.tags,
                    publishedAt: catalog.published,
                    metadataSource: "catalog",
                    catalogMatched: true,
                    overwriteMetadata: false
                )
                existing = try database.getWork(galleryId: galleryId)
            }
        }

        let needTitle = existing == nil || !existing!.hasTitle
        let needCover = existing?.hasThumb != true
        let needTags = (existing?.tags ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        if !needTitle && !needCover && !needTags {
            if existing?.thumbStatus != "ready" {
                try database.setThumb(galleryId: galleryId, status: "ready", path: existing?.thumbPath)
            }
            return
        }

        let gallery = try await HitomiContentSource.shared.gallery(galleryId)
        guard try database.getWork(galleryId: galleryId) != nil else { return }
        _ = try database.upsertWork(
            galleryId: galleryId, title: needTitle ? gallery.title : nil,
            artists: gallery.artists.joined(separator: ", "), language: gallery.language,
            type: gallery.type, tags: gallery.tags.joined(separator: ", "), metadataSource: "hitomi"
        )
        if needCover, !gallery.pages.isEmpty {
            let page = min(max(1, existing?.thumbPage ?? 1), gallery.pages.count)
            let image = try await images.load(gallery.pages[page - 1], galleryID: galleryId, thumbnail: true)
            guard try database.getWork(galleryId: galleryId) != nil, let data = image.jpegData(compressionQuality: 0.9) else { return }
            let file = thumbsDir.appendingPathComponent("native_\(galleryId).jpg")
            try data.write(to: file, options: .atomic)
            try database.setThumb(galleryId: galleryId, status: "ready", path: file.path, page: page)
        }
    }
}
