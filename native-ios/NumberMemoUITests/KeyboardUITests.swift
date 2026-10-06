import XCTest

final class KeyboardUITests: XCTestCase {
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
    func testWideThumbnailTapAndSelectionStayInsideTheirOwnCard() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--booru-ui-test", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let explore = element(app, "globe")
        XCTAssertTrue(explore.waitForExistence(timeout: 10)); explore.tap()
        let state = element(app, "booru.viewerState")
        for id in [101, 102] {
            let post = element(app, "booru.post.\(id)")
            XCTAssertTrue(post.waitForExistence(timeout: 10))
            for x in [0.1, 0.5, 0.9] {
                post.coordinate(withNormalizedOffset: CGVector(dx: x, dy: 0.5)).tap()
                XCTAssertTrue(state.wait(for: \.label, toEqual: "\(id):fit", timeout: 5))
                element(app, "booru.pointerClose").tap()
                XCTAssertTrue(state.waitForNonExistence(timeout: 5))
            }
            post.press(forDuration: 0.7)
            XCTAssertTrue(element(app, "booru.favoriteBadge.\(id)").waitForExistence(timeout: 5))
        }
        element(app, "folder.fill").tap()
        element(app, "booru.allFavorites").tap()
        element(app, "booru.select").tap()
        let first = element(app, "booru.post.101"), second = element(app, "booru.post.102")
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        first.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(first.value as? String, "Selected")
        XCTAssertEqual(second.value as? String, "")
        first.tap()
        XCTAssertEqual(first.value as? String, "")
        second.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap()
        XCTAssertEqual(second.value as? String, "Selected")
        XCTAssertEqual(first.value as? String, "")
    }

    func testOnboardingSuggestionsImportBannerAndSafeRefresh() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--booru-ui-test", "--onboarding-test", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let addServer = element(app, "onboarding.addServer")
        XCTAssertTrue(addServer.waitForExistence(timeout: 10)); addServer.tap()
        let address = element(app, "booru.serverURL")
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        address.tap(); address.typeText("s")
        let suggestion = element(app, "website.suggestion.safebooru.org")
        XCTAssertTrue(suggestion.waitForExistence(timeout: 5)); suggestion.tap()
        element(app, "booru.serverSave").tap()
        for _ in 0..<3 { element(app, "onboarding.continue").tap() }
        let banner = element(app, "importReminder.open")
        XCTAssertTrue(banner.waitForExistence(timeout: 5))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Post-onboarding import banner"; shot.lifetime = .keepAlways; add(shot)
        banner.tap()
        XCTAssertTrue(element(app, "onboarding.violetImport").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "onboarding.import").exists)
        element(app, "onboarding.continue").tap()
        XCTAssertTrue(banner.waitForNonExistence(timeout: 5))
        element(app, "globe").tap()
        let post = element(app, "booru.post.101")
        XCTAssertTrue(post.waitForExistence(timeout: 10))
        XCTAssertFalse(element(app, "booru.rating").exists)
        app.scrollViews.firstMatch.swipeDown()
        XCTAssertTrue(post.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["No Posts"].exists)
    }

    func testImageViewerKeyboardAndDialogIsolation() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--booru-ui-test", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let explore = element(app, "globe")
        XCTAssertTrue(explore.waitForExistence(timeout: 10)); explore.tap()
        let post = element(app, "booru.post.101")
        XCTAssertTrue(post.waitForExistence(timeout: 10))
        post.press(forDuration: 0.7)
        XCTAssertTrue(element(app, "booru.favoriteBadge.101").waitForExistence(timeout: 5))
        XCTAssertFalse(element(app, "booru.pointerClose").exists)
        post.press(forDuration: 0.7)
        XCTAssertTrue(element(app, "booru.favoriteBadge.101").waitForNonExistence(timeout: 5))
        post.tap()
        let state = element(app, "booru.viewerState")
        XCTAssertTrue(state.waitForExistence(timeout: 10))
        app.typeKey(XCUIKeyboardKey.rightArrow, modifierFlags: [])
        XCTAssertTrue(state.wait(for: \.label, toEqual: "102:fit", timeout: 5))
        app.typeKey(XCUIKeyboardKey.leftArrow, modifierFlags: [])
        XCTAssertTrue(state.wait(for: \.label, toEqual: "101:fit", timeout: 5))
        app.typeKey("m", modifierFlags: [])
        XCTAssertTrue(element(app, "booru.favorite").waitForExistence(timeout: 5))
        app.typeKey("f", modifierFlags: [])
        XCTAssertTrue(element(app, "booru.favorite").wait(for: \.label, toEqual: "Remove Favorite", timeout: 5))
        app.typeKey("f", modifierFlags: [])
        XCTAssertTrue(element(app, "booru.favorite").wait(for: \.label, toEqual: "Add Favorite", timeout: 5))
        element(app, "booru.pointerClose").tap()
        XCTAssertTrue(state.waitForNonExistence(timeout: 5))
        post.tap()
        XCTAssertTrue(state.waitForExistence(timeout: 5))
        app.typeKey("i", modifierFlags: [])
        XCTAssertTrue(element(app, "booru.postID").waitForExistence(timeout: 5))
        let originalID = element(app, "booru.postID").label
        app.typeKey(XCUIKeyboardKey.rightArrow, modifierFlags: [])
        XCTAssertEqual(element(app, "booru.postID").label, originalID)
        app.buttons["Done"].tap()
        XCTAssertTrue(element(app, "booru.postID").waitForNonExistence(timeout: 5))
        // A sheet dismissal must restore navigation without dismissing the work.
        app.typeKey(XCUIKeyboardKey.rightArrow, modifierFlags: [])
        XCTAssertTrue(state.wait(for: \.label, toEqual: "102:fit", timeout: 5))
        XCTAssertTrue(element(app, "booru.pointerClose").waitForExistence(timeout: 5))
        element(app, "booru.pointerClose").tap()
        XCTAssertTrue(state.waitForNonExistence(timeout: 5))
    }
}
