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
                let expected = CGRect(x: (web.scrollView.contentOffset.x / scale - origin.x) / imageSize.width,
                                      y: (web.scrollView.contentOffset.y / scale - origin.y) / imageSize.height,
                                      width: size.width / scale / imageSize.width,
                                      height: size.height / scale / imageSize.height).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
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
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
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
        coordinator.resume()
        var recovered = false
        for _ in 0..<100 {
            recovered = (try? await web.evaluateJavaScript("window.numberMemoDocumentID === 'current-work' && window.resumed === true")) as? Bool == true
            if recovered { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertTrue(recovered)
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
        try await Task.sleep(for: .milliseconds(550))
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

@MainActor private final class MediaRecorder: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    var gestures: [[String: Any]] = []
    var loaded: (() -> Void)?
    var viewport: CGRect?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if let value = message.body as? [String: Any], let r = value["viewport"] as? [String: Double], let x = r["x"], let y = r["y"], let w = r["w"], let h = r["h"] { viewport = CGRect(x: x, y: y, width: w, height: h) }
        if let value = message.body as? [String: Any], value["gesture"] != nil { gestures.append(value) }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded?(); loaded = nil }
}
