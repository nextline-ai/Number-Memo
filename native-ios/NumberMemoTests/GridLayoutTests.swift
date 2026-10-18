import XCTest
import SwiftUI
import GRDB
@testable import NumberMemo

final class GridLayoutTests: XCTestCase {
    @MainActor func testLocalThumbnailsDecodeOnceOffTheRenderingPathAndRespectPixelLimit() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let data = UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 2400), format: format).pngData { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 1200, height: 2400))
        }
        try data.write(to: url)
        let cache = LocalThumbnailCache(maximumPixelSize: 160)
        // View evaluation must not synchronously read and decode even a valid file.
        XCTAssertNil(cache.image(forPath: url.path))
        let images = await withTaskGroup(of: UIImage?.self) { group in
            for _ in 0..<20 { group.addTask { await cache.load(forPath: url.path) } }
            var results: [UIImage] = []
            for await image in group { if let image { results.append(image) } }
            return results
        }
        let image = try XCTUnwrap(images.first)
        XCTAssertEqual(images.count, 20)
        XCTAssertTrue(images.allSatisfy { $0 === image }, "Concurrent cells share one decoded image")
        XCTAssertEqual(image.cgImage?.width, 80)
        XCTAssertEqual(image.cgImage?.height, 160)
        XCTAssertTrue(cache.image(forPath: url.path) === image)

        cache.invalidate(path: url.path)
        XCTAssertNil(cache.image(forPath: url.path))
        let refreshed = await cache.load(forPath: url.path)
        XCTAssertNotNil(refreshed)
        XCTAssertFalse(refreshed === image)
        cache.clear()
        XCTAssertNil(cache.image(forPath: url.path))
    }

    @MainActor func testVisibleThumbnailReloadsWhenTheSameFileIsReplaced() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: url); LocalThumbnailCache.shared.invalidate(path: url.path) }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        func writeImage(width: CGFloat, height: CGFloat) throws {
            try UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).pngData { context in
                UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            }.write(to: url, options: .atomic)
        }
        try writeImage(width: 80, height: 160)
        let imageView = UIImageView()
        let view = LocalThumbnailView(path: url.path) { image in
            LocalThumbnailProbe(image: image, imageView: imageView)
        }
        let host = UIHostingController(rootView: view)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        // Observe what the hosted view actually displays. Fulfilling an
        // expectation inside onChange and immediately invalidating the file
        // can trigger SwiftUI's per-frame onChange limit in this test harness.
        func waitForDisplayedWidth(_ width: CGFloat) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while imageView.image?.size.width != width && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(imageView.image?.size.width, width)
        }
        try await waitForDisplayedWidth(80)
        try writeImage(width: 160, height: 80)
        LocalThumbnailCache.shared.invalidate(path: url.path)
        try await waitForDisplayedWidth(160)
        XCTAssertTrue(imageView.image === LocalThumbnailCache.shared.image(forPath: url.path))
    }

    func testLocalThumbnailFailuresDoNotPoisonLaterLoads() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        let cache = LocalThumbnailCache()
        let missing = await cache.load(forPath: url.path)
        XCTAssertNil(missing)
        let invalid = Data("not an image".utf8)
        try invalid.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let corrupt = await cache.load(forPath: url.path)
        XCTAssertNil(corrupt)
    }

    @MainActor func testCancelingLastThumbnailConsumerSkipsQueuedDecodeAndRemainsRetryable() async throws {
        let url = try makeThumbnailFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let queue = OperationQueue(); queue.isSuspended = true
        defer { queue.isSuspended = false }
        let cache = LocalThumbnailCache(decodeQueue: queue)
        let cancelled = expectation(description: "Cancelled cell returns before decoder runs")
        let caller = Task {
            let image = await cache.load(forPath: url.path)
            XCTAssertNil(image)
            cancelled.fulfill()
        }
        await waitForThumbnailConsumers(1, cache: cache, path: url.path)
        caller.cancel()
        await fulfillment(of: [cancelled], timeout: 3)
        XCTAssertEqual(cache.pendingConsumerCount(forPath: url.path), 0)
        XCTAssertTrue(queue.operations.allSatisfy(\.isCancelled), "Offscreen queued files must not be decoded")
        XCTAssertNil(cache.image(forPath: url.path))

        queue.isSuspended = false
        let returningCellImage = await cache.load(forPath: url.path)
        XCTAssertNotNil(returningCellImage, "A cancelled request must not poison the same path")
    }

    @MainActor func testCancelingOneThumbnailConsumerKeepsSharedDecodeAlive() async throws {
        let url = try makeThumbnailFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let queue = OperationQueue(); queue.isSuspended = true
        defer { queue.isSuspended = false }
        let cache = LocalThumbnailCache(decodeQueue: queue)
        let cancelled = expectation(description: "First consumer cancels independently")
        let first = Task {
            let image = await cache.load(forPath: url.path)
            XCTAssertNil(image)
            cancelled.fulfill()
        }
        let visible = Task { await cache.load(forPath: url.path) }
        await waitForThumbnailConsumers(2, cache: cache, path: url.path)
        XCTAssertEqual(queue.operationCount, 1, "Both cells must share one queued decode")
        first.cancel()
        await fulfillment(of: [cancelled], timeout: 3)
        XCTAssertEqual(cache.pendingConsumerCount(forPath: url.path), 1)
        XCTAssertFalse(try XCTUnwrap(queue.operations.first).isCancelled)

        queue.isSuspended = false
        let image = await visible.value
        XCTAssertNotNil(image)
        XCTAssertTrue(image === cache.image(forPath: url.path))
    }

    @MainActor private func makeThumbnailFixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let data = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 80), format: format).pngData { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 40, height: 80))
        }
        try data.write(to: url)
        return url
    }

    private func waitForThumbnailConsumers(_ count: Int, cache: LocalThumbnailCache, path: String) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while cache.pendingConsumerCount(forPath: path) != count && ContinuousClock.now < deadline {
            await Task.yield()
        }
        XCTAssertEqual(cache.pendingConsumerCount(forPath: path), count)
    }

    func testObservedLibrarySnapshotsIncludeThumbnailAndFolderEdits() async throws {
        let database = try AppDatabase.inMemory()
        let folder = try database.createFolder(name: "Snapshot test")
        let folderID = try XCTUnwrap(folder.id)
        _ = try database.upsertWork(galleryId: 42, folderId: folderID, title: "Original")
        let observation = ValueObservation.tracking { db in
            try (AppDatabase.fetchWorks(db, folderId: folderID), AppDatabase.fetchFolders(db), AppDatabase.fetchFolderPreviews(db))
        }
        var values = observation.values(in: database.dbWriter).makeAsyncIterator()
        let initial = try await values.next()
        XCTAssertEqual(initial?.0.first?.galleryId, 42)
        XCTAssertEqual(initial?.2[folderID]?.first?.galleryId, 42)

        try database.setThumb(galleryId: 42, status: "gone")
        let thumbnail = try await values.next()
        XCTAssertEqual(thumbnail?.0.first?.thumbStatus, "gone")
        XCTAssertEqual(thumbnail?.2[folderID]?.first?.thumbStatus, "gone")

        try database.setFolderColor(id: folderID, color: 0xFF123456)
        let recolored = try await values.next()
        XCTAssertEqual(recolored?.0.first?.folders.first?.color, 0xFF123456)
        XCTAssertEqual(recolored?.1.first { $0.id == folderID }?.color, 0xFF123456)

        try database.deleteWork(galleryId: 42)
        let removed = try await values.next()
        XCTAssertTrue(removed?.0.isEmpty == true)
        XCTAssertEqual(removed?.1.first { $0.id == folderID }?.workCount, 0)
        XCTAssertNil(removed?.2[folderID])
    }

    func testLargeLibrariesLoadFolderMembershipWithoutPerWorkSQLParameters() throws {
        let database = try AppDatabase.inMemory()
        let folderID = try XCTUnwrap(try database.listFolders().first?.id)
        let count = 32_770
        try database.dbWriter.write { db in
            try db.execute(sql: """
                WITH RECURSIVE ids(value) AS (
                    SELECT 1 UNION ALL SELECT value + 1 FROM ids WHERE value < ?
                )
                INSERT INTO works (gallery_id, title, bookmarked_at)
                SELECT value, 'Work ' || value, '2026-10-18' FROM ids
                """, arguments: [count])
            try db.execute(sql: "INSERT INTO folder_works (folder_id, work_id, added_at) SELECT ?, id, bookmarked_at FROM works", arguments: [folderID])
        }
        let works = try database.listWorks(folderId: folderID)
        XCTAssertEqual(works.count, count)
        XCTAssertTrue(works.allSatisfy { $0.folders.first?.id == folderID })
        XCTAssertEqual(try database.listWorks(query: "Work 32770").map(\.galleryId), [32770])
    }

    @MainActor func testAutomaticAndManualColumnsFollowContainerWidth() async throws {
        // Render the real shared grid at phone, split-window, and full iPad/Mac widths.
        for (width, setting, minimum, expected) in [(390.0, 0, 160.0, 2), (768, 0, 160, 4), (1024, 0, 160, 5), (1366, 0, 160, 7), (390, 3, 160, 3), (1024, 2, 160, 2), (768, 0, 240, 2), (1024, 0, 240, 3), (1366, 0, 240, 5)] {
            var frames: [Int: CGRect] = [:]
            let view = GridProbe(columns: setting, minimum: minimum) { frames = $0 }.frame(width: width, height: 900)
            let host = UIHostingController(rootView: view)
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
            let window = UIWindow(windowScene: scene)
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer { window.isHidden = true; window.rootViewController = nil }
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            host.view.layoutIfNeeded()
            let first = try XCTUnwrap(frames[0], "width \(width)")
            let row = frames.values.filter { abs($0.minY - first.minY) < 1 }
            XCTAssertEqual(row.count, expected, "width \(width), setting \(setting)")
            XCTAssertTrue(frames.values.allSatisfy { $0.minX >= 15 && $0.maxX <= width - 15 })
        }
    }

    @MainActor func testFolderPreviewHeightGrowsWithWidth() throws {
        let folder = try XCTUnwrap(try AppDatabase.inMemory().listFolders().first)
        let host = UIHostingController(rootView: FolderBentoCardView(folder: folder))
        let small = host.sizeThatFits(in: CGSize(width: 180, height: 2000))
        let large = host.sizeThatFits(in: CGSize(width: 360, height: 2000))
        XCTAssertEqual(large.height - small.height, (360 - 180) / 1.25, accuracy: 2)
    }

    @MainActor func testAutomaticPersistsAndModesKeepIndependentChoices() throws {
        let suite = "grid-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let database = try AppDatabase.inMemory()
        let store = try BooruStore()
        let env = AppEnvironment(database: database, browserPreferences: defaults, booru: store)
        XCTAssertEqual(env.gridColumns, 0)
        env.mode = .manga; env.gridColumns = 2; env.folderColumns = 1
        env.mode = .booru; env.gridColumns = 3; env.folderColumns = 4
        env.mode = .manga; XCTAssertEqual(env.gridColumns, 2)
        env.gridColumns = 0
        let reopened = AppEnvironment(database: database, browserPreferences: defaults, booru: store)
        XCTAssertEqual(reopened.gridColumns, 0)
        XCTAssertEqual(reopened.folderColumns, 1)
        reopened.mode = .booru; XCTAssertEqual(reopened.gridColumns, 3)
        XCTAssertEqual(reopened.folderColumns, 4)
    }
}

private struct LocalThumbnailProbe: UIViewRepresentable {
    let image: UIImage?
    let imageView: UIImageView
    func makeUIView(context: Context) -> UIImageView { imageView }
    func updateUIView(_ uiView: UIImageView, context: Context) { uiView.image = image }
}

private struct GridFrames: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct GridProbe: View {
    let columns: Int
    let minimum: CGFloat
    let report: ([Int: CGRect]) -> Void
    var body: some View {
        ScrollView {
            LazyVGrid(columns: WorkGridLayout.columns(columns, minimum: minimum), spacing: 14) {
                ForEach(0..<14) { index in
                    Color.blue.frame(height: 80).background {
                        GeometryReader { geometry in
                            Color.clear.preference(key: GridFrames.self, value: [index: geometry.frame(in: .named("grid"))])
                        }
                    }
                }
            }.padding(16)
        }.coordinateSpace(name: "grid").onPreferenceChange(GridFrames.self, perform: report)
    }
}
