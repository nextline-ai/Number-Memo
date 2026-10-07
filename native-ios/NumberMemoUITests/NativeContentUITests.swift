import XCTest
import Vision

final class NativeContentUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
    private func wait(_ item: XCUIElement, _ predicate: String, _ value: String) {
        expectation(for: NSPredicate(format: predicate, value), evaluatedWith: item)
        waitForExpectations(timeout: 10)
    }
    private func launchReader(extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--native-content-ui-test", "-AppleLanguages", "(ko)", "-AppleLocale", "ko_KR"] + extra
        app.launch()
        let card = element(app, "content.gallery.900000001")
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        card.tap()
        let read = element(app, "content.read")
        XCTAssertTrue(read.waitForExistence(timeout: 10))
        read.tap()
        XCTAssertTrue(element(app, "reader.image").waitForExistence(timeout: 10))
        return app
    }
    private func tap(_ app: XCUIApplication, x: CGFloat, y: CGFloat = 0.5) {
        app.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y)).tap()
    }
    private func menu(_ app: XCUIApplication) {
        expectation(for: NSPredicate { _, _ in
            app.images.matching(identifier: "reader.image").allElementsBoundByIndex.contains { $0.isHittable }
        }, evaluatedWith: app)
        waitForExpectations(timeout: 10)
        tap(app, x: 0.5)
        XCTAssertTrue(element(app, "reader.position").waitForExistence(timeout: 5))
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testSettingsSwitchExploreBetweenNativeAndBuiltInBrowser() {
        let app = XCUIApplication()
        app.launchArguments = ["--native-content-ui-test", "--native-content-tab-test", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        app.tabBars.buttons["Explore"].tap()
        XCTAssertTrue(element(app, "content.gallery.900000001").waitForExistence(timeout: 10))
        app.tabBars.buttons["Settings"].tap()
        let setting = element(app, "settings.embeddedBrowser")
        for _ in 0..<4 where !setting.isHittable { app.swipeUp() }
        XCTAssertTrue(setting.isHittable)
        XCTAssertEqual(setting.value as? String, "0")
        setting.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
        XCTAssertEqual(setting.value as? String, "1")
        capture(app, "Built-in browser setting enabled")
        app.tabBars.buttons["Explore"].tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Browser ready"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["JavaScript ready"].exists)
        XCTAssertFalse(element(app, "content.gallery.900000001").exists)
        app.links["Next test page"].tap()
        XCTAssertTrue(app.staticTexts["Second page"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Settings"].tap()
        app.tabBars.buttons["Explore"].tap()
        XCTAssertTrue(app.staticTexts["Second page"].waitForExistence(timeout: 5))
        element(app, "browser.back").tap()
        XCTAssertTrue(app.staticTexts["Browser ready"].waitForExistence(timeout: 5))
        element(app, "browser.forward").tap()
        XCTAssertTrue(app.staticTexts["Second page"].waitForExistence(timeout: 5))
        element(app, "browser.reload").tap()
        XCTAssertTrue(app.staticTexts["Second page"].waitForExistence(timeout: 5))
        app.links["New-window test page"].tap()
        expectation(for: NSPredicate(format: "value CONTAINS '/third'"), evaluatedWith: element(app, "browser.address"))
        waitForExpectations(timeout: 5)
        capture(app, "Embedded WebKit with navigation")
        app.tabBars.buttons["Settings"].tap()
        for _ in 0..<4 where !setting.isHittable { app.swipeUp() }
        setting.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
        XCTAssertEqual(setting.value as? String, "0")
        app.tabBars.buttons["Explore"].tap()
        XCTAssertTrue(element(app, "content.gallery.900000001").waitForExistence(timeout: 10))
        XCTAssertFalse(app.webViews.firstMatch.exists)
    }

    func testLibraryWorkOpensRequestedReaderInBrowserAndCloses() {
        let app = XCUIApplication()
        app.launchArguments = ["--native-content-ui-test", "--library-jump-test", "--browser-fallback-test", "-AppleLanguages", "(en)"]
        app.launch()
        let card = element(app, "works.card.910000001")
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        card.tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Browser ready"].waitForExistence(timeout: 10))
        let address = element(app, "browser.address").value as? String ?? ""
        XCTAssertTrue(address.contains("/reader/910000001.html#1"), address)
        XCTAssertFalse(element(app, "reader.image").exists)
        capture(app, "Library work in browser fallback")
        element(app, "browser.close").tap()
        XCTAssertTrue(card.waitForExistence(timeout: 5))
    }

    func testEnglishLocalization() { verifyLocalization("en", explore: "Explore", read: "Read", guide: "Reader Guide", zoom: "Zoom & Translate") }
    func testJapaneseLocalization() { verifyLocalization("ja", explore: "探索", read: "読む", guide: "ビューアの使い方", zoom: "拡大・翻訳") }
    func testKoreanLocalization() { verifyLocalization("ko", explore: "탐색", read: "읽기", guide: "읽기 모드 안내", zoom: "확대·번역") }
    func testUnsupportedLanguageFallsBackToEnglish() { verifyLocalization("fr", explore: "Explore", read: "Read", guide: "Reader Guide", zoom: "Zoom & Translate") }

    private func verifyLocalization(_ language: String, explore: String, read: String, guide: String, zoom: String) {
        let app = XCUIApplication()
        app.launchArguments = ["--native-content-ui-test", "--native-content-tab-test", "--reader-help-test",
                               "-AppleLanguages", "(\(language))", "-AppleLocale", language]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons[explore].waitForExistence(timeout: 10))
        capture(app, "Localized folders " + language)
        app.tabBars.buttons[explore].tap()
        let card = element(app, "content.gallery.900000001")
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        capture(app, "Localized explore " + language)
        card.tap()
        let readButton = element(app, "content.read")
        XCTAssertTrue(readButton.waitForExistence(timeout: 10))
        XCTAssertEqual(readButton.label, read)
        readButton.tap()
        XCTAssertTrue(element(app, "reader.help.close").waitForExistence(timeout: 10))
        XCTAssertTrue(app.navigationBars[guide].exists)
        app.buttons[zoom].tap()
        capture(app, "Localized guide " + language)
        element(app, "reader.help.never").tap()
        menu(app)
        capture(app, "Localized quick menu " + language)
        element(app, "reader.settings").tap()
        capture(app, "Localized reader settings " + language)
        element(app, "reader.settings.done").tap()
    }

    func testImmersiveReaderGesturesPreviewAndBookmark() {
        let app = launchReader()
        XCTAssertEqual(app.navigationBars.count, 0)
        XCTAssertFalse(element(app, "reader.position").exists)
        capture(app, "Immersive reader without chrome")
        let image = element(app, "reader.image")
        image.doubleTap()
        wait(image, "value == %@", "250%")
        image.doubleTap()
        wait(image, "value == %@", "100%")
        tap(app, x: 0.9)
        menu(app)
        XCTAssertEqual(element(app, "reader.position").label, "페이지 2 / 3")
        element(app, "reader.menu.close").tap()
        tap(app, x: 0.1)
        menu(app)
        XCTAssertEqual(element(app, "reader.position").label, "페이지 1 / 3")
        XCTAssertFalse(element(app, "reader.previous").isEnabled)
        capture(app, "Reader quick menu Liquid Glass white controls")
        element(app, "reader.preview").tap()
        let last = element(app, "reader.preview.3")
        XCTAssertTrue(last.waitForExistence(timeout: 10))
        last.tap()
        XCTAssertEqual(element(app, "reader.position").label, "페이지 3 / 3")
        XCTAssertFalse(element(app, "reader.next").isEnabled)
        element(app, "reader.menu.close").tap()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.8)
        XCTAssertTrue(element(app, "reader.toast").waitForExistence(timeout: 3))
        XCTAssertEqual(element(app, "reader.toast").label, "북마크를 표시했습니다")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(element(app, "reader.image").waitForExistence(timeout: 5))
        XCUIDevice.shared.orientation = .portrait
        XCUIDevice.shared.press(.home)
        app.activate()
        menu(app)
        element(app, "reader.exit").tap()
        XCTAssertTrue(element(app, "content.read").waitForExistence(timeout: 5))
        XCTAssertEqual(app.webViews.count, 0)
    }

    func testReadingModesAndPersistentQuickMenu() {
        let app = launchReader()
        menu(app)
        element(app, "reader.settings").tap()
        let rtl = element(app, "reader.settings.rtl")
        rtl.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        wait(rtl, "value == %@", "1")
        let bottom = element(app, "reader.settings.bottomMenu")
        bottom.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        wait(bottom, "value == %@", "1")
        element(app, "reader.settings.done").tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element(app, "reader.settings.done"))
        waitForExpectations(timeout: 10)
        expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: element(app, "reader.menu.close"))
        waitForExpectations(timeout: 10)
        element(app, "reader.menu.close").tap()
        XCTAssertTrue(element(app, "reader.settings").waitForExistence(timeout: 5))
        // Allow the sheet and glass morph transition to complete before capturing pixels.
        sleep(1)
        capture(app, "Persistent Liquid Glass white controls")
        tap(app, x: 0.1)
        menu(app)
        XCTAssertEqual(element(app, "reader.position").label, "페이지 2 / 3")
        element(app, "reader.settings").tap()
        element(app, "reader.settings.mode").tap()
        app.buttons["수직으로 넘기기"].tap()
        element(app, "reader.settings.done").tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element(app, "reader.settings.done"))
        waitForExpectations(timeout: 10)
        expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: element(app, "reader.menu.close"))
        waitForExpectations(timeout: 10)
        element(app, "reader.menu.close").tap()
        app.swipeUp()
        menu(app)
        XCTAssertEqual(element(app, "reader.position").label, "페이지 3 / 3")
        element(app, "reader.settings").tap()
        element(app, "reader.settings.mode").tap()
        app.buttons["스크롤로 보기"].tap()
        element(app, "reader.settings.done").tap()
        element(app, "reader.preview").tap()
        element(app, "reader.preview.1").tap()
        element(app, "reader.menu.close").tap()
        app.swipeUp()
        menu(app)
        XCTAssertNotEqual(element(app, "reader.position").label, "페이지 1 / 3")
        capture(app, "Continuous reader with quick menu")
    }

    func testOneTapTranslationOnDevice() throws {
        let app = launchReader()
        menu(app)
        element(app, "reader.translate").tap()
        XCTAssertTrue(element(app, "reader.original").waitForExistence(timeout: 10))
        let progress = element(app, "reader.translation.progress")
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: progress)
        waitForExpectations(timeout: 60)
        sleep(5)
        capture(app, "Apple Live Text image translation")
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["ko-KR", "en-US"]
        try VNImageRequestHandler(cgImage: try XCTUnwrap(app.screenshot().image.cgImage)).perform([request])
        let visibleText = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        XCTAssertTrue(visibleText.contains("확대하려면") && visibleText.contains("탭하세요"), "The actual Apple overlay must display translated page content: \(visibleText)")
        let translatedImage = element(app, "reader.translation.image")
        translatedImage.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleTap()
        wait(translatedImage, "value == %@", "250%")
        sleep(5)
        XCTAssertEqual(translatedImage.value as? String, "250%", "Zoom must preserve the existing translation without starting OCR again")
        capture(app, "Apple image translation enlarged")
        XCTAssertFalse(element(app, "reader.translation.progress").exists, "Zoom must not restart analysis")
        XCTAssertFalse(element(app, "reader.translation.retry").exists)
        XCTAssertEqual(element(app, "reader.translation.canvas").value as? String, "분석 1회")
        try VNImageRequestHandler(cgImage: try XCTUnwrap(app.screenshot().image.cgImage)).perform([request])
        let enlargedText = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        XCTAssertTrue(enlargedText.contains("탭") || enlargedText.contains("확대"), "The enlarged page must still contain translated content: \(enlargedText)")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.55))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.75)))
        app.pinch(withScale: 1.2, velocity: 1)
        sleep(1)
        XCTAssertNotEqual(translatedImage.value as? String, "250%", "Pinch must reach the image through the system overlay")
        XCTAssertNotEqual(translatedImage.value as? String, "100%")
        XCTAssertEqual(element(app, "reader.translation.canvas").value as? String, "분석 1회")
        try VNImageRequestHandler(cgImage: try XCTUnwrap(app.screenshot().image.cgImage)).perform([request])
        let controlsText = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        XCTAssertTrue(controlsText.contains { $0.contains("번역") }, "The native translation control must stay on screen after zoom and pan")
        capture(app, "Translation controls remain in viewport after pan and pinch")
        element(app, "reader.original").tap()
        XCTAssertFalse(element(app, "reader.original").exists)
        XCTAssertTrue(element(app, "reader.image").exists)
    }

    func testJapaneseTranslationStartsOnRepeatedOpen() throws {
        let app = launchReader(extra: ["--reader-japanese-test"])
        for attempt in 1...3 {
            menu(app)
            element(app, "reader.translate").tap()
            XCTAssertTrue(element(app, "reader.original").waitForExistence(timeout: 10))
            expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element(app, "reader.translation.progress"))
            waitForExpectations(timeout: 60)
            sleep(5)
            capture(app, "Japanese automatic translation \(attempt)")
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["ko-KR", "ja-JP"]
            try VNImageRequestHandler(cgImage: try XCTUnwrap(app.screenshot().image.cgImage)).perform([request])
            let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
            XCTAssertTrue(text.contains("날씨") || text.contains("공원"), "Actual translated page content is required: \(text)")
            XCTAssertFalse(element(app, "reader.translation.retry").exists)
            element(app, "reader.original").tap()
        }
    }

    func testZoomedShortPagePansVerticallyWithoutExitOrPaging() {
        let app = launchReader(extra: ["--reader-short-page-test"])
        let image = element(app, "reader.image")
        image.doubleTap()
        wait(image, "value == %@", "250%")
        let before = image.frame
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)))
        sleep(1)
        XCTAssertTrue(image.exists)
        XCTAssertFalse(element(app, "content.read").exists, "Downward pan while zoomed must never dismiss")
        XCTAssertGreaterThan(image.frame.minY, before.minY + 80, "Short pages need real vertical travel, not only bounce")
        app.swipeLeft()
        XCTAssertEqual(image.value as? String, "250%", "Horizontal pan must not turn a page")
        capture(app, "Short zoomed image with free vertical movement")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleTap()
        wait(image, "value == %@", "100%")
        tap(app, x: 0.9)
        menu(app)
        XCTAssertEqual(element(app, "reader.position").label, "페이지 2 / 3")
        element(app, "reader.menu.close").tap()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)))
        XCTAssertTrue(element(app, "content.read").waitForExistence(timeout: 5))
    }

    func testHelpCanBeDismissedAndReopened() {
        let app = launchReader(extra: ["--reader-help-test"])
        XCTAssertTrue(element(app, "reader.help.close").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "reader.help.visual").exists)
        capture(app, "Reader help tap overlay")
        app.buttons["확대·번역"].tap()
        capture(app, "Reader help zoom overlay")
        app.buttons["나가기"].tap()
        capture(app, "Reader help exit overlay")
        element(app, "reader.help.never").tap()
        menu(app)
        element(app, "reader.settings").tap()
        app.swipeUp()
        app.swipeUp()
        element(app, "reader.settings.help").tap()
        XCTAssertTrue(element(app, "reader.help.close").waitForExistence(timeout: 5))
        element(app, "reader.help.close").tap()
    }

    func testMultiplePagesAutoAdvanceAndDownwardExit() {
        let app = launchReader(extra: ["--reader-auto-test"])
        menu(app)
        element(app, "reader.settings").tap()
        element(app, "reader.settings.spread").tap()
        app.buttons["2페이지"].tap()
        let auto = element(app, "reader.settings.auto")
        auto.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        element(app, "reader.settings.done").tap()
        element(app, "reader.menu.close").tap()
        capture(app, "Two pages side by side")
        // Auto advance moves by the spread size; the quick menu then pauses it.
        sleep(3)
        menu(app)
        XCTAssertEqual(element(app, "reader.position").label, "페이지 3 / 3")
        // The exit gesture also works while the quick menu is open.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)))
        XCTAssertTrue(element(app, "content.read").waitForExistence(timeout: 5))
    }

    func testExploreTabAndDetailSearch() {
        let app = XCUIApplication()
        app.launchArguments = ["--native-content-ui-test", "-AppleLanguages", "(ko)", "-AppleLocale", "ko_KR", "--native-content-tab-test"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["탐색"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.tabBars.buttons["전체"].exists)
        app.tabBars.buttons["탐색"].tap()
        XCTAssertFalse(element(app, "content.open").exists)
        XCTAssertFalse(element(app, "content.close").exists)
        element(app, "content.sort").tap()
        app.buttons["주간 인기순"].tap()
        element(app, "content.language").tap()
        app.buttons["영어"].tap()
        let card = element(app, "content.gallery.900000001")
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        card.tap()
        element(app, "content.read").tap()
        menu(app)
        element(app, "reader.details").tap()
        app.buttons["female:sample"].tap()
        XCTAssertTrue(element(app, "content.gallery.900000001").waitForExistence(timeout: 10))
        XCTAssertEqual(element(app, "content.search").value as? String, "female:sample")
        capture(app, "Explore tab tag search")
    }

    func testFolderQuickJumpToOldestAndMonth() {
        let app = XCUIApplication()
        app.launchArguments = ["--native-content-ui-test", "-AppleLanguages", "(ko)", "-AppleLocale", "ko_KR", "--library-jump-test"]
        app.launch()
        let jump = element(app, "works.jump")
        XCTAssertTrue(jump.waitForExistence(timeout: 10))
        XCTAssertLessThanOrEqual(element(app, "works.add").frame.midX - jump.frame.midX, 44)
        jump.tap()
        app.buttons["맨 아래로"].tap()
        let oldest = element(app, "works.card.910000120")
        expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: oldest)
        waitForExpectations(timeout: 10)
        capture(app, "Folder oldest work without scrolling")
        jump.tap()
        app.buttons["맨 위로"].tap()
        XCTAssertTrue(element(app, "works.card.910000001").isHittable)
        jump.tap()
        app.buttons["저장한 달로 이동"].tap()
        let august = element(app, "works.month.2026-08")
        XCTAssertTrue(august.waitForExistence(timeout: 5))
        capture(app, "Folder month picker")
        august.tap()
        expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: element(app, "works.card.910000061"))
        waitForExpectations(timeout: 10)
        capture(app, "Folder jumped to August")
    }

    func testExploreScrollSearchAndTagCompletion() {
        let app = XCUIApplication()
        app.launchArguments = ["--native-content-ui-test", "-AppleLanguages", "(ko)", "-AppleLocale", "ko_KR", "--native-content-long-feed"]
        app.launch()
        let search = element(app, "content.search")
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        app.swipeUp()
        capture(app, "Explore after scroll")
        expectation(for: NSPredicate { _, _ in !search.exists || !search.isHittable }, evaluatedWith: search)
        waitForExpectations(timeout: 5)
        app.swipeDown()
        expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: search)
        waitForExpectations(timeout: 5)
        search.tap()
        search.typeText("language:korean female:sa")
        let suggestion = element(app, "content.suggestion.female:sample_tag")
        XCTAssertTrue(suggestion.waitForExistence(timeout: 5))
        capture(app, "Explore tag autocomplete")
        suggestion.tap()
        XCTAssertEqual(search.value as? String, "language:korean female:sample_tag ")
        search.typeText("\n")
        XCTAssertTrue(element(app, "content.gallery.900000001").waitForExistence(timeout: 10))
        XCTAssertFalse(suggestion.exists)
        capture(app, "Explore completed tag search")
    }

    func testWorkDetailsSheetKeepsLayoutWhileCoverLoadsAndDismissesDownward() {
        let app = XCUIApplication()
        app.launchArguments = ["--native-content-ui-test", "--slow-detail-cover-test", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let card = element(app, "content.gallery.900000001")
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        let cardY = card.frame.minY
        card.tap()
        let read = element(app, "content.read"), cover = element(app, "content.detail.cover"), title = element(app, "content.detail.title")
        XCTAssertTrue(read.waitForExistence(timeout: 10))
        XCTAssertEqual(cover.value as? String, "Loading")
        let coverFrame = cover.frame, titleY = title.frame.minY, readY = read.frame.minY
        XCTAssertEqual(coverFrame.height, 300, accuracy: 1)
        capture(app, "Work details with reserved thumbnail placeholder")
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Thumbnail loaded"), object: cover)
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 25), .completed)
        XCTAssertEqual(cover.frame.height, coverFrame.height, accuracy: 1)
        XCTAssertEqual(title.frame.minY, titleY, accuracy: 1)
        XCTAssertEqual(read.frame.minY, readY, accuracy: 1)
        capture(app, "Work details after thumbnail load without layout shift")
        read.tap()
        XCTAssertTrue(element(app, "reader.exitHandle").waitForExistence(timeout: 5))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)))
        XCTAssertTrue(element(app, "reader.exitHandle").waitForNonExistence(timeout: 5))
        XCTAssertTrue(read.isHittable)
        // Dismiss from the content, including after returning from the immersive reader.
        cover.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)))
        XCTAssertTrue(read.waitForNonExistence(timeout: 5))
        XCTAssertTrue(card.isHittable)
        XCTAssertEqual(card.frame.minY, cardY, accuracy: 1)
    }

    func testImageFailureStillAllowsExit() {
        let app = XCUIApplication()
        app.launchArguments = ["--native-content-ui-test", "-AppleLanguages", "(ko)", "-AppleLocale", "ko_KR", "--native-content-image-error"]
        app.launch()
        XCTAssertTrue(element(app, "content.gallery.900000001").waitForExistence(timeout: 10))
        element(app, "content.gallery.900000001").tap()
        XCTAssertTrue(element(app, "content.read").waitForExistence(timeout: 10))
        element(app, "content.read").tap()
        XCTAssertTrue(element(app, "content.retry").waitForExistence(timeout: 10))
        tap(app, x: 0.5, y: 0.3)
        XCTAssertTrue(element(app, "reader.exit").waitForExistence(timeout: 5))
        element(app, "reader.exit").tap()
        XCTAssertTrue(element(app, "content.read").waitForExistence(timeout: 5))
    }

    func testBrowseLongPressAndNetworkRetry() {
        let app = XCUIApplication()
        app.launchArguments = ["--native-content-ui-test", "-AppleLanguages", "(ko)", "-AppleLocale", "ko_KR", "--native-content-initial-error"]
        app.launch()
        let retry = element(app, "content.retry")
        XCTAssertTrue(retry.waitForExistence(timeout: 10))
        retry.tap()
        let card = element(app, "content.gallery.900000001")
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, "content.grid").exists)
        capture(app, "Browse shared gallery grid")
        XCTAssertEqual(card.value as? String, "북마크 안 됨")
        card.press(forDuration: 0.8)
        XCTAssertTrue(element(app, "content.toast").waitForExistence(timeout: 3))
        XCTAssertEqual(element(app, "content.toast").label, "북마크를 표시했습니다")
        wait(card, "value == %@", "북마크됨")
        capture(app, "Explore bookmark badge")
        XCTAssertFalse(element(app, "content.read").exists, "Long press must not also open the gallery")
        card.press(forDuration: 0.8)
        wait(card, "value == %@", "북마크 안 됨")
        XCTAssertEqual(element(app, "content.toast").label, "북마크를 해제했습니다")
        for _ in 0..<3 {
            app.swipeDown()
            XCTAssertTrue(card.waitForExistence(timeout: 5))
            XCTAssertFalse(app.staticTexts["결과 없음"].exists)
        }
        capture(app, "Explore bookmark removed and refresh retained")
    }
}
