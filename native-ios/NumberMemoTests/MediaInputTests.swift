import XCTest
import WebKit
@testable import NumberMemo

@MainActor final class MediaInputTests: XCTestCase {
    func testZoomedTranslationUsesExactlyTheVisibleImageRegion() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
        let controller = UIViewController()
        window.rootViewController = controller
        window.isHidden = false
        defer { window.isHidden = true }
        let recorder = MediaRecorder()
        let config = WKWebViewConfiguration()
        config.userContentController.add(recorder, name: "media")
        defer { config.userContentController.removeScriptMessageHandler(forName: "media") }
        let web = WKWebView(frame: window.bounds, configuration: config)
        web.scrollView.contentInsetAdjustmentBehavior = .never
        controller.view.addSubview(web)
        web.navigationDelegate = recorder
        for dimensions in [CGSize(width: 800, height: 1600), CGSize(width: 1600, height: 800)] {
            web.scrollView.setZoomScale(1, animated: false)
            let loaded = expectation(description: "Geometry document loaded")
            recorder.loaded = { loaded.fulfill() }
            let svg = "<svg xmlns='http://www.w3.org/2000/svg' width='\(Int(dimensions.width))' height='\(Int(dimensions.height))'><rect width='100%' height='100%' fill='white'/></svg>"
            let url = try XCTUnwrap(URL(string: "data:image/svg+xml;base64," + Data(svg.utf8).base64EncodedString()))
            web.loadHTMLString(BooruMediaView.document(post: BooruFixtureSource.post(101, server: BooruServer.presets[0]), url: url), baseURL: nil)
            await fulfillment(of: [loaded], timeout: 10)
            try await Task.sleep(for: .milliseconds(200))
            recorder.viewportReports = 0
            _ = try await web.evaluateJavaScript("for(let i=0;i<100;i++)window.dispatchEvent(new Event('scroll'))")
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(recorder.viewportReports, 0, "Unchanged scroll events must not repeatedly cross the SwiftUI bridge")
            web.scrollView.setZoomScale(2.5, animated: false)
            try await Task.sleep(for: .milliseconds(200))
            // A resize callback while enlarged must not fit the image to the
            // smaller visual viewport and shrink the underlying canvas again.
            _ = try await web.evaluateJavaScript("window.dispatchEvent(new Event('resize'))")
            for offset in [CGPoint(x: 120, y: 240), CGPoint(x: 580, y: 1100)] {
                web.scrollView.setContentOffset(offset, animated: false)
                try await Task.sleep(for: .milliseconds(200))
                let rect = try XCTUnwrap(recorder.viewport)
                let size = web.bounds.size, scale = web.scrollView.zoomScale
                let fit = min(size.width / dimensions.width, size.height / dimensions.height)
                let imageSize = CGSize(width: dimensions.width * fit, height: dimensions.height * fit)
                let origin = CGPoint(x: (size.width - imageSize.width) / 2, y: (size.height - imageSize.height) / 2)
                let rawX = (web.scrollView.contentOffset.x / scale - origin.x) / imageSize.width
                let rawY = (web.scrollView.contentOffset.y / scale - origin.y) / imageSize.height
                let rawW = size.width / scale / imageSize.width
                let rawH = size.height / scale / imageSize.height
                let expX = max(0, min(1, rawX))
                let expY = max(0, min(1, rawY))
                let expW = max(0, min(1, rawX + rawW) - expX)
                let expH = max(0, min(1, rawY + rawH) - expY)
                let expected = CGRect(x: expX, y: expY, width: expW, height: expH)
                XCTAssertEqual(rect.minX, expected.minX, accuracy: 0.015)
                XCTAssertEqual(rect.minY, expected.minY, accuracy: 0.015)
                XCTAssertEqual(rect.width, expected.width, accuracy: 0.015)
                XCTAssertEqual(rect.height, expected.height, accuracy: 0.015)
            }
            web.scrollView.setZoomScale(1, animated: false)
            web.scrollView.setContentOffset(.zero, animated: false)
            try await Task.sleep(for: .milliseconds(200))
            let fitRect = try XCTUnwrap(recorder.viewport)
            XCTAssertEqual(fitRect.minX, 0, accuracy: 0.015)
            XCTAssertEqual(fitRect.minY, 0, accuracy: 0.015)
            XCTAssertEqual(fitRect.width, 1, accuracy: 0.015)
            XCTAssertEqual(fitRect.height, 1, accuracy: 0.015)
        }
    }

    func testResumeRecoversTheCurrentDocumentAfterAnInterruptedTransition() async throws {
        let coordinator = BooruMediaView.Coordinator()
        let web = ResumeCountingWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        web.navigationDelegate = coordinator
        coordinator.observeLifecycle(of: web)
        defer { NotificationCenter.default.removeObserver(coordinator) }
        coordinator.documentID = "current-work"
        coordinator.document = "<html><script>window.numberMemoDocumentID='current-work';window.resumePlayback=()=>{window.resumed=true};window.renderNotes=()=>{};</script></html>"
        // A stale document can have finished even though a later transition did not.
        web.loadHTMLString("<html><script>window.numberMemoDocumentID='old-work';window.resumePlayback=()=>{};window.renderNotes=()=>{};</script></html>", baseURL: nil)
        for _ in 0..<100 {
            if coordinator.ready { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertTrue(coordinator.ready)
        // Scene activation and UIApplication activation can arrive together.
        coordinator.resume()
        coordinator.resume()
        var recovered = false
        for _ in 0..<100 {
            recovered = (try? await web.evaluateJavaScript("window.numberMemoDocumentID === 'current-work' && window.resumed === true")) as? Bool == true
            if recovered { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertTrue(recovered)
        XCTAssertEqual(web.documentLoads, 2, "Overlapping resume checks must reload the stale document only once")
    }

    func testResumeJavaScriptErrorsPreserveDocumentAndRetryOnlyOnce() async throws {
        for transient in [true, false] {
            let coordinator = BooruMediaView.Coordinator()
            let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
            web.navigationDelegate = coordinator
            coordinator.observeLifecycle(of: web)
            defer { coordinator.pause(); NotificationCenter.default.removeObserver(coordinator) }
            coordinator.documentID = "current-work"
            let retainedDocument = """
            <html><script>
            window.documentToken='retained';window.documentChecks=0;window.paused=true;
            Object.defineProperty(window,'numberMemoDocumentID',{get(){
              window.documentChecks++;
              if(\(transient ? "window.documentChecks === 1" : "true"))throw new Error('temporarily suspended');
              return 'current-work';
            }});
            window.resumePlayback=()=>{window.paused=false};
            window.pausePlayback=()=>{window.paused=true};window.renderNotes=()=>{};
            </script></html>
            """
            coordinator.document = retainedDocument.replacingOccurrences(of: "'retained'", with: "'reloaded'")
            web.loadHTMLString(retainedDocument, baseURL: nil)
            for _ in 0..<100 {
                if coordinator.ready { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertTrue(coordinator.ready)
            coordinator.pause()
            coordinator.resume()
            for _ in 0..<100 {
                if (try? await web.evaluateJavaScript("window.documentChecks")) as? Int == 2 { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            try await Task.sleep(for: .milliseconds(250))
            let token = try await web.evaluateJavaScript("window.documentToken") as? String
            let checks = try await web.evaluateJavaScript("window.documentChecks") as? Int
            let paused = try await web.evaluateJavaScript("window.paused") as? Bool
            XCTAssertEqual(token, "retained", "JavaScript evaluation failure must not replace the current document")
            XCTAssertEqual(checks, 2, "Resume may retry once, without polling indefinitely")
            XCTAssertEqual(paused, !transient)
            XCTAssertTrue(coordinator.ready)
        }
    }

    func testViewerDefersRequestedPageUntilForegroundWithoutStartingMoreRequests() {
        let paging = BooruViewerPagination()
        paging.isActive = true
        paging.requestAdvance(from: "last-loaded-post")
        XCTAssertTrue(paging.beginRequest())
        paging.isActive = false
        paging.finishRequest()
        XCTAssertFalse(paging.takeAdvance(currentID: "last-loaded-post", nextExists: true))
        XCTAssertEqual(paging.requestedFromID, "last-loaded-post", "A completed background response preserves the navigation intent")
        XCTAssertFalse(paging.beginRequest(), "Background completion must not start another network page")
        paging.isActive = true
        XCTAssertTrue(paging.takeAdvance(currentID: "last-loaded-post", nextExists: true))
        XCTAssertFalse(paging.takeAdvance(currentID: "last-loaded-post", nextExists: true), "Consume the intent only once")
    }

    func testViewerDoesNotApplyDeferredNavigationAfterSelectionChangesOrExit() {
        let paging = BooruViewerPagination()
        paging.isActive = true
        paging.requestAdvance(from: "original-post")
        XCTAssertFalse(paging.takeAdvance(currentID: "another-post", nextExists: true))
        XCTAssertFalse(paging.wantsNext)
        paging.requestAdvance(from: "original-post")
        paging.cancelAdvance()
        XCTAssertFalse(paging.takeAdvance(currentID: "original-post", nextExists: true))
    }

    func testViewerRetainsPendingNavigationWhenForegroundPrecedesResponse() {
        let paging = BooruViewerPagination()
        paging.isActive = true
        paging.requestAdvance(from: "last-loaded-post")
        XCTAssertTrue(paging.beginRequest())
        paging.isActive = false
        paging.isActive = true
        XCTAssertFalse(paging.takeAdvance(currentID: "last-loaded-post", nextExists: false))
        XCTAssertTrue(paging.wantsNext, "A still-loading request must survive foreground activation")
        XCTAssertFalse(paging.beginRequest(), "Activation must not duplicate the unfinished request")
        paging.finishRequest()
        XCTAssertTrue(paging.takeAdvance(currentID: "last-loaded-post", nextExists: true))
    }

    func testGoldRestrictedViewerNavigationRespectsBothDirections() {
        let ids = ["first", "gold", "last"]
        var navigation = BooruViewerAccessNavigation()
        navigation.restrict("gold")
        XCTAssertEqual(navigation.destination(in: ids, current: 1, canLoadMore: true, excluding: []), .post(2))
        navigation.moved(-1)
        navigation.restrict("gold")
        XCTAssertEqual(navigation.destination(in: ids, current: 1, canLoadMore: true, excluding: []), .post(0))
        XCTAssertEqual(navigation.candidate(in: ids, startingAt: 1, direction: -1, excluding: []), 0)
        XCTAssertEqual(navigation.candidate(in: ids, startingAt: 1, direction: 1, excluding: []), 2)
    }

    func testGoldRestrictedEndLoadsOnceThenFallsBackOrClosesWithoutLooping() {
        var navigation = BooruViewerAccessNavigation()
        navigation.restrict("gold")
        XCTAssertEqual(navigation.destination(in: ["first", "gold"], current: 1, canLoadMore: true, excluding: []), .loadMore)
        XCTAssertEqual(navigation.destination(in: ["first", "gold"], current: 1, canLoadMore: true, excluding: []), .post(0), "An empty batch must not repeatedly request the same next page")
        XCTAssertEqual(navigation.destination(in: ["first", "gold", "new"], current: 1, canLoadMore: true, excluding: []), .post(2))
        XCTAssertEqual(navigation.destination(in: ["first", "gold"], current: 1, canLoadMore: false, excluding: ["first"]), .close)
        var onlyRestricted = BooruViewerAccessNavigation()
        onlyRestricted.restrict("gold")
        XCTAssertEqual(onlyRestricted.destination(in: ["gold"], current: 0, canLoadMore: false, excluding: []), .close)
    }

    func testGoldRestrictionCallbackRejectsStaleDocumentsAndSuppressesOnlyTheirErrors() {
        let coordinator = BooruMediaView.Coordinator()
        let web = WKWebView(frame: .zero)
        var restrictions = 0, statuses: [String] = []
        coordinator.documentID = "current"
        coordinator.onGoldRequired = { restrictions += 1 }
        coordinator.onStatus = { statuses.append($0) }
        coordinator.rejectGoldRestrictedDocument("previous")
        XCTAssertEqual(restrictions, 0)
        coordinator.rejectGoldRestrictedDocument("current")
        coordinator.rejectGoldRestrictedDocument("current")
        coordinator.webView(web, didFail: nil, withError: BooruError.invalidResponse)
        XCTAssertEqual(restrictions, 1)
        XCTAssertTrue(statuses.isEmpty, "Confirmed Gold failures must not display generic error UI")
        coordinator.documentID = "next"
        coordinator.restrictedDocumentID = nil
        coordinator.webView(web, didFail: nil, withError: BooruError.invalidResponse)
        XCTAssertEqual(statuses, ["error"], "Ordinary image failures retain the existing error UI")
        XCTAssertEqual(restrictions, 1)
    }

    func testViewerImageCachePropagatesExplicitGoldResponseWithoutTreatingGenericErrorsAsRestricted() async throws {
        let server = try XCTUnwrap(BooruServer.presets.first { $0.engine == .danbooru })
        let url = try XCTUnwrap(URL(string: "https://example.com/image.jpg"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gold = Data("<div class='image-container'>You need a gold account to see this image</div>".utf8)
        let restricted = BooruViewerImageCache(directory: directory.appendingPathComponent("gold"), loadData: { _, _ in gold })
        do { _ = try await restricted.data(url: url, server: server); XCTFail("Expected explicit Gold restriction") }
        catch { XCTAssertEqual(error as? BooruPostAccessError, .goldRequired) }
        let denied = BooruViewerImageCache(directory: directory.appendingPathComponent("denied"), loadData: { _, _ in Data("Forbidden".utf8) })
        do { _ = try await denied.data(url: url, server: server); XCTFail("Expected ordinary invalid response") }
        catch { XCTAssertNil(error as? BooruPostAccessError) }
    }

    func testCacheMissTransitionKeepsPreviousFrameAndLoadsOnlyLatestDestination() {
        let transition = BooruMediaTransition()
        let previous = transitionImage(.red)
        var loads: [String] = []
        var captures: [(UIImage?) -> Void] = []
        transition.replace(id: "A", preview: previous, capture: { _ in XCTFail("Cached preview needs no snapshot") }) { loads.append("A") }
        transition.presented(id: "A")
        transition.replace(id: "B", preview: nil, capture: { captures.append($0) }) { loads.append("B") }
        transition.replace(id: "C", preview: nil, capture: { captures.append($0) }) { loads.append("C") }
        XCTAssertEqual(captures.count, 1, "Rapid cache misses share one outstanding snapshot")
        XCTAssertEqual(loads, ["A"], "Keep the current document visible until replacement pixels exist")
        captures[0](previous)
        XCTAssertEqual(loads, ["A", "C"])
        XCTAssertTrue(transition.overlay.image === previous)
        XCTAssertFalse(transition.overlay.isHidden)
        transition.presented(id: "B")
        XCTAssertFalse(transition.overlay.isHidden, "A stale ready message cannot reveal an unpainted destination")
        transition.presented(id: "C")
        XCTAssertTrue(transition.overlay.isHidden)
        XCTAssertNil(transition.overlay.image)
    }

    func testLateTransitionSnapshotCannotCoverNewCachedDestination() {
        let transition = BooruMediaTransition()
        let previous = transitionImage(.red), next = transitionImage(.blue)
        var loads: [String] = []
        var captured: ((UIImage?) -> Void)?
        transition.replace(id: "A", preview: previous, capture: { _ in }) { loads.append("A") }
        transition.presented(id: "A")
        transition.replace(id: "B", preview: nil, capture: { captured = $0 }) { loads.append("B") }
        transition.replace(id: "C", preview: next, capture: { _ in XCTFail("Cached preview needs no snapshot") }) { loads.append("C") }
        captured?(previous)
        XCTAssertEqual(loads, ["A", "C"])
        XCTAssertTrue(transition.overlay.image === next)
        transition.failed(id: "C")
        XCTAssertTrue(transition.overlay.isHidden, "Errors must reveal retry UI rather than retain stale pixels")
        XCTAssertNil(transition.overlay.image)
    }

    func testDismantledTransitionIgnoresPendingSnapshot() {
        let transition = BooruMediaTransition()
        let previous = transitionImage(.red)
        var loadedNext = false
        var captured: ((UIImage?) -> Void)?
        transition.replace(id: "A", preview: previous, capture: { _ in }) {}
        transition.presented(id: "A")
        transition.replace(id: "B", preview: nil, capture: { captured = $0 }) { loadedNext = true }
        transition.reset()
        captured?(previous)
        XCTAssertFalse(loadedNext)
        XCTAssertTrue(transition.overlay.isHidden)
        XCTAssertNil(transition.overlay.image)
    }

    func testPendingMediaURLHoldsFrameUntilResolutionAndFailureCancelsPendingLoad() {
        let transition = BooruMediaTransition()
        let previous = transitionImage(.red)
        var loads: [String] = []
        transition.replace(id: "A", preview: previous, capture: { _ in }) { loads.append("A") }
        transition.presented(id: "A")
        transition.replace(id: "B:pending", preview: nil, capture: { $0(previous) }) {}
        XCTAssertFalse(transition.overlay.isHidden)
        XCTAssertTrue(transition.overlay.image === previous)
        transition.replace(id: "B:resolved", preview: nil, capture: { _ in XCTFail("Reuse the held frame") }) { loads.append("B") }
        transition.presented(id: "B:pending")
        XCTAssertFalse(transition.overlay.isHidden)
        transition.presented(id: "B:resolved")
        XCTAssertTrue(transition.overlay.isHidden)
        var captured: ((UIImage?) -> Void)?
        transition.replace(id: "C:pending", preview: nil, capture: { captured = $0 }) { loads.append("C") }
        transition.failed(id: "C:pending")
        captured?(previous)
        XCTAssertEqual(loads, ["A", "B"])
        XCTAssertTrue(transition.overlay.isHidden)
        XCTAssertNil(transition.overlay.image)
    }

    func testDelayedSnapshotCannotStartVideoAfterViewerBecomesInactive() async throws {
        let coordinator = BooruMediaView.Coordinator()
        let config = WKWebViewConfiguration()
        config.userContentController.add(coordinator, name: "media")
        defer { config.userContentController.removeScriptMessageHandler(forName: "media") }
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 800), configuration: config)
        web.navigationDelegate = coordinator
        coordinator.observeLifecycle(of: web)
        defer { NotificationCenter.default.removeObserver(coordinator) }
        coordinator.transition.install(in: web)
        coordinator.transition.replace(id: "A", preview: transitionImage(.red), capture: { _ in }) {}
        coordinator.transition.presented(id: "A")
        var post = BooruFixtureSource.post(101, server: BooruServer.presets[0])
        post.fileExtension = "mp4"
        coordinator.documentID = "B"
        coordinator.document = BooruMediaView.document(post: post, url: URL(string: BooruTestMedia.mp4), identifier: "B")
        var captured: ((UIImage?) -> Void)?
        coordinator.transition.replace(id: "B", preview: nil, capture: { captured = $0 }) {
            web.loadHTMLString(coordinator.document, baseURL: nil)
        }
        coordinator.active = false
        coordinator.pause()
        captured?(transitionImage(.red))
        for _ in 0..<100 {
            if coordinator.ready { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertTrue(coordinator.ready)
        let started = try await web.evaluateJavaScript("document.getElementById('media').hasAttribute('src')") as? Bool
        XCTAssertEqual(started, false, "A delayed snapshot must not load a document with stale autoplay permission")
    }

    func testPendingMediaURLRejectsPreviousDocumentGesturesAndPlayback() async throws {
        let coordinator = BooruMediaView.Coordinator()
        let received = expectation(description: "Previous document message was delivered")
        let forwarder = MediaMessageForwarder { controller, message in
            coordinator.userContentController(controller, didReceive: message)
            received.fulfill()
        }
        let config = WKWebViewConfiguration()
        config.userContentController.add(forwarder, name: "media")
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 800), configuration: config)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let host = UIViewController()
        window.rootViewController = host
        host.view.addSubview(web)
        window.isHidden = false
        web.navigationDelegate = coordinator
        coordinator.observeLifecycle(of: web)
        defer {
            config.userContentController.removeScriptMessageHandler(forName: "media")
            NotificationCenter.default.removeObserver(coordinator)
            web.navigationDelegate = nil; web.stopLoading()
            window.isHidden = true; window.rootViewController = nil
        }
        coordinator.documentID = "A"
        coordinator.document = """
        <html><script>
        window.numberMemoDocumentID='A';window.paused=false;
        window.resumePlayback=()=>{window.paused=false};window.pausePlayback=()=>{window.paused=true};window.renderNotes=()=>{};
        </script></html>
        """
        web.loadHTMLString(coordinator.document, baseURL: nil)
        for _ in 0..<100 {
            if coordinator.ready { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertTrue(coordinator.ready)
        var gestures = 0, statuses = 0
        coordinator.onGesture = { _ in gestures += 1 }
        coordinator.onStatus = { _ in statuses += 1 }
        coordinator.documentID = "B:pending"; coordinator.document = ""
        coordinator.pause()
        // Even a late didFinish from the held document must keep it suspended.
        coordinator.webView(web, didFinish: nil)
        let sent = try await web.evaluateJavaScript("window.webkit.messageHandlers.media.postMessage({documentID:'A',gesture:'swipe',delta:1,status:'ready'}); true") as? Bool
        XCTAssertEqual(sent, true)
        await fulfillment(of: [received], timeout: 5)
        let document = try await web.evaluateJavaScript("window.numberMemoDocumentID") as? String
        let paused = try await web.evaluateJavaScript("window.paused") as? Bool
        XCTAssertEqual(document, "A", "Pending metadata retains the same rendered web document")
        XCTAssertEqual(paused, true)
        XCTAssertEqual(gestures, 0)
        XCTAssertEqual(statuses, 0)
    }

    func testStaticImageErrorBeforeNativeResumeIsRetriedAfterResume() async throws {
        let recorder = MediaRecorder()
        let config = WKWebViewConfiguration()
        config.userContentController.add(recorder, name: "media")
        defer { config.userContentController.removeScriptMessageHandler(forName: "media") }
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 800), configuration: config)
        web.navigationDelegate = recorder
        let loaded = expectation(description: "Suspended static image document loaded")
        recorder.loaded = { loaded.fulfill() }
        let svg = "<svg xmlns='http://www.w3.org/2000/svg' width='100' height='100'><rect width='100' height='100'/></svg>"
        let url = try XCTUnwrap(URL(string: "data:image/svg+xml;base64," + Data(svg.utf8).base64EncodedString()))
        let post = BooruFixtureSource.post(101, server: BooruServer.presets[0])
        web.loadHTMLString(BooruMediaView.document(post: post, url: url), baseURL: nil)
        await fulfillment(of: [loaded], timeout: 10)
        try await Task.sleep(for: .milliseconds(100))
        _ = try await web.evaluateJavaScript("""
        window.retrySourceChanges=0;
        new MutationObserver(changes=>{window.retrySourceChanges+=changes.length;})
          .observe(document.getElementById('media'),{attributes:true,attributeFilter:['src']});
        document.getElementById('media').dispatchEvent(new Event('error'));
        window.resumePlayback();
        """)
        try await Task.sleep(for: .milliseconds(700))
        let changes = try await web.evaluateJavaScript("window.retrySourceChanges") as? Int
        XCTAssertGreaterThanOrEqual(changes ?? 0, 2, "An error before didFinish must retry instead of leaving the loading frame forever")
        _ = try await web.evaluateJavaScript("window.pausePlayback()")
    }

    func testMediaPresentationWaitsForImageDecodeAndPaint() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
        let controller = UIViewController()
        window.rootViewController = controller; window.isHidden = false
        defer { window.isHidden = true }
        let recorder = MediaRecorder()
        let config = WKWebViewConfiguration()
        config.userContentController.add(recorder, name: "media")
        config.userContentController.addUserScript(WKUserScript(source: """
        HTMLImageElement.prototype.decode=function(){
          return new Promise(resolve=>{window.releaseImageDecode=resolve;});
        };
        """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        defer { config.userContentController.removeScriptMessageHandler(forName: "media") }
        let web = WKWebView(frame: window.bounds, configuration: config)
        controller.view.addSubview(web)
        web.navigationDelegate = recorder
        let loaded = expectation(description: "Image document loaded")
        recorder.loaded = { loaded.fulfill() }
        let svg = "<svg xmlns='http://www.w3.org/2000/svg' width='100' height='100'><rect width='100' height='100'/></svg>"
        let url = try XCTUnwrap(URL(string: "data:image/svg+xml;base64," + Data(svg.utf8).base64EncodedString()))
        let post = BooruFixtureSource.post(101, server: BooruServer.presets[0])
        web.loadHTMLString(BooruMediaView.document(post: post, url: url, identifier: "paint-test"), baseURL: nil)
        await fulfillment(of: [loaded], timeout: 10)
        var decoding = false
        for _ in 0..<100 {
            decoding = (try? await web.evaluateJavaScript("typeof window.releaseImageDecode === 'function'")) as? Bool == true
            if decoding { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(decoding)
        XCTAssertEqual(recorder.presentations, 0, "Network load alone cannot release the transition frame")
        _ = try await web.evaluateJavaScript("window.releaseImageDecode()")
        for _ in 0..<100 {
            if recorder.presentations > 0 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(recorder.presentations, 1)
        let visibility = try await web.evaluateJavaScript("document.getElementById('media').style.visibility") as? String
        XCTAssertEqual(visibility, "visible")
    }

    private func transitionImage(_ color: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
    }

    func testNativePauseInvalidatesPendingDocumentResume() async throws {
        let coordinator = BooruMediaView.Coordinator()
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        web.navigationDelegate = coordinator
        coordinator.observeLifecycle(of: web)
        defer { NotificationCenter.default.removeObserver(coordinator) }
        coordinator.documentID = "current-work"
        coordinator.document = """
        <html><script>
        window.numberMemoDocumentID='current-work';window.resumes=0;window.paused=true;
        window.resumePlayback=()=>{window.resumes++;window.paused=false};
        window.pausePlayback=()=>{window.paused=true};window.renderNotes=()=>{};
        </script></html>
        """
        web.loadHTMLString(coordinator.document, baseURL: nil)
        for _ in 0..<100 {
            if coordinator.ready { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertTrue(coordinator.ready)
        let initialResumes = try await web.evaluateJavaScript("window.resumes") as? Int
        // The document check returns asynchronously after the native pause.
        // Its callback must not reactivate playback using the older decision.
        coordinator.resume()
        coordinator.pause()
        try await Task.sleep(for: .milliseconds(200))
        let paused = try await web.evaluateJavaScript("window.paused") as? Bool
        let resumes = try await web.evaluateJavaScript("window.resumes") as? Int
        XCTAssertEqual(paused, true)
        XCTAssertEqual(resumes, initialResumes)
    }

    func testInactiveAnimatedMediaOnlyResumesThroughNativePlaybackGate() async throws {
        let recorder = MediaRecorder()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(recorder, name: "media")
        defer { config.userContentController.removeScriptMessageHandler(forName: "media") }
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 800), configuration: config)
        web.navigationDelegate = recorder
        let svg = "<svg xmlns='http://www.w3.org/2000/svg' width='100' height='100'><rect width='100' height='100'/></svg>"
        let url = try XCTUnwrap(URL(string: "data:image/svg+xml;base64," + Data(svg.utf8).base64EncodedString()))
        var post = BooruFixtureSource.post(101, server: BooruServer.presets[0])
        post.fileExtension = "gif"
        let loaded = expectation(description: "Initially inactive animated document loaded")
        recorder.loaded = { loaded.fulfill() }
        web.loadHTMLString(BooruMediaView.document(post: post, url: url, active: false), baseURL: nil)
        await fulfillment(of: [loaded], timeout: 10)
        let initiallyLoaded = try await web.evaluateJavaScript("document.getElementById('media').hasAttribute('src')")
        XCTAssertEqual(initiallyLoaded as? Bool, false)
        _ = try await web.evaluateJavaScript("window.dispatchEvent(new Event('pageshow'));document.dispatchEvent(new Event('visibilitychange'))")
        let browserResumed = try await web.evaluateJavaScript("document.getElementById('media').hasAttribute('src')")
        XCTAssertEqual(browserResumed as? Bool, false, "Browser events cannot restart an inactive viewer")
        _ = try await web.evaluateJavaScript("window.resumePlayback()")
        let resumed = try await web.evaluateJavaScript("document.getElementById('media').getAttribute('src')")
        XCTAssertEqual(resumed as? String, url.absoluteString)
        _ = try await web.evaluateJavaScript("window.pausePlayback();window.dispatchEvent(new Event('pageshow'))")
        let released = try await web.evaluateJavaScript("document.getElementById('media').hasAttribute('src')")
        XCTAssertEqual(released as? Bool, false, "Suspended animated images must release their decoder source")
    }

    func testPausedVideoIgnoresPendingPlaybackEvents() async throws {
        let recorder = MediaRecorder()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(recorder, name: "media")
        defer { config.userContentController.removeScriptMessageHandler(forName: "media") }
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 800), configuration: config)
        web.navigationDelegate = recorder
        var post = BooruFixtureSource.post(101, server: BooruServer.presets[0])
        post.fileExtension = "mp4"
        let loaded = expectation(description: "Initially inactive video loaded")
        recorder.loaded = { loaded.fulfill() }
        web.loadHTMLString(BooruMediaView.document(post: post, url: URL(string: BooruTestMedia.mp4), active: false), baseURL: nil)
        await fulfillment(of: [loaded], timeout: 10)
        _ = try await web.evaluateJavaScript("""
        Object.defineProperty(document,'hidden',{configurable:true,get:()=>false});
        window.playCount=0;
        document.getElementById('media').play=()=>{window.playCount++;return Promise.resolve();};
        window.pausePlayback();
        window.dispatchEvent(new Event('pageshow'));
        document.dispatchEvent(new Event('visibilitychange'));
        document.getElementById('media').dispatchEvent(new Event('canplay'));
        document.getElementById('media').dispatchEvent(new Event('loadeddata'));
        """)
        let pausedCount = try await web.evaluateJavaScript("window.playCount")
        XCTAssertEqual(pausedCount as? Int, 0)
        _ = try await web.evaluateJavaScript("window.resumePlayback()")
        let resumedCount = try await web.evaluateJavaScript("window.playCount")
        XCTAssertGreaterThan(resumedCount as? Int ?? 0, 0)
        _ = try await web.evaluateJavaScript("window.pausePlayback()")
    }

    func testLaunchAndResumeHaveIndependentDurations() {
        XCTAssertEqual(SplashTiming.launch.hold, SplashTiming.resume.hold * 2)
        XCTAssertEqual(SplashTiming.launch.slide, SplashTiming.resume.slide * 2)
        XCTAssertEqual(SplashTiming.resume.total, 1.5)
        XCTAssertEqual(SplashTiming.launch.total, 3)
    }

    func testPrivacyCoverIsImmediateAndSurvivesInterruptedReturn() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
        window.rootViewController = UIViewController()
        window.isHidden = false
        defer { window.isHidden = true }
        let manager = PrivacyCoverManager()
        manager.show(in: [window])
        let cover = try XCTUnwrap(window.subviews.last)
        XCTAssertEqual(cover.accessibilityIdentifier, "privacy.cover")
        XCTAssertEqual(cover.frame, window.bounds)
        XCTAssertEqual(cover.alpha, 1)
        XCTAssertTrue(cover.isOpaque)
        XCTAssertTrue(cover.layer.animationKeys()?.isEmpty ?? true)
        manager.hide()
        manager.show(in: [window])
        try await Task.sleep(for: .milliseconds(550))
        XCTAssertTrue(cover.superview === window)
        XCTAssertEqual(cover.transform, .identity)
        XCTAssertEqual(cover.alpha, 1)
        manager.hide()
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(cover.superview === window, "Resume keeps the original 0.6 second hold")
        XCTAssertEqual(cover.transform, .identity)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertLessThan(cover.transform.ty, 0, "Resume slides upward after the hold")
        manager.show(in: [window])
        XCTAssertEqual(cover.transform, .identity)
        try await Task.sleep(for: .milliseconds(900))
        XCTAssertTrue(cover.superview === window, "Interrupted slide must not remove the restored privacy cover")
        manager.hide()
        try await Task.sleep(for: .milliseconds(1700))
        XCTAssertNil(cover.superview)
    }

    func testChallengePageCannotBeAdoptedAsValidatedSession() async throws {
        let server = BooruServer.presets[0]
        let model = BooruValidationModel(server: server)
        XCTAssertTrue(model.webView.customUserAgent?.isEmpty ?? true)
        model.webView.loadHTMLString("<html><title>Just a moment...</title><form id='challenge-form'>Checking...</form></html>", baseURL: server.baseURL)
        for _ in 0..<100 {
            if model.challengePresent { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertTrue(model.challengePresent)
        XCTAssertFalse(model.canAdoptSession)
        model.webView.loadHTMLString("<html><title>Posts</title><body>Website ready</body></html>", baseURL: server.baseURL)
        for _ in 0..<100 {
            if model.canAdoptSession { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertTrue(model.canAdoptSession)
        XCTAssertFalse(model.challengePresent)
        model.cancelRetries()
    }

    func testMouseAndKeyboardInRealMediaDocument() async throws {
        let recorder = MediaRecorder()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(recorder, name: "media")
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        web.navigationDelegate = recorder
        let loaded = expectation(description: "Media document loaded")
        recorder.loaded = { loaded.fulfill() }
        let server = BooruServer.presets[0]
        let post = BooruFixtureSource.post(101, server: server)
        let svg = "<svg xmlns='http://www.w3.org/2000/svg' width='100' height='100'><rect width='100' height='100'/></svg>"
        let url = URL(string: "data:image/svg+xml;base64," + Data(svg.utf8).base64EncodedString())!
        web.loadHTMLString(BooruMediaView.document(post: post, url: url), baseURL: nil)
        await fulfillment(of: [loaded], timeout: 10)
        _ = try await web.evaluateJavaScript("document.body.dispatchEvent(new MouseEvent('click',{bubbles:true,detail:1,clientX:400,clientY:300}));")
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(recorder.gestures.map { $0["gesture"] as? String }, ["tap"])
        recorder.gestures = []
        _ = try await web.evaluateJavaScript("""
        document.body.dispatchEvent(new MouseEvent('click',{bubbles:true,detail:1}));
        document.body.dispatchEvent(new MouseEvent('click',{bubbles:true,detail:2}));
        document.body.dispatchEvent(new MouseEvent('dblclick',{bubbles:true,clientX:400,clientY:300}));
        document.body.dispatchEvent(new MouseEvent('contextmenu',{bubbles:true,cancelable:true}));
        document.body.dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowRight',bubbles:true}));
        document.body.dispatchEvent(new KeyboardEvent('keydown',{key:'f',ctrlKey:true,bubbles:true}));
        document.body.dispatchEvent(new KeyboardEvent('keydown',{key:'f',repeat:true,bubbles:true}));
        const input=document.createElement('input');document.body.appendChild(input);
        input.dispatchEvent(new KeyboardEvent('keydown',{key:'f',bubbles:true}));
        document.body.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}));
        """)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(recorder.gestures.compactMap { $0["gesture"] as? String }, ["double", "tap", "shortcut", "shortcut"])
        XCTAssertEqual(recorder.gestures.compactMap { $0["key"] as? String }, ["ArrowRight", "Escape"])
        recorder.gestures = []
        _ = try await web.evaluateJavaScript("""
        const touch=new Event('touchstart',{bubbles:true});Object.defineProperty(touch,'touches',{value:[]});
        document.body.dispatchEvent(touch);
        document.body.dispatchEvent(new MouseEvent('click',{bubbles:true,detail:1}));
        """)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(recorder.gestures.isEmpty, "Touch compatibility click must not navigate twice")
        config.userContentController.removeScriptMessageHandler(forName: "media")
    }
}

@MainActor private final class ResumeCountingWebView: WKWebView {
    private(set) var documentLoads = 0
    override func loadHTMLString(_ string: String, baseURL: URL?) -> WKNavigation? {
        documentLoads += 1
        return super.loadHTMLString(string, baseURL: baseURL)
    }
}

@MainActor private final class MediaMessageForwarder: NSObject, WKScriptMessageHandler {
    let receive: (WKUserContentController, WKScriptMessage) -> Void
    init(receive: @escaping (WKUserContentController, WKScriptMessage) -> Void) { self.receive = receive }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) { receive(controller, message) }
}

@MainActor private final class MediaRecorder: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    var gestures: [[String: Any]] = []
    var loaded: (() -> Void)?
    var viewport: CGRect?
    var viewportReports = 0
    var presentations = 0
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if let value = message.body as? [String: Any], value["presented"] as? Bool == true { presentations += 1 }
        if let value = message.body as? [String: Any], let r = value["viewport"] as? [String: Double], let x = r["x"], let y = r["y"], let w = r["w"], let h = r["h"] { viewport = CGRect(x: x, y: y, width: w, height: h); viewportReports += 1 }
        if let value = message.body as? [String: Any], value["gesture"] != nil { gestures.append(value) }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded?(); loaded = nil }
}
