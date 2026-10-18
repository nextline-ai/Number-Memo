import XCTest
import SwiftUI
@testable import NumberMemo

final class ReaderUXTests: XCTestCase {
    @MainActor func testSaveFeedbackUsesSameModeSpecificResultAndRecordsToggle() throws {
        let env = AppEnvironment.preview(), server = BooruServer.presets[0]
        try env.booru.saveServer(server)
        let post = BooruFixtureSource.post(201, server: server, tags: ["blue_hair", "green_eyes"])
        let item = TasteRecommendation(item: .init(source: server.canonicalAddress, id: post.postID, tags: post.tags), post: post, gallery: nil,
                                       reason: .init(source: server.canonicalAddress, name: "blue_hair"), score: 1)
        let saved = try TasteRecommendationAction.toggle(item, env: env, session: "test")
        XCTAssertEqual(saved, .added(.booru)); XCTAssertEqual(saved.message, L10n.text("Saved to Favorites"))
        let removed = try BooruFavoriteAction.toggle(post, store: env.booru, context: .recommended("blue_hair", session: "test"))
        XCTAssertEqual(removed, .removed(.booru)); XCTAssertEqual(removed.message, L10n.text("Favorite removed"))
        XCTAssertFalse(env.booru.isFavorite(post))
        let events = try env.booru.tasteStore.events()
        XCTAssertEqual(events.filter { $0.kind == .save }.count, 1)
        XCTAssertEqual(events.filter { $0.kind == .remove }.count, 1)
        enum Failure: Error { case failed }
        let feedback = WorkSaveFeedback.perform { throw Failure.failed }
        XCTAssertEqual(feedback.result, .failed)
        XCTAssertNotEqual(WorkSaveFeedback(saved).id, WorkSaveFeedback(saved).id)
    }

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
        XCTAssertEqual(try ContentBookmarkAction.toggle(id: id, gallery: nil, env: env).message, L10n.text("Bookmark removed"))
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

    @MainActor private func feedSource(blocked: Set<Int64> = [], failedMetadata: Set<Int64> = [], failedImages: Set<Int64> = []) -> PreparedFeedSource {
        let data = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 12)).pngData { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 12))
        }
        return PreparedFeedSource(data: data, blocked: blocked, failedMetadata: failedMetadata, failedImages: failedImages)
    }

    @MainActor private func loadCovers(_ loader: GalleryFeedLoader) async {
        for id in loader.ids { await loader.previews[id]?.load() }
    }

    @MainActor func testFeedPublishesImmediatelyWhileOneCoverRemainsBlocked() async throws {
        let source = feedSource(blocked: [1])
        let store = PageImageStore(source: source)
        let loader = GalleryFeedLoader(source: source, images: store)
        await loader.load(GalleryQuery(), reset: true).value
        await source.waitForImage(1)
        XCTAssertEqual(loader.ids, Array(1...24).map(Int64.init))
        XCTAssertFalse(loader.loading, "A blocked cover must never keep pagination loading")
        XCTAssertNotNil(loader.previews[1]?.gallery, "Metadata should appear before its slow cover")
        XCTAssertNil(loader.previews[1]?.image)
        await loader.previews[2]?.load()
        XCTAssertNotNil(loader.previews[2]?.image, "Other cards must complete independently")
        await source.release(1)
        await loadCovers(loader)
        for id in loader.ids {
            let preview = try XCTUnwrap(loader.previews[id])
            let gallery = try XCTUnwrap(preview.gallery)
            let image = try XCTUnwrap(preview.image)
            XCTAssertEqual(gallery.id, id)
            XCTAssertTrue(image === store.cachedImage(hash: gallery.pages[0].hash, thumbnail: true))
        }
    }

    @MainActor func testFeedAppendDoesNotWaitForCoversAndCoalescesRequests() async {
        let source = feedSource(blocked: [25])
        let loader = GalleryFeedLoader(source: source, images: PageImageStore(source: source))
        await loader.load(GalleryQuery(), reset: true).value
        await loadCovers(loader)
        let firstImage = loader.previews[1]?.image
        let request = loader.load(GalleryQuery(), reset: false)
        let duplicate = loader.load(GalleryQuery(), reset: false)
        await request.value
        await duplicate.value
        await source.waitForImage(25)
        XCTAssertEqual(loader.ids, Array(1...48).map(Int64.init))
        XCTAssertFalse(loader.loading)
        XCTAssertTrue(loader.previews[1]?.image === firstImage)
        XCTAssertNil(loader.previews[25]?.image)
        await loader.previews[26]?.load()
        XCTAssertNotNil(loader.previews[26]?.image)
        await source.release(25)
        await loadCovers(loader)
        let offsets = await source.offsets
        XCTAssertEqual(offsets, [0, 24])
        let requests = await source.imageRequests
        XCTAssertEqual(requests.count, 48)
        XCTAssertEqual(Set(requests).count, 48, "Visible cells and prefetch must share each cover request")
    }

    @MainActor func testAllPrefetchWorkersBlockedStillAllowsNextPage() async {
        let source = feedSource(blocked: [1, 2, 3, 4])
        let loader = GalleryFeedLoader(source: source, images: PageImageStore(source: source))
        await loader.load(GalleryQuery(), reset: true).value
        for id: Int64 in 1...4 { await source.waitForImage(id) }
        let requests = await source.imageRequests
        XCTAssertEqual(Set(requests), [1, 2, 3, 4])
        let concurrency = await source.maximumActiveImages
        XCTAssertEqual(concurrency, 4)
        await loader.load(GalleryQuery(), reset: false).value
        XCTAssertEqual(loader.ids, Array(1...48).map(Int64.init))
        XCTAssertFalse(loader.loading)
        // A visible cell can bypass the blocked speculative queue.
        await loader.previews[25]?.load()
        XCTAssertNotNil(loader.previews[25]?.image)
        for id: Int64 in 1...4 { await source.release(id) }
        await loadCovers(loader)
    }

    @MainActor func testPrefetchPrioritizesApproachingRowsOverDistantCovers() async {
        let source = feedSource(blocked: [1, 2, 3, 4])
        let loader = GalleryFeedLoader(source: source, images: PageImageStore(source: source))
        await loader.load(GalleryQuery(), reset: true).value
        for id: Int64 in 1...4 { await source.waitForImage(id) }
        loader.prioritizeCovers(startingAt: 20, count: 4)
        await source.release(1)
        await source.waitForImage(21)
        let requests = await source.imageRequests
        XCTAssertEqual(requests.dropFirst(4).first, 21)
        for id: Int64 in 2...4 { await source.release(id) }
        await loadCovers(loader)
    }

    @MainActor func testFilterChangeCancelsOldCoversWithoutDelayingNewResults() async {
        let source = feedSource(blocked: [1])
        let loader = GalleryFeedLoader(source: source, images: PageImageStore(source: source))
        await loader.load(GalleryQuery(), reset: true).value
        await source.waitForImage(1)
        let previous = loader.previews[1]
        await loader.load(GalleryQuery(language: "english"), reset: true).value
        XCTAssertEqual(loader.ids, Array(1001...1024).map(Int64.init))
        XCTAssertEqual(Set(loader.previews.keys), Set(loader.ids))
        XCTAssertFalse(loader.loading)
        await loadCovers(loader)
        await source.release(1)
        await previous?.load()
        XCTAssertNil(previous?.image)
        XCTAssertTrue(loader.ids.allSatisfy { loader.previews[$0]?.image != nil })
        XCTAssertNil(loader.error)
    }

    @MainActor func testUnavailableCoverDoesNotBlockOtherPreparedCards() async {
        let source = feedSource(failedMetadata: [3], failedImages: [5])
        let loader = GalleryFeedLoader(source: source, images: PageImageStore(source: source))
        await loader.load(GalleryQuery(), reset: true).value
        await loadCovers(loader)
        XCTAssertEqual(loader.ids, Array(1...24).map(Int64.init))
        XCTAssertNil(loader.previews[3]?.gallery)
        XCTAssertNotNil(loader.previews[5]?.gallery)
        XCTAssertNil(loader.previews[5]?.image)
        XCTAssertTrue(loader.ids.filter { $0 != 3 && $0 != 5 }.allSatisfy { loader.previews[$0]?.image != nil })
        XCTAssertFalse(loader.loading)
        XCTAssertNil(loader.error)
    }

    @MainActor func testFeedPinsOnlyRecentCoversDuringLongScroll() async {
        let source = feedSource()
        let loader = GalleryFeedLoader(source: source, images: PageImageStore(source: source))
        await loader.load(GalleryQuery(), reset: true).value
        await loadCovers(loader)
        while loader.hasMore {
            await loader.load(GalleryQuery(), reset: false).value
            await loadCovers(loader)
        }
        XCTAssertEqual(loader.ids, Array(1...108).map(Int64.init))
        XCTAssertEqual(Set(loader.previews.keys), Set(loader.ids.suffix(72)))
        XCTAssertTrue(loader.previews.values.allSatisfy { $0.image != nil })
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
        for folder in try env.database.listFolders() { try env.database.deleteFolder(id: folder.id!) }
        XCTAssertEqual(try ContentBookmarkAction.save(id: 900000001, gallery: nil, env: env).message, L10n.text("Saved to bookmarks"))
        XCTAssertEqual(try ContentBookmarkAction.save(id: 900000001, gallery: nil, env: env).message, L10n.text("Already bookmarked"))
        XCTAssertEqual(try env.database.listWorks().filter { $0.galleryId == 900000001 }.count, 1)
        XCTAssertFalse(try env.database.getWork(galleryId: 900000001)!.folders.isEmpty)
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

/// A gated cover request makes publication order deterministic without timing assertions or network access.
private actor PreparedFeedSource: ContentProviding {
    let data: Data
    var blocked: Set<Int64>
    let failedMetadata: Set<Int64>
    let failedImages: Set<Int64>
    private var gates: [Int64: CheckedContinuation<Void, Never>] = [:]
    private var observers: [Int64: CheckedContinuation<Void, Never>] = [:]
    private var activeImages = 0
    private(set) var maximumActiveImages = 0
    private(set) var imageRequests: [Int64] = []
    private(set) var offsets: [Int] = []

    init(data: Data, blocked: Set<Int64>, failedMetadata: Set<Int64>, failedImages: Set<Int64>) {
        self.data = data; self.blocked = blocked
        self.failedMetadata = failedMetadata; self.failedImages = failedImages
    }

    func list(_ query: GalleryQuery, offset: Int, count: Int) async throws -> GalleryBatch {
        offsets.append(offset)
        let end = min(108, offset + count)
        let base = query.language == "english" ? 1001 : 1
        return GalleryBatch(ids: (offset..<end).map { Int64(base + $0) }, hasMore: end < 108)
    }

    func gallery(_ id: Int64) async throws -> NativeGallery {
        if failedMetadata.contains(id) { throw ContentError.unavailable(404) }
        let page = GalleryPage(hash: String(format: "%064llx", id), name: "cover.png", width: 8, height: 12, hasAVIF: false)
        return NativeGallery(id: id, title: "Work \(id)", artists: [], language: "korean", type: "manga", tags: [], pages: [page])
    }

    func image(_ page: GalleryPage, galleryID: Int64, thumbnail: Bool) async throws -> Data {
        imageRequests.append(galleryID)
        activeImages += 1
        maximumActiveImages = max(maximumActiveImages, activeImages)
        defer { activeImages -= 1 }
        observers.removeValue(forKey: galleryID)?.resume()
        if blocked.contains(galleryID) { await withCheckedContinuation { gates[galleryID] = $0 } }
        try Task.checkCancellation()
        if failedImages.contains(galleryID) { throw URLError(.timedOut) }
        return data
    }

    func waitForImage(_ id: Int64) async {
        if imageRequests.contains(id) { return }
        await withCheckedContinuation { observers[id] = $0 }
    }

    func release(_ id: Int64) {
        blocked.remove(id)
        gates.removeValue(forKey: id)?.resume()
    }
}
