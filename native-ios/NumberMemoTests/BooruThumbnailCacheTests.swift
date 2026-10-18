import XCTest
import UIKit
@testable import NumberMemo

final class BooruThumbnailCacheTests: XCTestCase {
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true) }
    @MainActor private func preview() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 800, height: 400)).image { context in
            UIColor.systemBlue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 800, height: 400))
        }.pngData()!
    }
    func testDiskCacheBoundsRecencyAndClearAcrossRelaunch() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        var disk = BooruThumbnailDiskCache(directory: root, capacity: 8)
        let start = Date(timeIntervalSince1970: 100)
        disk.write(Data([1, 2, 3, 4]), key: "https://private.test/a", now: start)
        disk.write(Data([5, 6, 7, 8]), key: "second", now: start.addingTimeInterval(1))
        XCTAssertNotNil(disk.read("https://private.test/a", now: start.addingTimeInterval(2)))
        disk.write(Data([9, 10, 11, 12]), key: "third", now: start.addingTimeInterval(3))
        XCTAssertNil(disk.read("second"))
        var relaunched = BooruThumbnailDiskCache(directory: root, capacity: 8)
        XCTAssertEqual(relaunched.read("https://private.test/a"), Data([1, 2, 3, 4]))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 2)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.contains("private") })
        relaunched.clear()
        var cleared = BooruThumbnailDiskCache(directory: root)
        XCTAssertNil(cleared.read("third"))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
    @MainActor func testRelaunchUsesDiskPreviewWithoutNetworkAndClearRemovesIt() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let loader = ThumbnailLoader(data: preview())
        let url = URL(string: "https://example.test/preview.png")!, server = BooruServer.presets[0]
        let first = BooruThumbnailCache(directory: root, loadData: { url, _ in try await loader.load(url) })
        let downloaded = try await first.image(url: url, server: server)
        XCTAssertEqual(downloaded.size.width, 600)
        await loader.goOffline()
        let relaunched = BooruThumbnailCache(directory: root, loadData: { url, _ in try await loader.load(url) })
        let restored = try await relaunched.image(url: url, server: server)
        XCTAssertEqual(restored.size, downloaded.size)
        let calls = await loader.calls; XCTAssertEqual(calls, 1)
        await relaunched.clear()
        do { _ = try await relaunched.image(url: url, server: server); XCTFail("Clearing must remove both memory and disk copies") }
        catch { }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
    @MainActor func testSimultaneousCellsShareOneDownloadAndSourcesStaySeparate() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let loader = ThumbnailLoader(data: preview())
        let cache = BooruThumbnailCache(directory: root, loadData: { url, _ in try await loader.load(url) })
        let url = URL(string: "https://example.test/same.png")!, server = BooruServer.presets[0]
        async let one = cache.image(url: url, server: server)
        async let two = cache.image(url: url, server: server)
        let images = try await [one, two]
        XCTAssertEqual(images[0].size, images[1].size)
        let calls = await loader.calls; XCTAssertEqual(calls, 1)
        _ = try await cache.image(url: url, server: BooruServer.presets[1])
        let separatedCalls = await loader.calls; XCTAssertEqual(separatedCalls, 2)
    }
    @MainActor func testCorruptPreviewIsRefetched() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let loader = ThumbnailLoader(data: preview())
        let url = URL(string: "https://example.test/corrupt.png")!, server = BooruServer.presets[0]
        var disk = BooruThumbnailDiskCache(directory: root)
        disk.write(Data("invalid image".utf8), key: server.canonicalAddress + ":" + server.id + ":" + url.absoluteString)
        let cache = BooruThumbnailCache(directory: root, loadData: { url, _ in try await loader.load(url) })
        let image = try await cache.image(url: url, server: server)
        XCTAssertEqual(image.size.width, 600)
        let calls = await loader.calls; XCTAssertEqual(calls, 1)
    }
    @MainActor func testViewerCachesFullPixelsAndDeduplicatesAcrossRelaunch() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let bytes = preview(), loader = ThumbnailLoader(data: preview())
        let url = URL(string: "https://example.test/full.png")!, server = BooruServer.presets[0]
        let cache = BooruViewerImageCache(directory: root, loadData: { url, _ in try await loader.load(url) })
        async let before = cache.data(url: url, server: server)
        async let current = cache.data(url: url, server: server)
        let values = try await [before, current]
        XCTAssertEqual(values[0], bytes); XCTAssertEqual(values[1], bytes)
        XCTAssertEqual(UIImage(data: values[0])?.size, UIImage(data: bytes)?.size)
        let calls = await loader.calls; XCTAssertEqual(calls, 1)
        await loader.goOffline()
        let relaunched = BooruViewerImageCache(directory: root, loadData: { url, _ in try await loader.load(url) })
        let restored = try await relaunched.data(url: url, server: server)
        XCTAssertEqual(restored, bytes)
        await relaunched.clear()
        do { _ = try await relaunched.data(url: url, server: server); XCTFail("Clear removes original bytes too") } catch { }
    }
    func testViewerNeverUsesPreviewAsFullMedia() {
        let server = BooruServer.presets[0]
        var post = BooruFixtureSource.post(1, server: server)
        post.fileURL = nil; post.sampleURL = nil
        XCTAssertNotNil(post.displayURL)
        XCTAssertNil(post.viewerURL(original: false))
        post.fileURL = URL(string: "https://example.test/animated.gif")
        post.sampleURL = URL(string: "https://example.test/still.jpg")
        post.fileExtension = "gif"
        XCTAssertEqual(post.viewerURL(original: false), post.fileURL)
    }
    @MainActor func testClearDuringDownloadCannotResurrectPreview() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let loader = ThumbnailLoader(data: preview(), delay: .seconds(1))
        let cache = BooruThumbnailCache(directory: root, loadData: { url, _ in try await loader.load(url) })
        let task = Task { try await cache.image(url: URL(string: "https://example.test/late.png")!, server: BooruServer.presets[0]) }
        for _ in 0..<100 {
            if await loader.calls > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let calls = await loader.calls; XCTAssertEqual(calls, 1)
        await cache.clear()
        do { _ = try await task.value; XCTFail("An invalidated request must not repopulate the cache") } catch { }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        XCTAssertTrue(files.isEmpty)
    }
    @MainActor func testPrefetchPopulatesMemoryCacheForImmediateSynchronousRead() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let loader = ThumbnailLoader(data: preview(), delay: .milliseconds(5))
        let cache = BooruThumbnailCache(directory: root, loadData: { url, _ in try await loader.load(url) })
        let url = URL(string: "https://example.test/prefetch.png")!, server = BooruServer.presets[0]
        XCTAssertNil(cache.cachedImage(url: url, server: server))
        cache.prefetch([(url, server)])
        for _ in 0..<100 {
            if cache.cachedImage(url: url, server: server) != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(cache.cachedImage(url: url, server: server))
        let calls = await loader.calls
        XCTAssertEqual(calls, 1)
    }

    @MainActor func testOverlappingPrefetchWindowsShareGlobalConcurrencyLimit() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let loader = ThumbnailLoader(data: preview(), delay: .milliseconds(40))
        let cache = BooruThumbnailCache(directory: root, loadData: { url, _ in try await loader.load(url) })
        let server = BooruServer.presets[0]
        let urls = (0..<8).map { URL(string: "https://example.test/\($0).png")! }
        for _ in 0..<12 { cache.prefetch(urls.map { ($0, server) }) }
        for _ in 0..<300 {
            if urls.allSatisfy({ cache.cachedImage(url: $0, server: server) != nil }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(urls.allSatisfy { cache.cachedImage(url: $0, server: server) != nil })
        let calls = await loader.calls, peak = await loader.peakActive
        XCTAssertEqual(calls, urls.count, "Overlapping cells must share the same work")
        XCTAssertLessThanOrEqual(peak, 2, "The limit must apply across all prefetch calls")
    }

    @MainActor func testCancellingPrefetchDiscardsQueuedWork() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let loader = ThumbnailLoader(data: preview(), delay: .milliseconds(100))
        let cache = BooruThumbnailCache(directory: root, loadData: { url, _ in try await loader.load(url) })
        let server = BooruServer.presets[0]
        cache.prefetch((0..<12).map { (URL(string: "https://example.test/cancel-\($0).png")!, server) })
        for _ in 0..<100 {
            if await loader.calls == 2 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        await cache.cancelPrefetch()
        try await Task.sleep(for: .milliseconds(250))
        let calls = await loader.calls
        XCTAssertEqual(calls, 2, "Leaving the image mode must discard speculative queued downloads")
    }

    @MainActor func testRepeatedPrefetchCancellationKeepsSharedDownloadsWithinLimit() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let loader = ThumbnailLoader(data: preview(), delay: .milliseconds(200))
        let cache = BooruThumbnailCache(directory: root, loadData: { url, _ in try await loader.load(url) })
        let server = BooruServer.presets[0]
        cache.prefetch((0..<8).map { (URL(string: "https://example.test/initial-\($0).png")!, server) })
        for _ in 0..<100 {
            if await loader.calls == 2 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        var finalURLs: [URL] = []
        for wave in 0..<4 {
            await cache.cancelPrefetch()
            finalURLs = (0..<4).map { URL(string: "https://example.test/wave-\(wave)-\($0).png")! }
            cache.prefetch(finalURLs.map { ($0, server) })
            try await Task.sleep(for: .milliseconds(10))
        }
        for _ in 0..<300 {
            if finalURLs.allSatisfy({ cache.cachedImage(url: $0, server: server) != nil }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(finalURLs.allSatisfy { cache.cachedImage(url: $0, server: server) != nil })
        let peak = await loader.peakActive
        XCTAssertLessThanOrEqual(peak, 2, "Cancelled workers must count until their shared downloads finish")
    }
}

final class PageImageDecodeQueueTests: XCTestCase {
    @MainActor func testDecodeQueueLimitsIndependentRequests() async throws {
        let queue = PageImageDecodeQueue(limit: 2), probe = BlockingImageDecodeProbe()
        defer { probe.release() }
        let requests = (0..<8).map { id in Task { try await queue.perform { probe.decode(id) } } }
        try await waitForTwoDecodes(probe)
        XCTAssertEqual(probe.started.count, 2, "Only two independent decodes may enter ImageIO together")
        probe.release()
        var values: [Int] = []
        for request in requests { values.append(try await request.value) }
        XCTAssertEqual(Set(values), Set(0..<8))
        XCTAssertLessThanOrEqual(probe.peak, 2)
    }

    @MainActor func testCancellationSkipsQueuedDecodeAndKeepsRunningPermit() async throws {
        let queue = PageImageDecodeQueue(limit: 2), probe = BlockingImageDecodeProbe()
        defer { probe.release() }
        let first = Task { try await queue.perform { probe.decode(0) } }
        let second = Task { try await queue.perform { probe.decode(1) } }
        try await waitForTwoDecodes(probe)
        first.cancel()
        let obsolete = Task { try await queue.perform { probe.decode(2) } }
        let next = Task { try await queue.perform { probe.decode(3) } }
        await Task.yield()
        obsolete.cancel()
        do { _ = try await obsolete.value; XCTFail("Queued cancelled work must not decode") } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(Set(probe.started), [0, 1], "Cancelling a running decode must not free its slot early")
        probe.release()
        do { _ = try await first.value; XCTFail("The cancelled caller must not receive decoded pixels") } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        let secondValue = try await second.value, nextValue = try await next.value
        XCTAssertEqual(secondValue, 1); XCTAssertEqual(nextValue, 3)
        XCTAssertFalse(probe.started.contains(2))
        XCTAssertLessThanOrEqual(probe.peak, 2)
    }

    @MainActor private func waitForTwoDecodes(_ probe: BlockingImageDecodeProbe) async throws {
        for _ in 0..<200 {
            if probe.started.count >= 2 { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Decode workers did not start")
    }
}

private final class BlockingImageDecodeProbe: @unchecked Sendable {
    private let condition = NSCondition()
    private var blocked = true
    private var active = 0
    private var peakActive = 0
    private var startedIDs: [Int] = []
    var started: [Int] { condition.withLock { startedIDs } }
    var peak: Int { condition.withLock { peakActive } }
    func decode(_ id: Int) -> Int {
        condition.lock()
        active += 1; peakActive = max(peakActive, active); startedIDs.append(id)
        while blocked { condition.wait() }
        active -= 1
        condition.unlock()
        return id
    }
    func release() {
        condition.lock(); blocked = false; condition.broadcast(); condition.unlock()
    }
}

private actor ThumbnailLoader {
    let data: Data
    let delay: Duration
    var calls = 0
    var active = 0
    var peakActive = 0
    var offline = false
    init(data: Data, delay: Duration = .milliseconds(30)) { self.data = data; self.delay = delay }
    func goOffline() { offline = true }
    func load(_ url: URL) async throws -> Data {
        calls += 1
        guard !offline else { throw URLError(.notConnectedToInternet) }
        active += 1; peakActive = max(peakActive, active)
        defer { active -= 1 }
        try await Task.sleep(for: delay)
        return data
    }
}

final class ViewerDownloadLifetimeTests: XCTestCase {
    private let server = BooruServer.presets[0]
    private let url = URL(string: "https://example.test/viewer-original.png")!

    @MainActor private func png(_ color: UIColor) -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }.pngData()!
    }

    @MainActor func testCancelingSpeculationPreservesVisibleOriginalRequest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = png(.blue), loader = ControlledViewerDownload(payloads: [bytes])
        defer { Task { await loader.releaseAll() } }
        let cache = BooruViewerImageCache(directory: root, loadData: { _, _ in await loader.load() })
        let speculative = Task { try await cache.data(url: url, server: server) }
        let visible = Task { try await cache.data(url: url, server: server) }
        try await waitUntil { await cache.consumerCount(url: self.url, server: self.server) == 2 }
        speculative.cancel()
        do { _ = try await speculative.value; XCTFail("Canceled caller must return before the download completes") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        let consumers = await cache.consumerCount(url: url, server: server)
        XCTAssertEqual(consumers, 1)
        await loader.release(1)
        let image = try await visible.value
        XCTAssertEqual(image, bytes)
        let count = await loader.requests
        XCTAssertEqual(count, 1)
    }

    @MainActor func testLastConsumerCancellationAllowsFreshRequestWithoutStaleCacheWrite() async throws {
        try await verifyRestart(clear: false)
    }

    @MainActor func testClearingCacheCancelsConsumersAndRejectsLateResponse() async throws {
        try await verifyRestart(clear: true)
    }

    @MainActor private func verifyRestart(clear: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let oldBytes = png(.blue), newBytes = png(.red)
        let loader = ControlledViewerDownload(payloads: [oldBytes, newBytes])
        defer { Task { await loader.releaseAll() } }
        let cache = BooruViewerImageCache(directory: root, loadData: { _, _ in await loader.load() })
        let old = Task { try await cache.data(url: url, server: server) }
        try await waitUntil { await loader.requests == 1 }
        if clear { await cache.clear() } else { old.cancel() }
        do { _ = try await old.value; XCTFail("The unused consumer must finish immediately") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        let current = Task { try await cache.data(url: url, server: server) }
        try await waitUntil { await loader.requests == 2 }
        // Simulate a transport that finishes after cancellation, out of order.
        await loader.release(2)
        let value = try await current.value
        XCTAssertEqual(value, newBytes)
        await loader.release(1)
        let cached = try await cache.data(url: url, server: server)
        XCTAssertEqual(cached, newBytes)
        let count = await loader.requests
        XCTAssertEqual(count, 2)
    }

    @MainActor private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Viewer download did not reach the expected state")
        throw URLError(.timedOut)
    }
}

private actor ControlledViewerDownload {
    let payloads: [Data]
    private(set) var requests = 0
    private var gates: [Int: CheckedContinuation<Void, Never>] = [:]
    init(payloads: [Data]) { self.payloads = payloads }
    func load() async -> Data {
        requests += 1
        let index = requests
        await withCheckedContinuation { gates[index] = $0 }
        return payloads[min(index - 1, payloads.count - 1)]
    }
    func release(_ request: Int) { gates.removeValue(forKey: request)?.resume() }
    func releaseAll() {
        let pending = gates.values
        gates.removeAll()
        for continuation in pending { continuation.resume() }
    }
}
