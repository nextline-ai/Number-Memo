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

    @MainActor func testPaginationDoesNotDownloadOffscreenCovers() async {
        let source = feedSource()
        let loader = GalleryFeedLoader(source: source, images: PageImageStore(source: source))
        await loader.load(GalleryQuery(), reset: true).value
        await loader.load(GalleryQuery(), reset: false).value
        let idleRequests = await source.imageRequests
        XCTAssertTrue(idleRequests.isEmpty, "Loading IDs must not eagerly download all 48 covers")
        loader.prioritizeCovers(startingAt: 20, count: 4)
        for id: Int64 in 21...24 { await loader.previews[id]?.load() }
        let requests = await source.imageRequests
        XCTAssertEqual(Set(requests), Set((21...24).map(Int64.init)))
    }

    @MainActor func testCancelingOffscreenCardStopsItsUnsharedCover() async throws {
        let source = feedSource(blocked: [1])
        let preview = GalleryFeedPreview(id: 1, source: source, images: PageImageStore(source: source))
        let visible = Task { await preview.load() }
        await source.waitForImage(1)
        visible.cancel()
        // Let the cancellation handler release the final consumer before the
        // simulated transport completes its otherwise uncancelable response.
        try await Task.sleep(for: .milliseconds(20))
        await source.release(1)
        await visible.value
        XCTAssertNil(preview.image, "An offscreen card must not finish decoding its obsolete response")
        await preview.load()
        XCTAssertNotNil(preview.image, "Returning to the card must remain retryable")
    }

    @MainActor func testCancelingLookaheadPreservesVisibleCardConsumer() async throws {
        let source = feedSource(blocked: [1])
        let preview = GalleryFeedPreview(id: 1, source: source, images: PageImageStore(source: source))
        let speculative = Task { await preview.load() }
        await source.waitForImage(1)
        let visible = Task { await preview.load() }
        try await Task.sleep(for: .milliseconds(20))
        speculative.cancel()
        try await Task.sleep(for: .milliseconds(20))
        await source.release(1)
        await speculative.value
        await visible.value
        XCTAssertNotNil(preview.image)
        let requests = await source.imageRequests
        XCTAssertEqual(requests, [1], "Visible and speculative consumers share one request")
    }

    @MainActor func testOffscreenCardReleasesPinnedContentAndReusesImageCache() async {
        let source = feedSource()
        let preview = GalleryFeedPreview(id: 1, source: source, images: PageImageStore(source: source))
        await preview.load()
        let image = preview.image
        XCTAssertNotNil(image)
        preview.discardDisplayContent()
        XCTAssertNil(preview.image)
        XCTAssertNil(preview.gallery)
        await preview.load()
        XCTAssertTrue(preview.image === image)
        let requests = await source.imageRequests
        XCTAssertEqual(requests, [1], "Returning to a cached card must not download again")
    }

    @MainActor func testFeedPublishesImmediatelyWhileOneCoverRemainsBlocked() async throws {
        let source = feedSource(blocked: [1])
        let store = PageImageStore(source: source)
        let loader = GalleryFeedLoader(source: source, images: store)
        await loader.load(GalleryQuery(), reset: true).value
        loader.prioritizeCovers(startingAt: 0, count: 4)
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
        loader.prioritizeCovers(startingAt: 24, count: 4)
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
        let source = feedSource(blocked: [1, 2])
        let loader = GalleryFeedLoader(source: source, images: PageImageStore(source: source))
        await loader.load(GalleryQuery(), reset: true).value
        loader.prioritizeCovers(startingAt: 0, count: 4)
        for id: Int64 in 1...2 { await source.waitForImage(id) }
        let requests = await source.imageRequests
        XCTAssertEqual(Set(requests), [1, 2])
        let concurrency = await source.maximumActiveImages
        XCTAssertEqual(concurrency, 2)
        await loader.load(GalleryQuery(), reset: false).value
        XCTAssertEqual(loader.ids, Array(1...48).map(Int64.init))
        XCTAssertFalse(loader.loading)
        // A visible cell can bypass the blocked speculative queue.
        await loader.previews[25]?.load()
        XCTAssertNotNil(loader.previews[25]?.image)
        for id: Int64 in 1...2 { await source.release(id) }
        await loadCovers(loader)
    }

    @MainActor func testPrefetchPrioritizesApproachingRowsOverDistantCovers() async {
        let source = feedSource(blocked: [1, 2])
        let loader = GalleryFeedLoader(source: source, images: PageImageStore(source: source))
        await loader.load(GalleryQuery(), reset: true).value
        loader.prioritizeCovers(startingAt: 0, count: 4)
        for id: Int64 in 1...2 { await source.waitForImage(id) }
        loader.prioritizeCovers(startingAt: 20, count: 4)
        await source.release(1)
        await source.waitForImage(21)
        let requests = await source.imageRequests
        XCTAssertEqual(requests.dropFirst(2).first, 21)
        XCTAssertFalse(requests.contains(3), "Old offscreen speculation must be discarded")
        await source.release(2)
        await loadCovers(loader)
    }

    @MainActor func testFilterChangeCancelsOldCoversWithoutDelayingNewResults() async {
        let source = feedSource(blocked: [1])
        let loader = GalleryFeedLoader(source: source, images: PageImageStore(source: source))
        await loader.load(GalleryQuery(), reset: true).value
        loader.prioritizeCovers(startingAt: 0, count: 4)
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

    func testPrefetchBoundsIncompleteFinalSpreadAndDisabledSetting() {
        XCTAssertEqual(PageImageStore.prefetchIndices(total: 5, current: 4, count: 3, visibleCount: 4), [4, 3])
        XCTAssertEqual(PageImageStore.prefetchIndices(total: 6, current: 4, count: 3, visibleCount: 4), [4, 3])
        XCTAssertEqual(PageImageStore.prefetchIndices(total: 8, current: 0, count: 2, visibleCount: 4), [0, 4, 5])
        XCTAssertEqual(PageImageStore.prefetchIndices(total: 8, current: 0, count: 0), [])
        XCTAssertEqual(PageImageStore.prefetchIndices(total: 0, current: 0, count: 3), [])
        XCTAssertEqual(PageImageStore.prefetchIndices(total: 5, current: 5, count: 3), [])
        XCTAssertEqual(PageImageStore.prefetchIndices(total: 5, current: 4, count: Int.max), [4, 3])
    }

    func testEnergyPolicySkipsSpeculationButStillLoadsRequestedPage() async throws {
        let source = CountingContentSource()
        let gallery = try await source.gallery(1)
        let store = PageImageStore(source: source, allowsPrefetch: { false })
        await store.prefetch(gallery, current: 0, count: 3)
        let speculative = await source.requests
        XCTAssertEqual(speculative, 0)
        _ = try await store.load(gallery.pages[0], galleryID: 1)
        let requested = await source.requests
        XCTAssertEqual(requested, 1)
    }

    @MainActor func testHiddenFeedStopsCoversAndResumesWithoutReplacingResults() async throws {
        let source = feedSource(blocked: [1, 2])
        let loader = GalleryFeedLoader(source: source, images: PageImageStore(source: source))
        await loader.load(GalleryQuery(), reset: true).value
        loader.prioritizeCovers(startingAt: 0, count: 4)
        for id: Int64 in 1...2 { await source.waitForImage(id) }
        let first = try XCTUnwrap(loader.previews[1])
        await loader.load(GalleryQuery(), reset: false).value
        await loader.load(GalleryQuery(), reset: false).value
        let pending = Task { await first.load() }
        await Task.yield()
        loader.suspend()
        for id: Int64 in 1...2 { await source.release(id) }
        await pending.value
        XCTAssertNil(first.image)
        XCTAssertFalse(loader.loading)
        await loader.load(GalleryQuery(), reset: false).value
        let offsets = await source.offsets
        XCTAssertEqual(offsets, [0, 24, 48], "A hidden feed must not request more pages")
        XCTAssertEqual(loader.ids, Array(1...72).map(Int64.init))
        let restarted = expectation(description: "Earlier visible cover restarts after resume")
        let observer = Task { await source.waitForImage(1, occurrences: 2); restarted.fulfill() }
        loader.resume()
        await fulfillment(of: [restarted], timeout: 3)
        observer.cancel()
        await loadCovers(loader)
        XCTAssertTrue(loader.previews[1] === first)
        XCTAssertNotNil(first.image, "A canceled cover must remain retryable on return")
        XCTAssertTrue(loader.ids.allSatisfy { loader.previews[$0]?.image != nil })
    }

    func testDiskPageCacheSurvivesStoreRecreationWithoutDownload() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = CountingContentSource()
        let gallery = try await source.gallery(1)
        let firstStore = PageImageStore(source: source, diskDirectory: directory)
        async let first = firstStore.load(gallery.pages[0], galleryID: 1)
        async let second = firstStore.load(gallery.pages[0], galleryID: 1)
        _ = try await (first, second)
        let secondStore = PageImageStore(source: source, diskDirectory: directory)
        let restored = try await secondStore.load(gallery.pages[0], galleryID: 1)
        XCTAssertGreaterThan(restored.size.width, 0)
        let requests = await source.requests
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 1)
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
    private var observers: [Int64: (occurrences: Int, continuation: CheckedContinuation<Void, Never>)] = [:]
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
        if let observer = observers[galleryID], imageRequests.filter({ $0 == galleryID }).count >= observer.occurrences {
            observers.removeValue(forKey: galleryID)?.continuation.resume()
        }
        if blocked.contains(galleryID) { await withCheckedContinuation { gates[galleryID] = $0 } }
        try Task.checkCancellation()
        if failedImages.contains(galleryID) { throw URLError(.timedOut) }
        return data
    }

    func waitForImage(_ id: Int64, occurrences: Int = 1) async {
        if imageRequests.filter({ $0 == id }).count >= occurrences { return }
        await withCheckedContinuation { observers[id] = (occurrences, $0) }
    }

    func release(_ id: Int64) {
        blocked.remove(id)
        gates.removeValue(forKey: id)?.resume()
    }
}

extension ReaderUXTests {
    @MainActor func testCachedReaderPersistsExplicitStartingPageWithoutTurningAndResumesThere() async throws {
        let id = Int64.random(in: 1_000_000_000...2_000_000_000)
        let progressKey = "reader_page_\(id)"
        let preferences = ReaderPreferences.defaults
        let settings: [String: Any] = ["reader.pagesPerSpread": 1, "reader.helpHidden": true, "reader.autoAdvance": false,
                                      "reader.prefetch": 0, "reader.keepAwake": false, "reader.mode": ReaderMode.horizontal.rawValue]
        let previous = settings.keys.map { ($0, preferences.object(forKey: $0)) }
        for (key, value) in settings { preferences.set(value, forKey: key) }
        UserDefaults.standard.set(20, forKey: progressKey)
        defer {
            UserDefaults.standard.removeObject(forKey: progressKey)
            for (key, value) in previous {
                if let value { preferences.set(value, forKey: key) } else { preferences.removeObject(forKey: key) }
            }
        }
        let pages = (0..<24).map { GalleryPage(hash: String(format: "%064x", $0 + 1), name: "\($0).jpg", width: 800, height: 1200, hasAVIF: false) }
        let gallery = NativeGallery(id: id, title: "Cached reader", artists: [], language: "", type: "", tags: [], pages: pages)
        let source = CachedReaderFixture(gallery: gallery)
        let images = PageImageStore(source: source, allowsPrefetch: { false })
        let env = AppEnvironment.preview()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: NativeReaderView(galleryID: id, initialPage: 5, source: source, images: images,
                                                                savesProgress: true, search: { _ in }, exit: {}).environment(env))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while UserDefaults.standard.integer(forKey: progressKey) != 5 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(UserDefaults.standard.integer(forKey: progressKey), 5, "Opening a cached explicit page must replace the old resume point even without turning")
        window.rootViewController = nil
        let reopened = UIHostingController(rootView: NativeReaderView(galleryID: id, initialPage: 1, source: source, images: images,
                                                                    savesProgress: true, search: { _ in }, exit: {}).environment(env))
        window.rootViewController = reopened
        func shownPage(in controller: UIViewController) -> Int? {
            if let pager = controller as? UIPageViewController {
                return (pager.viewControllers?.first as? ReaderPager.PageController)?.index
            }
            return controller.children.lazy.compactMap { shownPage(in: $0) }.first
        }
        let reopenedDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        while shownPage(in: reopened) == nil && ContinuousClock.now < reopenedDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(shownPage(in: reopened), 4, "A normal reopen must use the newly saved fifth page")
    }

    func testReaderStartsWithCachedThumbnailAndDistinguishesFullResolution() async throws {
        let source = CountingContentSource()
        let gallery = try await source.gallery(1)
        let page = gallery.pages[0]
        let images = PageImageStore(source: source)
        let thumbnail = try await images.load(page, galleryID: gallery.id, thumbnail: true)
        let preview = try XCTUnwrap(ReaderPageImage.cached(hash: page.hash, images: images))
        XCTAssertTrue(preview.image === thumbnail)
        XCTAssertFalse(preview.satisfies(page.hash), "A cached preview must still upgrade to full resolution")
        let fullImage = try await images.load(page, galleryID: gallery.id)
        let full = try XCTUnwrap(ReaderPageImage.cached(hash: page.hash, images: images))
        XCTAssertTrue(full.image === fullImage, "Prefer a decoded full page over its thumbnail")
        XCTAssertTrue(full.satisfies(page.hash), "Retained full pixels need no reload after lifecycle changes")
        XCTAssertFalse(full.satisfies("another-page"))
        let requests = await source.requests
        XCTAssertEqual(requests, 2)
    }

    func testReaderInitialPageMatchesResumeAndSpreadRules() {
        XCTAssertEqual(ReaderLayout.initialPage(1, saved: 7, total: 10, count: 2), 6)
        XCTAssertEqual(ReaderLayout.initialPage(4, saved: 9, total: 10, count: 2), 2)
        XCTAssertEqual(ReaderLayout.initialPage(100, saved: 0, total: 5, count: 2), 4)
        XCTAssertEqual(ReaderLayout.initialPage(Int.min, saved: 0, total: 5, count: 0), 0)
        XCTAssertEqual(ReaderLayout.initialPage(5, saved: 0, total: 0, count: 2), 0)
    }

    @MainActor func testSamePageResolutionUpgradePreservesZoomAndViewport() {
        let page = PageScrollView()
        page.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
        let thumbnail = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 600)).image { _ in }
        let full = UIGraphicsImageRenderer(size: CGSize(width: 1600, height: 2400)).image { _ in }
        page.update(image: thumbnail, contentID: "page-1")
        page.layoutIfNeeded()
        page.setZoomScale(2.5, animated: false)
        page.setContentOffset(CGPoint(x: 100, y: 350), animated: false)
        page.layoutIfNeeded()
        let offset = page.contentOffset, imageBounds = page.imageView.bounds, imageFrame = page.imageView.frame
        page.update(image: full, contentID: "page-1")
        page.layoutIfNeeded()
        XCTAssertTrue(page.imageView.image === full)
        XCTAssertEqual(page.zoomScale, 2.5, accuracy: 0.01)
        XCTAssertEqual(page.contentOffset, offset)
        XCTAssertEqual(page.imageView.bounds, imageBounds)
        XCTAssertEqual(page.imageView.frame, imageFrame)
        page.update(image: full, contentID: "page-2")
        page.layoutIfNeeded()
        XCTAssertEqual(page.zoomScale, 1, accuracy: 0.01, "A different page still starts fitted to the viewport")
    }

    @MainActor private func pagerFixture(current: Binding<Int>, images: PageImageStore,
                                         tap: @escaping (CGFloat) -> Void = { _ in }, isActive: Bool = true) -> ReaderPager {
        let pages = (0..<6).map { GalleryPage(hash: String(format: "%064x", $0 + 1), name: "\($0).jpg", width: 800, height: 1200, hasAVIF: false) }
        let gallery = NativeGallery(id: 1, title: "Reader", artists: [], language: "", type: "", tags: [], pages: pages)
        return ReaderPager(gallery: gallery, images: images, vertical: false, rtl: false, current: current,
                           tap: tap, bookmark: {}, count: 1, viewport: { _, _, _ in }, isActive: isActive)
    }

    @MainActor func testPagerReusesSpreadAndForwardsLatestActionsWithoutReplacingItsRoot() {
        var current = 0, firstCalls = 0, latestCalls = 0
        let binding = Binding(get: { current }, set: { current = $0 })
        let images = PageImageStore(source: FixtureContentSource())
        let parent = pagerFixture(current: binding, images: images, tap: { _ in firstCalls += 1 })
        let coordinator = ReaderPager.Coordinator(parent)
        let page = coordinator.page(0)
        let originalContent = page.rootView
        let controller = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal)
        controller.setViewControllers([page], direction: .forward, animated: false)
        coordinator.update(pagerFixture(current: binding, images: images, tap: { _ in latestCalls += 1 }), controller: controller)
        XCTAssertTrue(coordinator.page(0) === page)
        originalContent.tap(0.5)
        XCTAssertEqual(firstCalls, 0)
        XCTAssertEqual(latestCalls, 1, "Existing roots must forward through the latest parent without rebuilding")
        coordinator.update(pagerFixture(current: binding, images: images, isActive: false), controller: controller)
        XCTAssertFalse(page.rootView.isActive, "Lifecycle changes still reach retained image tasks")
    }

    @MainActor func testPagerHonorsPageJumpRequestedDuringInteractiveSwipe() {
        var current = 0
        let binding = Binding(get: { current }, set: { current = $0 })
        let images = PageImageStore(source: FixtureContentSource())
        let parent = pagerFixture(current: binding, images: images)
        let coordinator = ReaderPager.Coordinator(parent)
        let first = coordinator.page(0), swiped = coordinator.page(1)
        let controller = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal)
        controller.setViewControllers([first], direction: .forward, animated: false)
        coordinator.pageViewController(controller, willTransitionTo: [swiped])
        current = 4
        coordinator.update(parent, controller: controller)
        XCTAssertTrue(controller.viewControllers?.first === first)
        controller.setViewControllers([swiped], direction: .forward, animated: false)
        coordinator.pageViewController(controller, didFinishAnimating: true, previousViewControllers: [first], transitionCompleted: true)
        XCTAssertEqual(current, 4, "A completed swipe must not overwrite a newer explicit page jump")
        XCTAssertEqual((controller.viewControllers?.first as? ReaderPager.PageController)?.index, 4)
        XCTAssertTrue(coordinator.pages.keys.allSatisfy { abs($0 - 4) <= 1 })
    }

    @MainActor func testPagerCompletedAndCancelledSwipesKeepPositionConsistent() {
        var current = 0
        let binding = Binding(get: { current }, set: { current = $0 })
        let coordinator = ReaderPager.Coordinator(pagerFixture(current: binding, images: PageImageStore(source: FixtureContentSource())))
        let first = coordinator.page(0), second = coordinator.page(1)
        let controller = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal)
        controller.setViewControllers([first], direction: .forward, animated: false)
        coordinator.pageViewController(controller, willTransitionTo: [second])
        coordinator.pageViewController(controller, didFinishAnimating: true, previousViewControllers: [first], transitionCompleted: false)
        XCTAssertEqual(current, 0)
        coordinator.pageViewController(controller, willTransitionTo: [second])
        controller.setViewControllers([second], direction: .forward, animated: false)
        coordinator.pageViewController(controller, didFinishAnimating: true, previousViewControllers: [first], transitionCompleted: true)
        XCTAssertEqual(current, 1)
    }

    @MainActor func testPagerKeepsJumpThatArrivesBeforeSwipeDelegateCallback() {
        var current = 0
        let binding = Binding(get: { current }, set: { current = $0 })
        let parent = pagerFixture(current: binding, images: PageImageStore(source: FixtureContentSource()))
        let coordinator = ReaderPager.Coordinator(parent)
        let first = coordinator.page(0), swiped = coordinator.page(1)
        let controller = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal)
        controller.setViewControllers([first], direction: .forward, animated: false)
        current = 5
        coordinator.pageViewController(controller, willTransitionTo: [swiped])
        coordinator.update(parent, controller: controller)
        controller.setViewControllers([swiped], direction: .forward, animated: false)
        coordinator.pageViewController(controller, didFinishAnimating: true, previousViewControllers: [first], transitionCompleted: true)
        XCTAssertEqual(current, 5)
        XCTAssertEqual((controller.viewControllers?.first as? ReaderPager.PageController)?.index, 5)
    }

    @MainActor func testPageImageReplacementRecomputesAspectFitButUnchangedImageKeepsZoom() {
        let page = PageScrollView()
        page.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
        let landscape = UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 400)).image { _ in }
        let portrait = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 1200)).image { _ in }
        page.update(image: landscape)
        page.layoutIfNeeded()
        page.setZoomScale(2.5, animated: false)
        page.update(image: landscape)
        XCTAssertEqual(page.zoomScale, 2.5, accuracy: 0.01)
        page.update(image: portrait)
        page.layoutIfNeeded()
        XCTAssertEqual(page.zoomScale, 1, accuracy: 0.01)
        XCTAssertEqual(page.imageView.bounds.height, 800, accuracy: 1)
        XCTAssertEqual(page.imageView.bounds.width, 800 / 3, accuracy: 1)
    }

    @MainActor func testTranslationLabelsFollowImageTransformAndChangedRegionBounds() throws {
        let view = TranslatedPageView(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        let image = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 1200)).image { _ in }
        let regions = [ReaderTextRegion(text: "Translated", bounds: CGRect(x: 0.1, y: 0.2, width: 0.4, height: 0.1))]
        view.configure(image, regions: regions)
        view.layoutIfNeeded()
        let scroll = try XCTUnwrap(view.subviews.compactMap { $0 as? PageScrollView }.first)
        scroll.layoutIfNeeded()
        let label = try XCTUnwrap(scroll.imageView.subviews.compactMap { $0 as? UILabel }.first)
        let originalFrame = label.frame
        scroll.setZoomScale(2, animated: false)
        scroll.setContentOffset(CGPoint(x: 50, y: 80), animated: false)
        view.configure(image, regions: regions)
        XCTAssertTrue(scroll.imageView.subviews.first === label)
        XCTAssertEqual(label.frame, originalFrame, "Zoom and pan transform the existing image hierarchy")
        view.configure(image, regions: [.init(text: "Translated", bounds: CGRect(x: 0.1, y: 0.5, width: 0.4, height: 0.1))])
        let moved = try XCTUnwrap(scroll.imageView.subviews.compactMap { $0 as? UILabel }.first)
        XCTAssertNotEqual(moved.frame, originalFrame, "Equal text at new OCR bounds must not retain stale positioning")
    }
}

private struct CachedReaderFixture: ContentProviding {
    let gallery: NativeGallery
    func cachedGallery(_ id: Int64) -> NativeGallery? { id == gallery.id ? gallery : nil }
    func gallery(_ id: Int64) async throws -> NativeGallery { throw ContentError.unavailable(503) }
    func list(_ query: GalleryQuery, offset: Int, count: Int) async throws -> GalleryBatch { .init(ids: [], hasMore: false) }
    func image(_ page: GalleryPage, galleryID: Int64, thumbnail: Bool) async throws -> Data { throw ContentError.unavailable(503) }
}
