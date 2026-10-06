import XCTest
import WebKit
@testable import NumberMemo

@MainActor final class MediaInputTests: XCTestCase {
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
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if let value = message.body as? [String: Any], value["gesture"] != nil { gestures.append(value) }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded?(); loaded = nil }
}
