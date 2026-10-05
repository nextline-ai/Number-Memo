import XCTest
import SwiftUI
@testable import NumberMemo

final class ReaderUXTests: XCTestCase {
    func testExitRecognizesShortFlickAndRejectsAccidentalDrags() {
        XCTAssertTrue(ReaderDismissal.shouldExit(delta: CGPoint(x: 8, y: 110), velocity: .zero))
        XCTAssertTrue(ReaderDismissal.shouldExit(delta: CGPoint(x: 2, y: 30), velocity: CGPoint(x: 0, y: 700)))
        XCTAssertFalse(ReaderDismissal.shouldExit(delta: CGPoint(x: 2, y: 30), velocity: CGPoint(x: 0, y: 100)))
        XCTAssertFalse(ReaderDismissal.shouldExit(delta: CGPoint(x: 120, y: 80), velocity: CGPoint(x: 800, y: 600)))
        XCTAssertFalse(ReaderDismissal.shouldExit(delta: CGPoint(x: 0, y: -120), velocity: CGPoint(x: 0, y: -800)))
    }

    @MainActor func testLiveTextActionOnlyInvokesTranslateInsideOwnedImage() {
        let image = UIImageView()
        let button = UIButton()
        var translated = false
        var copied = false
        button.menu = UIMenu(children: [
            UIAction(title: "복사") { _ in copied = true },
            UIMenu(children: [UIAction(title: "번역하기") { _ in translated = true }])
        ])
        image.addSubview(button)
        XCTAssertTrue(ReaderLiveTextAction.activate(in: image))
        XCTAssertTrue(translated)
        XCTAssertFalse(copied)
        XCTAssertFalse(ReaderLiveTextAction.activate(in: UIView()))
    }

    @MainActor func testTranslationDoesNotToggleActiveOrDisabledActions() {
        let root = UIView()
        let button = UIButton()
        var calls = 0
        button.menu = UIMenu(children: [UIAction(title: "翻訳", state: .on) { _ in calls += 1 }])
        root.addSubview(button)
        XCTAssertTrue(ReaderLiveTextAction.activate(in: root))
        XCTAssertEqual(calls, 0)
        button.isEnabled = false
        XCTAssertFalse(ReaderLiveTextAction.activate(in: root))
        button.isEnabled = true
        button.menu = UIMenu(children: [UIAction(title: "Translate", attributes: .disabled) { _ in calls += 1 }])
        XCTAssertFalse(ReaderLiveTextAction.activate(in: root))
        XCTAssertEqual(calls, 0)
        let identifiedControl = UIButton()
        identifiedControl.accessibilityIdentifier = "ImageAnalysis.Translate"
        identifiedControl.addAction(UIAction { _ in calls += 1 }, for: .primaryActionTriggered)
        root.addSubview(identifiedControl)
        XCTAssertTrue(ReaderLiveTextAction.activate(in: root))
        XCTAssertEqual(calls, 1)
        identifiedControl.isSelected = true
        XCTAssertTrue(ReaderLiveTextAction.activate(in: root))
        XCTAssertEqual(calls, 1)
    }

    @MainActor func testShortZoomedPageHasVerticalSpaceAndRestoresParentScrolling() {
        let parent = UIScrollView(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        let page = PageScrollView()
        page.frame = parent.bounds
        parent.addSubview(page)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 400)).image { _ in }
        page.update(image: image)
        page.layoutIfNeeded()
        page.setZoomScale(2.5, animated: false)
        page.layoutIfNeeded()
        XCTAssertEqual(page.contentInset.top, 400, accuracy: 1)
        XCTAssertEqual(page.contentInset.bottom, 400, accuracy: 1)
        XCTAssertEqual(page.contentInset.left, 200, accuracy: 1)
        XCTAssertEqual(page.contentInset.right, 200, accuracy: 1)
        XCTAssertFalse(parent.isScrollEnabled)
        let verticalRange = page.contentSize.height + page.contentInset.top + page.contentInset.bottom - page.bounds.height
        XCTAssertGreaterThan(verticalRange, 300, "Even a short landscape page must pan vertically")
        page.setZoomScale(1, animated: false)
        page.layoutIfNeeded()
        XCTAssertTrue(parent.isScrollEnabled)
        XCTAssertFalse(page.panGestureRecognizer.isEnabled)
        XCTAssertEqual(page.contentInset.top, page.contentInset.bottom)
    }

    @MainActor func testTwoZoomedPagesKeepTheirSharedPagerLocked() {
        let parent = UIScrollView(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        let pages = [PageScrollView(), PageScrollView()]
        let image = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 1200)).image { _ in }
        for page in pages {
            page.frame = parent.bounds
            parent.addSubview(page)
            page.update(image: image)
            page.layoutIfNeeded()
            page.setZoomScale(2, animated: false)
        }
        pages[0].setZoomScale(1, animated: false)
        XCTAssertFalse(parent.isScrollEnabled)
        pages[1].setZoomScale(1, animated: false)
        XCTAssertTrue(parent.isScrollEnabled)
    }

    @MainActor func testExploreBookmarkTogglesOnOffAndOn() throws {
        let env = AppEnvironment.preview()
        let id: Int64 = 900000001
        _ = try ContentBookmarkAction.toggle(id: id, gallery: nil, env: env)
        XCTAssertNotNil(try env.database.getWork(galleryId: id))
        XCTAssertEqual(try ContentBookmarkAction.toggle(id: id, gallery: nil, env: env), L10n.text("Bookmark removed"))
        XCTAssertNil(try env.database.getWork(galleryId: id))
        _ = try ContentBookmarkAction.toggle(id: id, gallery: nil, env: env)
        XCTAssertEqual(try env.database.listWorks().filter { $0.galleryId == id }.count, 1)
    }

    @MainActor func testRefreshKeepsResultsOnFailureAndRestartsAtFirstPage() async {
        let source = RefreshContentSource()
        let loader = GalleryFeedLoader(source: source)
        await loader.load(GalleryQuery(), reset: true).value
        XCTAssertEqual(loader.ids, [1])
        await loader.load(GalleryQuery(), reset: false).value
        XCTAssertEqual(loader.ids, [1, 2])
        await source.setFailure(true)
        let refresh = loader.load(GalleryQuery(), reset: true)
        XCTAssertEqual(loader.ids, [1, 2])
        await refresh.value
        XCTAssertEqual(loader.ids, [1, 2])
        XCTAssertNotNil(loader.error)
        await source.setFailure(false)
        await loader.retry(GalleryQuery()).value
        XCTAssertEqual(loader.ids, [1])
        XCTAssertNil(loader.error)
        let offsets = await source.offsets
        XCTAssertEqual(offsets, [0, 1, 0, 0])
    }

    @MainActor func testRefreshSurvivesRefreshableCallerCancellation() async {
        let loader = GalleryFeedLoader(source: RefreshContentSource())
        await loader.load(GalleryQuery(), reset: true).value
        let caller = Task { await loader.load(GalleryQuery(), reset: true).value }
        caller.cancel()
        await caller.value
        XCTAssertEqual(loader.ids, [1])
        XCTAssertFalse(loader.loading)
        XCTAssertNil(loader.error)
    }

    @MainActor func testNewFilterRejectsLateResultsFromCancelledQuery() async {
        let loader = GalleryFeedLoader(source: RefreshContentSource())
        let previous = loader.load(GalleryQuery(language: "english"), reset: true)
        await Task.yield()
        let latest = loader.load(GalleryQuery(), reset: true)
        await latest.value
        await previous.value
        XCTAssertEqual(loader.ids, [1])
        XCTAssertFalse(loader.loading)
        XCTAssertNil(loader.error)
    }

    func testConcurrentLoadsShareDownloadAndDecodedImage() async throws {
        let source = CountingContentSource()
        let gallery = try await source.gallery(1)
        let store = PageImageStore(source: source)
        async let first = store.load(gallery.pages[0], galleryID: 1)
        async let second = store.load(gallery.pages[0], galleryID: 1)
        let pair = try await (first, second)
        XCTAssertTrue(pair.0 === pair.1)
        let count = await source.requests
        XCTAssertEqual(count, 1)
    }

    func testPrefetchEliminatesNextPageDownload() async throws {
        let source = CountingContentSource()
        let gallery = try await source.gallery(1)
        let store = PageImageStore(source: source)
        await store.prefetch(gallery, current: 0, count: 2)
        let before = await source.requests
        let start = ContinuousClock.now
        _ = try await store.load(gallery.pages[1], galleryID: 1)
        let duration = start.duration(to: .now)
        let after = await source.requests
        XCTAssertEqual(before, 3)
        XCTAssertEqual(before, after)
        print("READER_CACHE_HIT_DURATION=\(duration)")
    }

    func testCancellingOneConsumerKeepsSharedDownloadAlive() async throws {
        let source = CountingContentSource()
        let gallery = try await source.gallery(1)
        let store = PageImageStore(source: source)
        let first = Task { try await store.load(gallery.pages[0], galleryID: 1) }
        let second = Task { try await store.load(gallery.pages[0], galleryID: 1) }
        try await Task.sleep(for: .milliseconds(50))
        first.cancel()
        do { _ = try await first.value; XCTFail("Cancelled consumer must not receive an image") } catch {}
        _ = try await second.value
        let count = await source.requests
        XCTAssertEqual(count, 1)
    }

    func testChunkedTransportEnforcesBodyLimitAndStatus() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ContentFixtureURLProtocol.self]
        let transport = ContentTransport(configuration: configuration)
        let root = "https://ltn.gold-usergeneratedcontent.net/"
        let (data, response) = try await transport.get(URL(string: root + "small")!, limit: 16)
        XCTAssertEqual(data, Data([1, 2, 3, 4, 5, 6]))
        XCTAssertEqual(response.statusCode, 200)
        do { _ = try await transport.get(URL(string: root + "small")!, limit: 4); XCTFail("Must reject streamed overflow") }
        catch ContentError.tooLarge {} catch { XCTFail("Wrong error: \(error)") }
        do { _ = try await transport.get(URL(string: root + "missing")!, limit: 16); XCTFail("Must reject 404") }
        catch ContentError.unavailable(404) {} catch { XCTFail("Wrong error: \(error)") }
        let task = Task { try await transport.get(URL(string: root + "small")!, limit: 16) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Must cancel") } catch {}
    }

    func testOCRFindsSyntheticPageText() async throws {
        let source = FixtureContentSource()
        let gallery = try await source.gallery(1)
        let image = try await PageImageStore(source: source).load(gallery.pages[0], galleryID: 1)
        let regions = try await ReaderTextRecognizer.shared.recognize(image)
        XCTAssertTrue(regions.map(\.text).joined(separator: " ").contains("Native Reader"))
        XCTAssertTrue(regions.allSatisfy { $0.bounds.width > 0 && $0.bounds.height > 0 })
    }

    @MainActor func testBookmarkIsIdempotentAndPreservesFolders() throws {
        let env = AppEnvironment.preview()
        XCTAssertEqual(try ContentBookmarkAction.save(id: 900000001, gallery: nil, env: env), L10n.text("Saved to bookmarks"))
        XCTAssertEqual(try ContentBookmarkAction.save(id: 900000001, gallery: nil, env: env), L10n.text("Already bookmarked"))
        XCTAssertEqual(try env.database.listWorks().filter { $0.galleryId == 900000001 }.count, 1)
    }
}

private actor CountingContentSource: ContentProviding {
    private let fixture = FixtureContentSource()
    private(set) var requests = 0
    func gallery(_ id: Int64) async throws -> NativeGallery { try await fixture.gallery(id) }
    func list(_ query: GalleryQuery, offset: Int, count: Int) async throws -> GalleryBatch { try await fixture.list(query, offset: offset, count: count) }
    func image(_ page: GalleryPage, galleryID: Int64, thumbnail: Bool) async throws -> Data {
        requests += 1
        try await Task.sleep(for: .milliseconds(150))
        return try await fixture.image(page, galleryID: galleryID, thumbnail: thumbnail)
    }
}

private final class ContentFixtureURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: request.url!.lastPathComponent == "missing" ? 404 : 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data([1, 2, 3]))
        client?.urlProtocol(self, didLoad: Data([4, 5, 6]))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private actor RefreshContentSource: ContentProviding {
    var offsets: [Int] = []
    private var fails = false
    func setFailure(_ value: Bool) { fails = value }
    func list(_ query: GalleryQuery, offset: Int, count: Int) async throws -> GalleryBatch {
        offsets.append(offset)
        // Deliberately ignore cancellation to simulate a late transport response.
        try? await Task.sleep(for: .milliseconds(query.language == "english" ? 150 : 30))
        if query.language == "english" { return GalleryBatch(ids: [99], hasMore: false) }
        if fails { throw ContentError.unavailable(503) }
        return GalleryBatch(ids: [Int64(offset + 1)], hasMore: true)
    }
    func gallery(_ id: Int64) async throws -> NativeGallery { try await FixtureContentSource().gallery(id) }
    func image(_ page: GalleryPage, galleryID: Int64, thumbnail: Bool) async throws -> Data { Data() }
}
