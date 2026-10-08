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
}

private actor ThumbnailLoader {
    let data: Data
    let delay: Duration
    var calls = 0
    var offline = false
    init(data: Data, delay: Duration = .milliseconds(30)) { self.data = data; self.delay = delay }
    func goOffline() { offline = true }
    func load(_ url: URL) async throws -> Data {
        calls += 1
        guard !offline else { throw URLError(.notConnectedToInternet) }
        try await Task.sleep(for: delay)
        return data
    }
}
