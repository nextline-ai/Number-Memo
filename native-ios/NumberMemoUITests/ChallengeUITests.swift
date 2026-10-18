import XCTest

final class ChallengeUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
    private func launch(language: String = "en", largeText: Bool = false, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--booru-ui-test", "--challenge-ui-test", "-AppleLanguages", "(\(language))", "-AppleLocale", language == "ko" ? "ko_KR" : language == "ja" ? "ja_JP" : "en_US"]
        app.launchArguments += extra
        if largeText { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        if extra.contains("--splash-ui-test") {
            let finished = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element(app, "splash.launch"))
            XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 8), .completed)
        }
        let more = language == "ko" ? "더보기" : language == "ja" ? "その他" : "More"
        let tab = app.tabBars.buttons[more]
        if tab.exists { tab.tap() }
        else { app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", more)).firstMatch.tap() }
        let link = element(app, "booru.challengesLink")
        XCTAssertTrue(link.waitForExistence(timeout: 10)); link.tap()
        return app
    }
    private func reveal(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        let value = element(app, id)
        for _ in 0..<16 {
            let top = app.navigationBars.allElementsBoundByIndex.filter { $0.isHittable }.map { $0.frame.maxY }.max() ?? 140
            let visible = value.exists && value.isHittable && value.frame.midY > top + 10 && value.frame.midY < app.frame.maxY - 40
            if visible { return value }
            scroll(app, up: !value.exists || value.frame.midY > top + 10)
        }
        XCTAssertTrue(value.isHittable, id); return value
    }
    private func scroll(_ app: XCUIApplication, up: Bool) {
        // Drag the form margin, not a multiline field's internal scroll view.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: up ? 0.78 : 0.28))
            .press(forDuration: 0.01, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: up ? 0.28 : 0.78)))
    }
    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
    func testCountChallengeImagesViewerAndEnding() {
        let app = launch()
        element(app, "challenge.game.ui-count").tap()
        let draw = element(app, "challenge.draw"); XCTAssertTrue(draw.waitForExistence(timeout: 5)); draw.tap()
        XCTAssertTrue(element(app, "challenge.mission").waitForExistence(timeout: 5))
        reveal(app, "challenge.source").tap()
        element(app, "challenge.sourceDone").tap()
        let search = reveal(app, "booru.search")
        XCTAssertEqual(search.value as? String, "scenery")
        screenshot(app, "Shared reference feed")
        let image = reveal(app, "booru.post.101"); XCTAssertTrue(image.waitForExistence(timeout: 10)); image.tap()
        let media = element(app, "booru.mediaStatus")
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "ready"), object: media)
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 15), .completed)
        let mission = element(app, "challenge.viewerPanel")
        XCTAssertTrue(mission.waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "challenge.count").exists)
        XCTAssertFalse(element(app, "challenge.complete").isEnabled)
        XCTAssertLessThan(element(app, "challenge.viewerCapsule").frame.height, 65)
        XCTAssertLessThan(element(app, "challenge.viewerCapsule").frame.width, app.frame.width * 0.75)
        screenshot(app, "Compact mission capsule")
        element(app, "challenge.increment").tap()
        element(app, "challenge.complete").tap()
        let ending = element(app, "challenge.ending"); XCTAssertTrue(ending.waitForExistence(timeout: 10))
        screenshot(app, "Challenge ending")
    }
    func testTimerContinueAndManualCompletion() {
        let app = launch()
        element(app, "challenge.game.ui-timer").tap()
        XCTAssertTrue(element(app, "challenge.draw").waitForExistence(timeout: 5))
        element(app, "challenge.draw").tap()
        reveal(app, "challenge.timerToggle").tap()
        element(app, "challenge.close").tap()
        element(app, "challenge.game.ui-timer").tap()
        let complete = reveal(app, "challenge.complete")
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: complete)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 6), .completed)
        screenshot(app, "Timer resumed and ready")
        XCTAssertFalse(element(app, "challenge.ending").exists)
        complete.tap()
        XCTAssertTrue(element(app, "challenge.ending").waitForExistence(timeout: 5))
    }
    func testKoreanLargeTextAndSavedFolderSelection() {
        let app = launch(language: "ko", largeText: true)
        reveal(app, "challenge.game.ui-count").tap()
        reveal(app, "challenge.draw").tap()
        reveal(app, "challenge.source").tap()
        app.buttons["저장 폴더"].tap()
        element(app, "challenge.folderPicker").tap()
        app.buttons["Sketch References"].tap()
        element(app, "challenge.sourceDone").tap()
        let image = reveal(app, "booru.post.101")
        XCTAssertTrue(image.exists)
        screenshot(app, "Korean accessible challenge")
        reveal(app, "challenge.increment").tap()
        reveal(app, "challenge.complete").tap()
        XCTAssertTrue(element(app, "challenge.ending").waitForExistence(timeout: 5))
    }

    func testEditorCreatePreviewAndBackupEntry() {
        let app = launch()
        reveal(app, "challenge.new").tap()
        let title = element(app, "challenge.title")
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        screenshot(app, "Beginner editor")
        XCTAssertFalse(element(app, "challenge.template").exists)
        title.tap(); title.typeText(" Custom")
        element(app, "challenge.previewTop").tap()
        XCTAssertTrue(element(app, "challenge.draw").waitForExistence(timeout: 5))
        XCTAssertFalse(element(app, "challenge.gameDescription").exists)
        reveal(app, "challenge.draw").tap()
        screenshot(app, "Editor preview")
        app.buttons["Done"].tap()
        element(app, "challenge.save").tap()
        XCTAssertTrue(element(app, "challenge.new").waitForExistence(timeout: 5))
        reveal(app, "challenge.backup").tap()
        XCTAssertTrue(element(app, "challenge.export").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "challenge.import").exists)
        XCTAssertTrue(app.navigationBars["Challenge Backup and Import"].exists)
        XCTAssertFalse(app.staticTexts["Restore Preview"].exists)
        XCTAssertFalse(app.switches["Replace Matching Challenges"].exists)
        screenshot(app, "Challenge backup")
    }
    func testAdvancedRulesRemainAvailableAndDefaultRatingIsAll() {
        let app = launch()
        screenshot(app, "Challenge library")
        reveal(app, "challenge.new").tap()
        reveal(app, "challenge.advanced").tap()
        XCTAssertTrue(element(app, "challenge.template").waitForExistence(timeout: 5))
        screenshot(app, "Advanced rules")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["Cancel"].tap()
        app.buttons["Discard"].tap()
        reveal(app, "challenge.game.ui-count").tap()
        element(app, "challenge.menu").tap()
        XCTAssertFalse(app.buttons["Animation Speed"].exists)
        element(app, "challenge.help").tap()
        XCTAssertTrue(element(app, "challenge.gameDescription").waitForExistence(timeout: 5))
        element(app, "challenge.helpTab.tips").tap()
        XCTAssertTrue(element(app, "challenge.gameDescription").label.contains("Choose clear shapes"))
        screenshot(app, "Tabbed game instructions")
        app.buttons["Done"].tap()
        reveal(app, "challenge.draw").tap()
        reveal(app, "challenge.source").tap()
        XCTAssertFalse(app.buttons["Rating, All Ratings"].exists)
        element(app, "challenge.sourceDone").tap()
        let rating = reveal(app, "booru.rating")
        XCTAssertTrue(rating.label.contains("All Ratings"))
        screenshot(app, "Single image rating filter")
    }

    func testExampleIsReusedAndCanBeDeletedFromVisibleMenu() {
        let app = launch()
        for attempt in 0..<2 {
            reveal(app, "challenge.example").tap()
            if attempt == 0 {
                let draw = element(app, "challenge.draw")
                XCTAssertTrue(draw.waitForExistence(timeout: 5)); draw.tap()
            }
            XCTAssertTrue(element(app, "challenge.mission").waitForExistence(timeout: 6))
            if attempt == 1 { screenshot(app, "Centered roulette and resumed example") }
            element(app, "challenge.close").tap()
        }
        let id = "challenge.game.builtin.croquis.v1"
        XCTAssertTrue(element(app, id).waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(identifier: id).count, 1)
        reveal(app, "challenge.actions.builtin.croquis.v1").tap()
        app.buttons["Delete"].tap()
        app.alerts.buttons["Delete"].tap()
        let removed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element(app, id))
        XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 10), .completed)
        screenshot(app, "Example deleted")
    }
    func testCreateHelpTabAndPreviewIt() {
        let app = launch()
        reveal(app, "challenge.new").tap()
        reveal(app, "challenge.editHelp").tap()
        element(app, "challenge.addHelp").tap()
        app.buttons["New Help Tab"].tap()
        let body = element(app, "challenge.helpBody")
        body.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        // iPad's software keyboard can drop a burst while its presentation settles.
        for character in "My drawing tips." { body.typeText(String(character)) }
        XCTAssertEqual(body.value as? String, "My drawing tips.")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        element(app, "challenge.previewTop").tap()
        element(app, "challenge.menu").tap()
        element(app, "challenge.help").tap()
        app.buttons["New Help Tab"].tap()
        XCTAssertEqual(element(app, "challenge.gameDescription").label, "My drawing tips.")
        screenshot(app, "User authored help tab")
    }

    func testReferenceSearchHidesDownAndReturnsWhenScrollingUp() {
        let app = launch(extra: ["--challenge-scroll-test"])
        element(app, "challenge.game.ui-count").tap()
        element(app, "challenge.draw").tap()
        reveal(app, "challenge.source").tap()
        element(app, "challenge.sourceDone").tap()
        let search = reveal(app, "booru.search")
        XCTAssertEqual(search.value as? String, "scenery")
        for _ in 0..<4 { scroll(app, up: true) }
        XCTAssertFalse(search.isHittable)
        scroll(app, up: false)
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        XCTAssertTrue(search.isHittable)
        XCTAssertLessThan(search.frame.midY, app.frame.height / 3)
        screenshot(app, "Search returns above scrolled images")
        scroll(app, up: true)
        XCTAssertFalse(search.isHittable)
    }
    func testColdSplashAndRepeatedResumeKeepChallengeState() {
        let app = launch(extra: ["--splash-ui-test"])
        XCTAssertFalse(element(app, "splash.launch").exists)
        element(app, "challenge.game.ui-count").tap()
        element(app, "challenge.draw").tap()
        XCTAssertTrue(element(app, "challenge.mission").waitForExistence(timeout: 8))
        for _ in 0..<2 {
            XCUIDevice.shared.press(.home)
            app.activate()
            let removed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element(app, "privacy.cover"))
            XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 5), .completed)
            XCTAssertTrue(element(app, "challenge.mission").exists)
        }
        reveal(app, "challenge.increment").tap()
        reveal(app, "challenge.complete").tap()
        XCTAssertTrue(element(app, "challenge.ending").waitForExistence(timeout: 10))
    }

    func testFullReelAndEndingAnimations() {
        let app = launch(extra: ["--challenge-motion-test"])
        element(app, "challenge.game.ui-count").tap()
        element(app, "challenge.draw").tap()
        XCTAssertTrue(element(app, "challenge.mission").waitForExistence(timeout: 8))
        screenshot(app, "Large filled roulette reels")
        reveal(app, "challenge.increment").tap()
        reveal(app, "challenge.complete").tap()
        XCTAssertTrue(element(app, "challenge.ending").waitForExistence(timeout: 10))
        screenshot(app, "Animated final result")
    }

}
