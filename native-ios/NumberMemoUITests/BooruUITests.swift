import XCTest

final class BooruUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        #if targetEnvironment(simulator)
        XCUIDevice.shared.orientation = .portrait
        #endif
    }
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
    private func launch(extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--booru-ui-test", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"] + extra
        app.launch()
        if !extra.contains("--onboarding-test") {
            let tab = app.tabBars.buttons["Explore"]
            if tab.exists { tab.tap() }
            else { app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Explore")).firstMatch.tap() }
        }
        return app
    }
    private func reveal(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        let value = element(app, id)
        for _ in 0..<6 {
            if value.exists && value.isHittable { return value }
            app.swipeUp()
        }
        XCTAssertTrue(value.isHittable, "Missing control: " + id)
        return value
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        // UIKit's glass morph can outlive accessibility idleness after tab changes.
        Thread.sleep(forTimeInterval: 1)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    private func exitViewer(_ app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)))
    }
    private func firstTasteCard(_ app: XCUIApplication) -> XCUIElement {
        let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "taste.work."))
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 20))
        return cards.allElementsBoundByIndex.first { $0.isHittable } ?? cards.firstMatch
    }
    private func openMenu(_ app: XCUIApplication) {
        if !element(app, "booru.menuClose").exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            if !element(app, "booru.menuClose").waitForExistence(timeout: 1) { app.twoFingerTap() }
            XCTAssertTrue(element(app, "booru.menuClose").waitForExistence(timeout: 5))
        }
    }

    func testSavedImageOffersSimilarArtStyleSearch() {
        let app = launch(extra: ["--taste-ui-rich"])
        app.tabBars.buttons["Saved"].tap()
        element(app, "booru.allFavorites").tap()
        let post = element(app, "booru.post.108")
        XCTAssertTrue(post.waitForExistence(timeout: 5))
        post.press(forDuration: 0.8)
        let action = app.buttons["Find works with a similar art style"]
        XCTAssertTrue(action.waitForExistence(timeout: 5))
        action.tap()
        XCTAssertTrue(app.navigationBars["Similar art styles"].waitForExistence(timeout: 5))
        capture(app, "Saved visual similarity search")
        app.buttons["Done"].tap()
    }

    func testSharedServerSelectionAllowsNoneAcrossAllTabs() {
        let app = launch(extra: ["--taste-ui-rich"])
        element(app, "booru.server").tap()
        XCTAssertFalse(app.buttons["Deselect All"].exists)
        XCTAssertFalse(app.buttons["Select All"].exists)
        app.buttons["Danbooru"].tap()
        // The multiselect menu stays open so several servers can be changed together.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.55)).tap()
        XCTAssertTrue(element(app, "booru.noSelection").waitForExistence(timeout: 5))
        for title in ["Saved", "Tags", "Smart"] {
            app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", title)).firstMatch.tap()
            XCTAssertTrue(element(app, "booru.server").waitForExistence(timeout: 5))
            XCTAssertTrue(element(app, "booru.noSelection").waitForExistence(timeout: 5))
        }
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "More")).firstMatch.tap()
        XCTAssertTrue(element(app, "booru.server").waitForExistence(timeout: 5))
        element(app, "booru.server").tap()
        app.buttons["Danbooru"].tap()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.55)).tap()
        capture(app, "Shared server selection")
    }

    func testTasteAnalysisNavigationAndControls() {
        let app = launch()
        let post = element(app, "booru.post.101")
        XCTAssertTrue(post.waitForExistence(timeout: 10))
        post.press(forDuration: 0.7)
        let entry = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Smart")).firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 5)); entry.tap()
        XCTAssertTrue(element(app, "taste.dashboard").waitForExistence(timeout: 10))
        XCTAssertEqual(app.sheets.count, 0)
        XCTAssertFalse(app.alerts["Discover your taste"].exists)
        XCTAssertTrue(element(app, "taste.highlight").waitForExistence(timeout: 10))
        capture(app, "Taste recommendations")
        XCTAssertFalse(element(app, "taste.period").exists)
        app.navigationBars.buttons["Settings"].tap()
        element(app, "taste.settings.weekly").tap()
        XCTAssertTrue(app.staticTexts["Newly saved works"].waitForExistence(timeout: 5))
        capture(app, "Taste weekly report")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let toggle = app.switches["taste.enabled"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        capture(app, "Taste before pause")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertTrue(app.alerts["Turn off taste analysis?"].waitForExistence(timeout: 5))
        app.alerts.buttons["Keep Enabled"].tap()
        XCTAssertEqual(toggle.value as? String, "1")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        app.alerts.buttons["Turn Off"].tap()
        let paused = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '0'"), object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [paused], timeout: 5), .completed)
        XCTAssertEqual(toggle.value as? String, "0")
        capture(app, "Taste analysis settings")
        XCTAssertFalse(app.switches["taste.ai"].exists)
    }

    func testTasteCardsDetailsAndEmptyStart() {
        let empty = launch()
        empty.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Smart")).firstMatch.tap()
        XCTAssertTrue(element(empty, "taste.empty").waitForExistence(timeout: 10))
        capture(empty, "AI getting started")
        element(empty, "taste.startExploring").tap()
        XCTAssertTrue(element(empty, "booru.search").waitForExistence(timeout: 5))
        empty.terminate()

        let app = launch(extra: ["--taste-ui-rich"])
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Smart")).firstMatch.tap()
        XCTAssertTrue(element(app, "taste.highlight").waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, "taste.work.201").waitForExistence(timeout: 20))
        capture(app, "AI recommendations with works")
        element(app, "taste.highlight").tap()
        XCTAssertTrue(element(app, "taste.tag.detail").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Your evidence"].exists)
        capture(app, "AI taste evidence")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons["Settings"].tap()
        element(app, "taste.settings.weekly").tap()
        XCTAssertTrue(app.staticTexts["Newly saved works"].waitForExistence(timeout: 5))
        capture(app, "AI weekly activity")
    }

    func testTasteFeedRetentionPaginationAndEvidence() {
        let app = launch(extra: ["--taste-ui-rich"])
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Smart")).firstMatch.tap()
        let first = firstTasteCard(app)
        first.tap()
        XCTAssertTrue(element(app, "booru.media").waitForExistence(timeout: 10))
        XCTAssertFalse(element(app, "booru.pointerClose").exists)
        capture(app, "Image viewer with sheet-style dismiss handle")
        openMenu(app)
        let initialState = element(app, "booru.viewerState").label
        XCTAssertTrue(element(app, "booru.next").isEnabled)
        element(app, "booru.next").tap()
        let nextState = element(app, "booru.viewerState").label
        XCTAssertNotEqual(nextState, initialState)
        let mediaReady = expectation(for: NSPredicate(format: "label IN %@", ["ready", "playing", "ended"]), evaluatedWith: element(app, "booru.mediaStatus"))
        wait(for: [mediaReady], timeout: 15)
        XCUIDevice.shared.press(.home); app.activate()
        XCTAssertEqual(element(app, "booru.viewerState").label, nextState)
        XCTAssertTrue(element(app, "privacy.cover").waitForNonExistence(timeout: 3))
        let resumedMedia = expectation(for: NSPredicate(format: "label IN %@", ["ready", "playing", "ended"]), evaluatedWith: element(app, "booru.mediaStatus"))
        wait(for: [resumedMedia], timeout: 15)
        openMenu(app)
        element(app, "booru.previous").tap()
        XCTAssertEqual(element(app, "booru.viewerState").label, initialState)
        element(app, "booru.menuClose").tap()
        exitViewer(app)
        XCTAssertTrue(element(app, "booru.media").waitForNonExistence(timeout: 5))
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        let y = first.frame.minY
        app.tabBars.buttons["Explore"].tap()
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Smart")).firstMatch.tap()
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertEqual(first.frame.minY, y, accuracy: 10)
        XCTAssertFalse(app.buttons["Why this work?"].exists)
        element(app, "taste.evidence").tap()
        XCTAssertTrue(app.navigationBars["Recommendation evidence"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let next = reveal(app, "taste.work.221")
        XCTAssertTrue(next.waitForExistence(timeout: 10))
        capture(app, "AI infinite feed second page")
    }

    func testTasteMonthlyRecapBannerAndAnalysisExclusions() {
        let app = launch(extra: ["--taste-ui-rich", "--taste-recap-test"])
        XCTAssertTrue(element(app, "taste.recap.open").waitForExistence(timeout: 15))
        for tab in ["Saved", "Tags", "More", "Smart"] {
            app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", tab)).firstMatch.tap()
            XCTAssertTrue(element(app, "taste.recap.open").exists)
        }
        capture(app, "Monthly recap banner across tabs")
        element(app, "taste.recap.open").tap()
        XCTAssertTrue(element(app, "taste.monthly").waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["A month of discoveries"].exists)
        capture(app, "Monthly recap overview")
        app.buttons["Next card"].tap()
        XCTAssertTrue(app.staticTexts["The tags that defined your month"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Done"].isHittable)
        capture(app, "Monthly recap taste cards")
        element(app, "app.mode.hitomi").tap()
        XCTAssertTrue(app.staticTexts["A month of discoveries"].waitForExistence(timeout: 5))
        element(app, "app.mode.booru").tap()
        XCTAssertTrue(app.staticTexts["The tags that defined your month"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        XCTAssertFalse(element(app, "taste.recap.open").exists)
        app.navigationBars.buttons["Settings"].tap()
        element(app, "taste.settings.exclusions").tap()
        XCTAssertTrue(app.staticTexts["1girl"].exists)
        element(app, "taste.exclusions.mode").buttons["Comics"].tap()
        XCTAssertTrue(app.staticTexts["female:sole_female"].exists)
        XCTAssertTrue(app.staticTexts["tag:digital"].exists)
        capture(app, "Analysis exclusions by mode")
        let field = element(app, "taste.exclusions.input")
        field.tap(); field.typeText("tag: test")
        element(app, "taste.exclusions.add").tap()
        XCTAssertTrue(app.staticTexts["tag:test"].exists)
        app.terminate()
        let again = launch(extra: ["--taste-ui-rich", "--taste-recap-test"])
        XCTAssertTrue(element(again, "taste.recap.dismiss").waitForExistence(timeout: 10))
        element(again, "taste.recap.dismiss").tap()
        XCTAssertFalse(element(again, "taste.recap.open").exists)
        again.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "More")).firstMatch.tap()
        XCTAssertFalse(element(again, "taste.recap.open").exists)
    }

    func testLegacySoloExclusionFiltersActualSoleTagInComicRecommendations() {
        let app = launch(extra: ["--taste-ui-rich", "--taste-sole-exclusion-test"])
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Smart")).firstMatch.tap()
        element(app, "app.mode.hitomi").tap()
        let card = firstTasteCard(app), id = card.identifier
        element(app, "taste.evidence").tap()
        XCTAssertTrue(app.staticTexts["female:sample"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["female:sole female"].exists)
        XCTAssertFalse(app.staticTexts["male:sole male"].exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        element(app, id).tap()
        XCTAssertTrue(element(app, "content.read").waitForExistence(timeout: 5))
        let bar = app.navigationBars.firstMatch
        bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)))
        XCTAssertTrue(element(app, "content.read").waitForNonExistence(timeout: 5))
        XCTAssertTrue(element(app, id).isHittable)
        app.navigationBars.buttons["Settings"].tap()
        element(app, "taste.settings.exclusions").tap()
        XCTAssertTrue(app.staticTexts["female:sole_female"].exists)
        XCTAssertFalse(app.staticTexts["female:solo_female"].exists)
        capture(app, "Legacy exclusion spelling corrected to actual sole tag")
    }

    func testExclusionUpdatesRetainedRecommendationEvidenceImmediately() {
        let app = launch(extra: ["--taste-ui-rich"])
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Smart")).firstMatch.tap()
        let card = firstTasteCard(app), id = card.identifier
        let reason = card.staticTexts.matching(NSPredicate(format: "label IN %@", ["scenery", "mountain", "cloud", "river"])).firstMatch
        XCTAssertTrue(reason.exists)
        let tag = reason.label
        app.navigationBars.buttons["Settings"].tap()
        element(app, "taste.settings.exclusions").tap()
        let field = element(app, "taste.exclusions.input")
        field.tap(); field.typeText(tag)
        element(app, "taste.exclusions.add").tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let retained = element(app, id)
        XCTAssertTrue(retained.waitForExistence(timeout: 5))
        XCTAssertFalse(retained.staticTexts[tag].exists)
        element(app, "taste.evidence").tap()
        XCTAssertFalse(app.staticTexts[tag].exists)
        capture(app, "Excluded evidence removed without refreshing works")
    }

    func testTasteComicCardsAndModeRetention() {
        let app = launch(extra: ["--taste-ui-rich"])
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Smart")).firstMatch.tap()
        let image = firstTasteCard(app)
        let imageID = image.identifier
        image.press(forDuration: 0.7)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Saved"), object: image)], timeout: 5), .completed)
        XCTAssertEqual(element(app, "taste.saveStatus").label, "Saved to Favorites")
        image.press(forDuration: 0.7)
        XCTAssertEqual(element(app, "taste.saveStatus").label, "Favorite removed")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Not favorited"), object: image)], timeout: 5), .completed)
        app.swipeUp()
        let imageAnchor = firstTasteCard(app)
        let imageAnchorID = imageAnchor.identifier, imageY = imageAnchor.frame.minY
        element(app, "app.mode.booru").press(forDuration: 0.05, thenDragTo: element(app, "app.mode.hitomi"))
        let comic = firstTasteCard(app)
        XCTAssertTrue(comic.identifier.contains("900000"))
        comic.press(forDuration: 0.7)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Bookmarked"), object: comic)], timeout: 5), .completed)
        XCTAssertEqual(element(app, "taste.saveStatus").label, "Saved to bookmarks")
        comic.press(forDuration: 0.7)
        XCTAssertEqual(element(app, "taste.saveStatus").label, "Bookmark removed")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Not bookmarked"), object: comic)], timeout: 5), .completed)
        capture(app, "AI compact comic cards")
        comic.tap()
        XCTAssertTrue(element(app, "content.read").waitForExistence(timeout: 10))
        element(app, "content.read").tap()
        XCTAssertTrue(element(app, "reader.exitHandle").waitForExistence(timeout: 10))
        XCTAssertFalse(element(app, "reader.pointerClose").exists)
        capture(app, "Comic viewer with sheet-style dismiss handle")
        exitViewer(app)
        XCTAssertTrue(element(app, "reader.exitHandle").waitForNonExistence(timeout: 5))
        XCTAssertTrue(element(app, "content.read").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "content.read").isHittable)
        // A second open/close catches stale window gestures and double-dismissals.
        element(app, "content.read").tap()
        XCTAssertTrue(element(app, "reader.exitHandle").waitForExistence(timeout: 5))
        exitViewer(app)
        XCTAssertTrue(element(app, "reader.exitHandle").waitForNonExistence(timeout: 5))
        XCTAssertTrue(element(app, "content.read").isHittable)
        capture(app, "Comic details after reader return")
        element(app, "content.close").tap()
        app.swipeUp()
        let comicAnchor = firstTasteCard(app)
        let comicAnchorID = comicAnchor.identifier, comicY = comicAnchor.frame.minY
        element(app, "app.mode.hitomi").press(forDuration: 0.05, thenDragTo: element(app, "app.mode.booru"))
        XCTAssertTrue(element(app, imageAnchorID).waitForExistence(timeout: 5))
        XCTAssertEqual(element(app, imageAnchorID).frame.minY, imageY, accuracy: 10)
        XCTAssertTrue(element(app, imageID).exists)
        element(app, "app.mode.hitomi").tap()
        XCTAssertTrue(element(app, comicAnchorID).waitForExistence(timeout: 5))
        XCTAssertEqual(element(app, comicAnchorID).frame.minY, comicY, accuracy: 10)
        capture(app, "Comic feed retained after mode switch")
    }

    func testTasteKoreanLargeTextLayout() {
        let app = XCUIApplication()
        app.launchArguments = ["--booru-ui-test", "--taste-ui-rich", "-AppleLanguages", "(ko)", "-AppleLocale", "ko_KR", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "스마트 추천")).firstMatch.tap()
        XCTAssertTrue(element(app, "taste.highlight").waitForExistence(timeout: 10))
        capture(app, "AI Korean large text")
        let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "taste.work."))
        for _ in 0..<10 {
            if cards.allElementsBoundByIndex.contains(where: { $0.isHittable }) { break }
            app.swipeUp()
        }
        XCTAssertTrue(firstTasteCard(app).isHittable)
        capture(app, "AI accessible recommendation cards")
    }

    func testOrganizedSettingsAndOfflinePrivacyInBothModes() {
        let app = launch()
        app.tabBars.buttons["More"].tap()
        for mode in ["booru", "hitomi"] {
            if mode == "hitomi" { element(app, "app.mode.hitomi").tap() }
            XCTAssertTrue(element(app, "settings.gridColumns").waitForExistence(timeout: 5))
            capture(app, mode + " settings overview")
            reveal(app, mode == "booru" ? "booru.readerSettings" : "settings.reader").tap()
            XCTAssertTrue(element(app, "reader.settings.done").waitForExistence(timeout: 5))
            element(app, "reader.settings.done").tap()
            let remember = reveal(app, "settings.rememberHistory")
            XCTAssertTrue(remember.isEnabled)
            reveal(app, "settings.privacy").tap()
            XCTAssertTrue(element(app, "settings.privacyPolicy").waitForExistence(timeout: 5))
            XCTAssertFalse(app.staticTexts["Unable to load privacy policy."].exists)
            XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Number Memo Privacy Policy")).firstMatch.exists)
            capture(app, mode + " offline privacy policy")
            app.navigationBars.buttons.element(boundBy: 0).tap()
            let website = reveal(app, "developer.website")
            XCTAssertTrue(website.isEnabled)
            XCTAssertFalse(element(app, "developer.publisher").exists)
            capture(app, mode + " NextLine support links")
        }
    }

    func testPostReportAndHideControls() {
        let app = launch()
        let post = element(app, "booru.post.101")
        XCTAssertTrue(post.waitForExistence(timeout: 10)); post.tap()
        openMenu(app); element(app, "booru.info").tap()
        reveal(app, "booru.report").tap()
        XCTAssertTrue(element(app, "content.reportEmail").waitForExistence(timeout: 5))
        capture(app, "Report content without sending automatically")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        reveal(app, "booru.hidePost").tap()
        XCTAssertTrue(element(app, "booru.post.102").waitForExistence(timeout: 5))
        XCTAssertFalse(element(app, "booru.post.101").exists)
    }

    func testModeSwitchKeepsTabSearchAndLoadedPages() {
        let app = launch()
        let search = element(app, "booru.search")
        search.tap(); search.typeText("scenery mountain\n")
        element(app, "booru.more").tap()
        XCTAssertTrue(element(app, "booru.post.103").waitForExistence(timeout: 5))
        element(app, "app.mode.hitomi").tap()
        XCTAssertTrue(app.tabBars.buttons["Explore"].isSelected)
        XCTAssertTrue(element(app, "content.search").waitForExistence(timeout: 5))
        element(app, "app.mode.booru").tap()
        XCTAssertTrue(app.tabBars.buttons["Explore"].isSelected)
        XCTAssertEqual(search.value as? String, "scenery mountain")
        XCTAssertTrue(element(app, "booru.post.103").exists)
        app.tabBars.buttons["Tags"].tap(); element(app, "app.mode.hitomi").tap()
        XCTAssertTrue(app.tabBars.buttons["Artists"].isSelected)
        element(app, "app.mode.booru").tap()
        XCTAssertTrue(app.tabBars.buttons["Tags"].isSelected)
        capture(app, "Mode switch preserves corresponding tab")
    }

    func testHoldTogglesAndFolderMultiSelectionDeletes() {
        let app = launch()
        let card = element(app, "booru.post.101")
        XCTAssertTrue(card.waitForExistence(timeout: 8))
        card.press(forDuration: 0.8)
        XCTAssertTrue(element(app, "booru.favoriteBadge.101").waitForExistence(timeout: 4))
        card.press(forDuration: 0.8)
        XCTAssertFalse(element(app, "booru.favoriteBadge.101").exists)
        card.press(forDuration: 0.8)
        app.tabBars.buttons["Saved"].tap(); element(app, "booru.allFavorites").tap()
        element(app, "booru.select").tap(); element(app, "booru.post.101").tap()
        element(app, "booru.deleteSelected").tap()
        app.alerts.buttons["Delete"].tap()
        XCTAssertTrue(app.staticTexts["No Favorites"].waitForExistence(timeout: 5))
        capture(app, "Folder selection and deletion")
    }

    func testSavedMultiTagHistoryAndClearConfirmation() {
        let app = launch()
        let search = element(app, "booru.search")
        search.tap(); search.typeText("scenery mountain\n")
        app.tabBars.buttons["Tags"].tap()
        let star = element(app, "history.star.scenery mountain")
        XCTAssertTrue(star.waitForExistence(timeout: 5)); star.tap()
        XCTAssertTrue(app.staticTexts["Saved Searches"].exists)
        element(app, "history.clear").tap()
        XCTAssertTrue(app.alerts["Clear History?"].waitForExistence(timeout: 3))
        app.alerts.buttons["Cancel"].tap()
        XCTAssertTrue(star.exists)
        element(app, "history.clear").tap(); app.alerts.buttons["Clear History"].tap()
        XCTAssertFalse(star.exists)
        XCTAssertTrue(app.staticTexts["scenery mountain"].exists)
        capture(app, "Saved query keeps all tags after clearing history")
    }

    func testViewerHoldAutoplayAndCopyID() {
        let app = launch(extra: ["--booru-media-test"])
        element(app, "booru.post.105").tap()
        let status = element(app, "booru.mediaStatus")
        expectation(for: NSPredicate(format: "label == 'playing' OR label == 'ended'"), evaluatedWith: status)
        waitForExpectations(timeout: 12)
        openMenu(app); element(app, "booru.info").tap()
        XCTAssertTrue(element(app, "booru.copyID").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "booru.postID").label.contains("105"))
        capture(app, "Autoplay video details and copy ID")
    }

    func testICloudDisableWarningAndDeveloperEmail() {
        let app = launch()
        app.tabBars.buttons["More"].tap()
        let toggle = reveal(app, "settings.icloud")
        XCTAssertEqual(toggle.value as? String, "1")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertTrue(app.alerts["Turn Off iCloud Sync?"].waitForExistence(timeout: 5))
        app.alerts.buttons["Cancel"].tap(); XCTAssertEqual(toggle.value as? String, "1")
        XCTAssertTrue(reveal(app, "developer.email").exists)
        capture(app, "SVG developer identity and contact")
    }

    func testModesFavoritesServersAndNotesAreIsolated() {
        let app = launch()
        let card = element(app, "booru.post.101")
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        capture(app, "Booru Explore")
        card.press(forDuration: 0.7)
        XCTAssertEqual(card.value as? String, "Saved")
        XCTAssertFalse(app.buttons["Save to Folder"].exists)
        XCTAssertFalse(element(app, "booru.media").exists)
        card.press(forDuration: 0.7)
        XCTAssertEqual(card.value as? String, "Not favorited")
        XCTAssertEqual(element(app, "booru.saveStatus").label, "Favorite removed")
        card.press(forDuration: 0.7)
        XCTAssertEqual(element(app, "booru.saveStatus").label, "Saved to Favorites")
        card.tap()
        XCTAssertTrue(element(app, "booru.media").waitForExistence(timeout: 10))
        let note = app.webViews.buttons["Note 1"].firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 10)); note.tap()
        XCTAssertTrue(app.staticTexts["A mountain in the morning."].waitForExistence(timeout: 5))
        element(app, "booru.noteClose").tap()
        openMenu(app)
        XCTAssertEqual(element(app, "booru.favorite").label, "Remove Favorite")
        element(app, "booru.favorite").tap()
        XCTAssertEqual(element(app, "booru.favorite").label, "Add Favorite")
        element(app, "booru.favorite").tap()
        XCTAssertEqual(element(app, "booru.favorite").label, "Remove Favorite")
        element(app, "booru.info").tap()
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["A mountain in the morning."].waitForExistence(timeout: 10))
        capture(app, "Booru details and notes")
        app.buttons["Done"].tap()
        element(app, "booru.close").tap()
        XCTAssertEqual(card.value as? String, "Saved")
        app.tabBars.buttons["Saved"].tap()
        element(app, "booru.allFavorites").tap()
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        XCTAssertEqual(card.value as? String ?? "", "")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.tabBars.buttons["Explore"].tap()
        element(app, "booru.server").tap()
        app.buttons["Gelbooru"].tap()
        app.buttons["Danbooru"].tap()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).tap()
        app.tabBars.buttons["Saved"].tap()
        element(app, "booru.allFavorites").tap()
        XCTAssertTrue(card.waitForExistence(timeout: 5), "Saved works remain visible regardless of the selected exploration server")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        element(app, "app.mode.hitomi").tap()
        XCTAssertTrue(app.tabBars.buttons["Saved"].waitForExistence(timeout: 5))
        XCTAssertFalse(card.exists)
        capture(app, "Hitomi mode remains separate")
        element(app, "app.mode.booru").tap()
        app.tabBars.buttons["Saved"].tap()
        element(app, "booru.allFavorites").tap()
        XCTAssertTrue(card.waitForExistence(timeout: 5))
    }

    func testSearchSuggestionsScrollAndClearingDoesNotSubmit() {
        let app = launch(extra: ["--booru-long-suggestions"])
        let search = element(app, "booru.search")
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap(); search.typeText("sc")
        let first = element(app, "booru.suggestion.sc_00")
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        let panel = element(app, "search.suggestions")
        XCTAssertTrue(panel.exists)
        panel.swipeUp()
        let last = element(app, "booru.suggestion.sc_11")
        XCTAssertTrue(last.isHittable)
        capture(app, "Image search scrollable autocomplete")
        last.tap()
        app.buttons["Clear Search"].tap()
        search.typeText("empty\n")
        XCTAssertTrue(app.staticTexts["No Posts"].waitForExistence(timeout: 5))
        search.tap(); app.buttons["Clear Search"].tap()
        XCTAssertFalse(element(app, "booru.post.101").exists)
        search.typeText("\n")
        XCTAssertTrue(element(app, "booru.post.101").waitForExistence(timeout: 5))
    }

    func testAutocompleteHistoryPaginationAndPools() {
        let app = launch()
        XCTAssertTrue(element(app, "booru.post.101").waitForExistence(timeout: 10))
        let search = element(app, "booru.search")
        search.tap(); search.typeText("sc")
        let suggestion = element(app, "booru.suggestion.scenery")
        XCTAssertTrue(suggestion.waitForExistence(timeout: 5))
        suggestion.tap()
        XCTAssertEqual(search.value as? String, "scenery ")
        app.keyboards.buttons["Search"].tap()
        XCTAssertTrue(element(app, "booru.post.101").waitForExistence(timeout: 5))
        app.swipeUp()
        XCTAssertTrue(element(app, "booru.post.103").waitForExistence(timeout: 5))
        app.tabBars.buttons["Tags"].tap()
        app.swipeUp()
        XCTAssertTrue(element(app, "booru.savedHistory.scenery").waitForExistence(timeout: 5))
        app.tabBars.buttons["More"].tap()
        element(app, "booru.poolsLink").tap()
        let pool = element(app, "booru.pool.77")
        XCTAssertTrue(pool.waitForExistence(timeout: 5)); pool.tap()
        XCTAssertTrue(element(app, "booru.post.102").waitForExistence(timeout: 5))
        capture(app, "Booru ordered pool")
    }

    func testBlacklistAndCustomServerValidation() {
        let app = launch()
        XCTAssertTrue(element(app, "booru.post.101").waitForExistence(timeout: 10))
        app.tabBars.buttons["More"].tap()
        app.swipeUp()
        reveal(app, "booru.blacklist").tap()
        let rules = element(app, "booru.blacklistText")
        XCTAssertTrue(rules.waitForExistence(timeout: 5)); rules.tap(); rules.typeText("scenery")
        element(app, "booru.blacklistSave").tap()
        app.tabBars.buttons["Explore"].tap()
        XCTAssertTrue(element(app, "booru.post.102").waitForExistence(timeout: 5))
        XCTAssertFalse(element(app, "booru.post.101").exists)
        app.tabBars.buttons["More"].tap()
        for _ in 0..<6 where !element(app, "booru.serversLink").isHittable { app.swipeDown() }
        element(app, "booru.serversLink").tap()
        element(app, "booru.addServer").tap()
        element(app, "booru.serverOptions").tap()
        element(app, "booru.serverName").tap(); element(app, "booru.serverName").typeText("My Booru")
        element(app, "booru.serverURL").tap(); element(app, "booru.serverURL").typeText("https://example.com")
        element(app, "booru.serverEngine").tap(); app.buttons["Danbooru"].tap()
        element(app, "booru.serverSave").tap()
        XCTAssertTrue(app.staticTexts["My Booru"].waitForExistence(timeout: 5))
        capture(app, "Custom server configured")
        app.tabBars.buttons["Explore"].tap()
        XCTAssertTrue(element(app, "booru.post.101").waitForExistence(timeout: 5))
    }

    func testNetworkErrorCanBeRetried() {
        let app = launch(extra: ["--booru-initial-error"])
        let retry = element(app, "content.retry")
        XCTAssertTrue(retry.waitForExistence(timeout: 10)); retry.tap()
        XCTAssertTrue(element(app, "booru.post.101").waitForExistence(timeout: 10))
    }

    func testViewerContinuesAcrossPagesAndResumesCurrentPost() {
        let app = launch()
        let first = element(app, "booru.post.101")
        XCTAssertTrue(first.waitForExistence(timeout: 10)); first.tap()
        openMenu(app)
        let next = element(app, "booru.next")
        next.tap()
        let state = element(app, "booru.viewerState")
        expectation(for: NSPredicate(format: "label == '102:fit'"), evaluatedWith: state)
        waitForExpectations(timeout: 10)
        next.tap()
        expectation(for: NSPredicate(format: "label == '103:fit'"), evaluatedWith: state)
        waitForExpectations(timeout: 10)
        XCUIDevice.shared.press(.home)
        app.activate()
        expectation(for: NSPredicate(format: "label == '103:fit'"), evaluatedWith: state)
        waitForExpectations(timeout: 10)
        capture(app, "Viewer resumes paginated current image")
        openMenu(app)
        element(app, "booru.previous").tap()
        expectation(for: NSPredicate(format: "label == '102:fit'"), evaluatedWith: state)
        waitForExpectations(timeout: 10)
        element(app, "booru.close").tap()
        XCTAssertTrue(first.waitForExistence(timeout: 5))
    }

    func testAnimatedGIFAndVideoLoadOnDevice() {
        let app = launch(extra: ["--booru-media-test"])
        let gif = element(app, "booru.post.104")
        XCTAssertTrue(gif.waitForExistence(timeout: 10)); gif.tap()
        let status = element(app, "booru.mediaStatus")
        expectation(for: NSPredicate(format: "label == 'ready'"), evaluatedWith: status)
        waitForExpectations(timeout: 15)
        capture(app, "Animated GIF loaded")
        openMenu(app)
        element(app, "booru.close").tap()
        element(app, "booru.post.105").tap()
        expectation(for: NSPredicate(format: "label == 'playing' OR label == 'ended'"), evaluatedWith: status)
        waitForExpectations(timeout: 15)
        capture(app, "MP4 playback verified")
        XCUIDevice.shared.press(.home); app.activate()
        expectation(for: NSPredicate(format: "label == 'playing' OR label == 'ended'"), evaluatedWith: status)
        waitForExpectations(timeout: 15)
        let playback = app.buttons.matching(NSPredicate(format: "label IN %@", ["Play", "재생", "Pause", "일시 정지"])).firstMatch
        XCTAssertTrue(playback.waitForExistence(timeout: 5))
        playback.twoFingerTap()
        XCTAssertTrue(element(app, "booru.close").waitForExistence(timeout: 5))
        element(app, "booru.close").tap()
        XCTAssertTrue(gif.waitForExistence(timeout: 5))
    }

    func testViewerGesturesAndIndependentSettings() {
        let app = launch()
        let first = element(app, "booru.post.101")
        XCTAssertTrue(first.waitForExistence(timeout: 10)); first.tap()
        let media = element(app, "booru.media")
        let state = element(app, "booru.viewerState")
        XCTAssertTrue(state.waitForExistence(timeout: 10))
        media.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.6)).tap()
        expectation(for: NSPredicate(format: "label == '102:fit'"), evaluatedWith: state); waitForExpectations(timeout: 5)
        media.swipeRight()
        expectation(for: NSPredicate(format: "label == '101:fit'"), evaluatedWith: state); waitForExpectations(timeout: 5)
        media.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).press(forDuration: 0.7)
        openMenu(app)
        XCTAssertEqual(element(app, "booru.favorite").label, "Remove Favorite")
        element(app, "booru.menuClose").tap()
        media.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).doubleTap()
        expectation(for: NSPredicate(format: "label == '101:zoomed'"), evaluatedWith: state); waitForExpectations(timeout: 5)
        media.swipeDown()
        XCTAssertTrue(state.exists)
        media.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.8)).doubleTap()
        expectation(for: NSPredicate(format: "label == '101:fit'"), evaluatedWith: state); waitForExpectations(timeout: 5)
        openMenu(app)
        capture(app, "Unified Booru reader menu")
        element(app, "booru.readerSettings").tap()
        let rtl = element(app, "reader.settings.rtl")
        rtl.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertEqual(rtl.value as? String, "1")
        element(app, "reader.settings.done").tap()
        element(app, "booru.menuClose").tap()
        media.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.6)).tap()
        expectation(for: NSPredicate(format: "label == '102:fit'"), evaluatedWith: state); waitForExpectations(timeout: 5)
        media.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.45)).press(forDuration: 0.05, thenDragTo: media.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.85)))
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: state); waitForExpectations(timeout: 5)
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        element(app, "app.mode.hitomi").tap()
        app.tabBars.buttons["Settings"].tap()
        app.swipeUp()
        app.buttons["Reader Settings"].tap()
        XCTAssertEqual(element(app, "reader.settings.rtl").value as? String, "0")
    }

    func testKoreanRootHeaders() {
        let app = XCUIApplication()
        app.launchArguments = ["--booru-ui-test", "-AppleLanguages", "(ko)", "-AppleLocale", "ko_KR"]
        app.launch()
        app.tabBars.buttons.element(boundBy: 1).tap()
        XCTAssertTrue(element(app, "booru.post.101").waitForExistence(timeout: 10))
        for index in 0..<4 {
            app.tabBars.buttons.element(boundBy: index).tap()
            let mode = element(app, "app.mode")
            XCTAssertTrue(mode.exists)
            XCTAssertLessThan(mode.frame.maxY, 130)
            XCTAssertEqual(mode.frame.height, 44, accuracy: 2)
            capture(app, "Korean Booru tab \(index)")
        }
        element(app, "app.mode.hitomi").tap()
        for index in 0..<4 {
            app.tabBars.buttons.element(boundBy: index).tap()
            let mode = element(app, "app.mode")
            XCTAssertTrue(mode.exists)
            XCTAssertLessThan(mode.frame.maxY, 130)
            XCTAssertEqual(mode.frame.height, 44, accuracy: 2)
            capture(app, "Korean Hitomi tab \(index)")
        }
    }

    func testMoreValidationAndCookieSettings() {
        let app = launch()
        XCTAssertTrue(element(app, "booru.post.101").waitForExistence(timeout: 10))
        app.tabBars.buttons["More"].tap()
        let servers = element(app, "booru.serversLink"), pools = element(app, "booru.poolsLink"), columns = element(app, "settings.gridColumns")
        XCTAssertLessThan(servers.frame.minY, pools.frame.minY)
        XCTAssertTrue(columns.isHittable, "More must expose settings without another navigation step")
        XCTAssertLessThan(pools.frame.minY, columns.frame.minY)
        XCTAssertFalse(element(app, "booru.settingsLink").exists)
        capture(app, "Booru More with inline settings")
        app.swipeUp()
        reveal(app, "booru.validate").tap()
        XCTAssertTrue(app.webViews.staticTexts["Validation browser is ready."].waitForExistence(timeout: 10))
        capture(app, "Validate Client")
        element(app, "booru.validationDone").tap()
        element(app, "booru.cookies").tap()
        XCTAssertTrue(app.staticTexts["No Cookies"].waitForExistence(timeout: 5))
        element(app, "booru.resetCookies").tap()
        app.sheets.buttons["Reset Cookies"].tap()
        XCTAssertTrue(app.staticTexts["No Cookies"].exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(reveal(app, "developer.website").isHittable)
        XCTAssertTrue(element(app, "developer.logo").exists)
        XCTAssertTrue(reveal(app, "developer.community").isHittable)
        capture(app, "Booru developer and community")
        element(app, "app.mode.hitomi").tap()
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(reveal(app, "developer.website").isHittable)
        XCTAssertTrue(element(app, "developer.logo").exists)
        XCTAssertTrue(reveal(app, "developer.community").isHittable)
        capture(app, "Hitomi developer and community")
    }

    func testMultiServerExploreAndFolderFavorites() {
        let app = launch(extra: ["--booru-multi-test"])
        XCTAssertTrue(element(app, "booru.post.101").waitForExistence(timeout: 10))
        element(app, "booru.server").tap(); app.buttons["Gelbooru"].tap()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).tap()
        XCTAssertTrue(element(app, "booru.post.1101").waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, "booru.post.101").exists)
        capture(app, "Multi-server Explore")
        app.tabBars.buttons["Saved"].tap()
        element(app, "booru.createFolder").tap()
        let alert = element(app, "folder.namePrompt")
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        let name = alert.textFields.firstMatch
        capture(app, "Booru folder name before entry")
        XCTAssertEqual(name.frame.midX, alert.frame.midX, accuracy: 3, "Folder input should be centered within the alert")
        XCTAssertTrue(name.exists); name.tap(); name.typeText("Landscapes")
        capture(app, "Booru folder name after entry")
        alert.buttons["Create"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Landscapes, 0 items"].exists || app.staticTexts["Landscapes"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Explore"].tap()
        element(app, "booru.post.1101").tap(); openMenu(app)
        element(app, "booru.folder").tap()
        app.buttons["Create Folder"].tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertEqual(name.frame.midX, alert.frame.midX, accuracy: 3)
        name.typeText("Discarded from picker")
        alert.buttons["Cancel"].firstMatch.tap()
        app.buttons.containing(.staticText, identifier: "Landscapes").firstMatch.tap()
        element(app, "booru.close").tap()
        element(app, "booru.post.1101").press(forDuration: 0.7)
        app.tabBars.buttons["Saved"].tap()
        capture(app, "Booru folder library")
        app.buttons.containing(.staticText, identifier: "Landscapes").firstMatch.tap()
        XCTAssertTrue(element(app, "booru.post.1101").waitForExistence(timeout: 5))
        element(app, "booru.server").tap(); app.buttons["Gelbooru"].tap()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).tap()
        XCTAssertTrue(app.staticTexts["No Favorites"].waitForExistence(timeout: 5))
    }

    func testFolderNamePromptsAlignAndResetAcrossModes() {
        let app = launch()
        element(app, "app.mode.hitomi").tap()
        app.tabBars.buttons["Settings"].tap()
        element(app, "settings.onboarding").tap()
        XCTAssertTrue(element(app, "onboarding.addServer").waitForExistence(timeout: 10))
        element(app, "onboarding.continue").tap()
        XCTAssertTrue(element(app, "onboarding.violetImport").waitForExistence(timeout: 5))
        element(app, "onboarding.continue").tap()
        XCTAssertTrue(element(app, "onboarding.tutorial").waitForExistence(timeout: 5))
        element(app, "onboarding.continue").tap()
        XCTAssertTrue(app.tabBars.buttons["Saved"].waitForExistence(timeout: 5))

        for (mode, button) in [("booru", "booru.createFolder"), ("hitomi", "hitomi.createFolder")] {
            element(app, "app.mode." + mode).tap()
            app.tabBars.buttons["Saved"].tap()
            let createFolder = element(app, button)
            XCTAssertTrue(createFolder.waitForExistence(timeout: 5)); createFolder.tap()
            let alert = element(app, "folder.namePrompt")
            XCTAssertTrue(alert.waitForExistence(timeout: 5))
            let name = alert.textFields.firstMatch
            XCTAssertEqual(name.frame.midX, alert.frame.midX, accuracy: 3)
            XCTAssertFalse(alert.buttons["Create"].firstMatch.isEnabled)
            name.typeText("Discarded")
            alert.buttons["Cancel"].firstMatch.tap()
            createFolder.tap()
            XCTAssertTrue(alert.waitForExistence(timeout: 5))
            XCTAssertFalse(alert.buttons["Create"].firstMatch.isEnabled)
            XCTAssertFalse((name.value as? String ?? "").contains("Discarded"))
            name.typeText(mode + " Collection")
            capture(app, mode + " aligned folder name prompt")
            alert.buttons["Create"].firstMatch.tap()
            XCTAssertTrue(app.staticTexts[mode + " Collection"].waitForExistence(timeout: 5))
        }
    }

    func testImportedFavoritesRemainMarkedWhenReturningToExplore() {
        let app = launch(extra: ["--booru-import-test", "--booru-import-badge-test"])
        XCTAssertTrue(element(app, "booru.post.201").waitForExistence(timeout: 10))
        app.tabBars.buttons["More"].tap()
        reveal(app, "booru.libraryManagement").tap()
        reveal(app, "booru.importLink").tap()
        reveal(app, "booru.import.confirm").tap()
        XCTAssertTrue(element(app, "booru.import.result").waitForExistence(timeout: 10))
        app.tabBars.buttons["Explore"].tap()
        let cards = app.descendants(matching: .any).matching(identifier: "booru.post.201")
        expectation(for: NSPredicate(format: "count == 2"), evaluatedWith: cards)
        waitForExpectations(timeout: 10)
        for card in cards.allElementsBoundByIndex { XCTAssertEqual(card.value as? String, "Saved") }
        capture(app, "Imported favorite badges in Explore")
    }

    func testRestoredImportedFavoriteBadgesAfterAppRelaunch() {
        let app = launch(extra: ["--booru-restored-badge-test", "--booru-badge-seed"])
        for pass in 0..<2 {
            let cards = app.descendants(matching: .any).matching(identifier: "booru.post.5194309")
            expectation(for: NSPredicate(format: "count == 2"), evaluatedWith: cards)
            waitForExpectations(timeout: 10)
            for card in cards.allElementsBoundByIndex { XCTAssertEqual(card.value as? String, "Saved") }
            capture(app, "Restored 5194309 badges pass \(pass)")
            if pass == 0 {
                app.terminate()
                app.launchArguments.removeAll { $0 == "--booru-badge-seed" }
                app.launch()
                app.tabBars.buttons["Explore"].tap()
            }
        }
        let card = element(app, "booru.post.5194309")
        card.press(forDuration: 0.8)
        XCTAssertEqual(card.value as? String, "Not favorited")
        card.press(forDuration: 0.8)
        XCTAssertEqual(card.value as? String, "Saved")
    }

    func testBothModesCanRenameFolders() {
        let app = launch(extra: ["--folder-edit-test"])
        app.tabBars.buttons["Saved"].tap()
        for mode in ["booru", "hitomi"] {
            if mode == "hitomi" { element(app, "app.mode.hitomi").tap() }
            element(app, mode + ".createFolder").tap()
            let input = element(app, mode == "booru" ? "booru.folderName" : "folder.name")
            XCTAssertTrue(input.waitForExistence(timeout: 5)); input.tap(); input.typeText("Before Rename")
            app.buttons["Create"].tap()
            let folder = app.staticTexts["Before Rename"].firstMatch
            XCTAssertTrue(folder.waitForExistence(timeout: 5)); folder.press(forDuration: 0.8)
            app.buttons["Rename Folder"].tap()
            let rename = element(app, "folder.rename")
            XCTAssertTrue(rename.waitForExistence(timeout: 5)); rename.tap()
            rename.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "Before Rename".count) + "Renamed Folder")
            app.buttons["Save"].tap()
            XCTAssertTrue(app.staticTexts["Renamed Folder"].firstMatch.waitForExistence(timeout: 5))
            capture(app, mode + " renamed folder")
        }
    }

    func testAnimeBoxesImportPreviewAndFolders() {
        let app = launch(extra: ["--booru-import-test"])
        XCTAssertTrue(element(app, "booru.post.101").waitForExistence(timeout: 10))
        app.tabBars.buttons["More"].tap()
        for _ in 0..<4 where !element(app, "booru.libraryManagement").isHittable { app.swipeUp() }
        reveal(app, "booru.libraryManagement").tap()
        reveal(app, "booru.importLink").tap()
        XCTAssertTrue(app.staticTexts["Backup Contents"].waitForExistence(timeout: 5))
        capture(app, "Anime Boxes import preview")
        for _ in 0..<3 where !element(app, "booru.import.confirm").isHittable { app.swipeUp() }
        element(app, "booru.import.confirm").tap()
        XCTAssertTrue(element(app, "booru.import.result").waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, "booru.import.result").label.contains("2 favorites added"))
        app.tabBars.buttons["Saved"].tap()
        element(app, "booru.folder.anime-boxes").tap()
        XCTAssertEqual(app.buttons.matching(identifier: "booru.post.201").count, 2)
        capture(app, "Imported favorites in Anime Boxes folder")
    }

    func testHitomiDefaultTagsAndGridSettingsStayInTheirMode() {
        let app = launch()
        XCTAssertTrue(element(app, "booru.post.101").waitForExistence(timeout: 10))
        app.tabBars.buttons["More"].tap()
        XCTAssertTrue(element(app, "settings.gridColumns").buttons["3"].isSelected)
        element(app, "settings.gridColumns").buttons["4"].tap()
        element(app, "app.mode.hitomi").tap()
        app.tabBars.buttons["Settings"].tap()
        for _ in 0..<4 {
            if element(app, "hitomi.defaultTagsSettings").exists && element(app, "hitomi.defaultTagsSettings").isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(element(app, "settings.gridColumns").buttons["2"].isSelected)
        element(app, "hitomi.defaultTagsSettings").tap()
        let included = element(app, "hitomi.defaultTags"), excluded = element(app, "hitomi.defaultExcludedTags")
        XCTAssertTrue(included.waitForExistence(timeout: 5)); included.tap(); included.typeText("tag:scenery")
        excluded.tap(); excluded.typeText("tag:spoilers")
        capture(app, "Hitomi default search tags")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        element(app, "app.mode.booru").tap()
        app.tabBars.buttons["More"].tap()
        XCTAssertTrue(element(app, "settings.gridColumns").buttons["4"].isSelected)
    }

    func testBooruUsesAppleImageTranslation() {
        let app = launch()
        let card = element(app, "booru.post.101")
        XCTAssertTrue(card.waitForExistence(timeout: 10)); card.tap()
        openMenu(app); element(app, "booru.translate").tap()
        XCTAssertTrue(element(app, "reader.original").waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, "reader.translation.canvas").waitForExistence(timeout: 30))
        let canvas = element(app, "reader.translation.canvas")
        XCTAssertGreaterThan(canvas.frame.height, app.frame.height * 0.8)
        XCTAssertGreaterThan(canvas.frame.width, app.frame.width * 0.9)
        capture(app, "Booru Apple image translation")
        element(app, "reader.original").tap()
        XCTAssertTrue(element(app, "booru.media").waitForExistence(timeout: 5))
    }

    func testManualOnboardingImportsAndSwitchTutorial() {
        let app = launch(extra: ["--onboarding-test", "--booru-import-test"])
        XCTAssertTrue(element(app, "onboarding.addServer").waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["danbooru.donmai.us"].exists)
        XCTAssertFalse(app.staticTexts["Safebooru"].exists)
        XCTAssertFalse(app.buttons["Validate Client Danbooru"].exists)
        capture(app, "Unified onboarding addresses")
        element(app, "onboarding.continue").tap()
        XCTAssertTrue(element(app, "onboarding.violetImport").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "onboarding.import").exists)
        capture(app, "Unified onboarding both imports")
        element(app, "onboarding.import").tap()
        XCTAssertTrue(app.staticTexts["Backup Contents"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        element(app, "onboarding.continue").tap()
        XCTAssertTrue(element(app, "onboarding.tutorial").waitForExistence(timeout: 5))
        element(app, "app.mode.hitomi").tap()
        XCTAssertTrue(app.staticTexts["Comics Mode"].waitForExistence(timeout: 5))
        element(app, "app.mode.booru").tap()
        capture(app, "Unified onboarding switch tutorial")
        element(app, "app.mode.hitomi").tap()
        element(app, "onboarding.continue").tap()
        XCTAssertTrue(app.tabBars.buttons["More"].waitForExistence(timeout: 5))
        XCTAssertFalse(element(app, "comics.enterAddress").exists)
        element(app, "app.mode.hitomi").tap()
        XCTAssertTrue(element(app, "comics.enterAddress").waitForExistence(timeout: 5))
        capture(app, "Comics requires explicit website setup")
        element(app, "app.mode.booru").tap()
        XCTAssertTrue(app.tabBars.buttons["More"].waitForExistence(timeout: 5))
    }

    func testKoreanComicsPoolConnectionCardAndSavedTab() {
        let app = XCUIApplication()
        app.launchArguments = ["--booru-ui-test", "--comics-setup-test", "-AppleLanguages", "(ko)", "-AppleLocale", "ko_KR"]
        app.launch()
        app.tabBars.buttons["탐색"].tap()
        element(app, "app.mode.hitomi").tap()
        XCTAssertTrue(element(app, "booru.pool.77").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "comics.enterAddress").isHittable)
        XCTAssertTrue(element(app, "comics.importViolet").isHittable)
        capture(app, "Korean comics pool setup")
        app.tabBars.buttons["저장"].tap()
        XCTAssertTrue(element(app, "comics.connectionCard").waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["콘텐츠를 표시할 수 없습니다"].exists)
        XCTAssertTrue(element(app, "hitomi.createFolder").isEnabled)
        capture(app, "Korean disconnected comics library")
        element(app, "comics.importViolet").tap()
        XCTAssertTrue(app.buttons["완료"].waitForExistence(timeout: 5))
        capture(app, "Korean Violet import sheet")
    }

    func testDisconnectedComicsCanUseLocalFoldersBeforeConnectingReader() {
        let app = launch(extra: ["--comics-setup-test", "--no-sites-test", "--comics-local-library-test"])
        element(app, "app.mode.hitomi").tap()
        app.tabBars.buttons["Saved"].tap()
        XCTAssertTrue(element(app, "hitomi.createFolder").isEnabled)
        let folder = app.staticTexts["Offline library"]
        XCTAssertTrue(folder.waitForExistence(timeout: 5)); folder.tap()
        let work = element(app, "works.card.900000001")
        XCTAssertTrue(work.waitForExistence(timeout: 5)); work.tap()
        XCTAssertTrue(element(app, "comics.enterAddress").waitForExistence(timeout: 5))
        XCTAssertFalse(element(app, "reader.canvas").exists)
        element(app, "content.close").tap()
        XCTAssertTrue(work.waitForExistence(timeout: 5))
    }

    func testDisconnectedComicsKeepsTabsAndOffersVioletImport() {
        let app = launch(extra: ["--comics-setup-test", "--no-sites-test"])
        element(app, "app.mode.hitomi").tap()
        XCTAssertTrue(element(app, "comics.enterAddress").waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["Explore"].isSelected)
        element(app, "comics.importViolet").tap()
        XCTAssertTrue(app.buttons["Import user.db (Bookmarks, Folders, Artists)"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Backup & Restore"].exists)
        capture(app, "Violet import from disconnected comics")
        app.tabBars.buttons["Artists"].tap()
        XCTAssertTrue(app.tabBars.buttons["Artists"].isSelected)
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(element(app, "settings.connection").waitForExistence(timeout: 5))
    }

    func testComicsShowsImagePoolsUntilComicsWebsiteIsConnected() {
        let app = launch(extra: ["--comics-setup-test"])
        element(app, "app.mode.hitomi").tap()
        XCTAssertTrue(element(app, "comics.connectionCard").waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["Explore"].isSelected)
        let pool = element(app, "booru.pool.77")
        XCTAssertTrue(pool.waitForExistence(timeout: 10))
        XCTAssertFalse(element(app, "booru.pool.78").exists)
        capture(app, "Comics mode image pools and connection card")
        pool.tap()
        let post = element(app, "booru.post.101")
        XCTAssertTrue(post.waitForExistence(timeout: 5)); post.tap()
        XCTAssertTrue(element(app, "booru.media").waitForExistence(timeout: 5))
        openMenu(app); element(app, "booru.close").tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        element(app, "comics.enterAddress").tap()
        let input = element(app, "comics.address")
        input.tap(); input.typeText("hitomi.la")
        element(app, "comics.connect").tap()
        XCTAssertTrue(element(app, "content.search").waitForExistence(timeout: 5))
        XCTAssertFalse(element(app, "comics.connectionCard").exists)
        XCTAssertTrue(app.tabBars.buttons["Explore"].isSelected)
    }

    func testComicsConnectionGateAndInvalidAddress() {
        let app = launch(extra: ["--comics-setup-test"])
        element(app, "app.mode.hitomi").tap()
        XCTAssertTrue(element(app, "comics.enterAddress").waitForExistence(timeout: 5))
        element(app, "comics.enterAddress").tap()
        let input = element(app, "comics.address")
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap(); input.typeText("example.com")
        element(app, "comics.connect").tap()
        XCTAssertTrue(app.alerts["Invalid Address"].waitForExistence(timeout: 5))
        app.alerts.buttons["OK"].tap()
        input.tap()
        input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "example.com".count) + "hitomi.la")
        element(app, "comics.connect").tap()
        XCTAssertTrue(app.tabBars.buttons["Explore"].waitForExistence(timeout: 5))
        XCTAssertFalse(element(app, "comics.enterAddress").exists)
        element(app, "app.mode.booru").tap()
        XCTAssertTrue(app.tabBars.buttons["Explore"].isSelected)
        element(app, "app.mode.hitomi").tap()
        XCTAssertTrue(app.tabBars.buttons["Explore"].isSelected)
    }

    func testOnboardingAddsManualOldGelbooruAddress() {
        let app = launch(extra: ["--onboarding-test"])
        element(app, "onboarding.addServer").tap()
        let address = element(app, "booru.serverURL")
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        address.tap(); address.typeText("https://sample.booru.org")
        XCTAssertTrue(app.staticTexts["Old Gelbooru (v0.1.11)"].exists)
        element(app, "booru.serverSave").tap()
        XCTAssertTrue(app.staticTexts["sample.booru.org"].waitForExistence(timeout: 5))
        element(app, "onboarding.continue").tap()
        XCTAssertTrue(element(app, "onboarding.violetImport").waitForExistence(timeout: 5))
    }

    func testOnboardingConnectsComicsWithoutAddingAnImageServer() {
        let app = launch(extra: ["--onboarding-test", "-AppleLanguages", "(ko)", "-AppleLocale", "ko_KR"])
        capture(app, "Concise onboarding setup")
        element(app, "onboarding.addServer").tap()
        let address = element(app, "booru.serverURL")
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        address.tap(); address.typeText("https://hitomi.la/")
        XCTAssertTrue(app.staticTexts["만화 모드"].exists)
        XCTAssertFalse(element(app, "booru.serverEngine").exists)
        capture(app, "Comics address in initial connection")
        element(app, "booru.serverSave").tap()
        XCTAssertTrue(element(app, "onboarding.comicsConnected").waitForExistence(timeout: 5))
        element(app, "onboarding.continue").tap()
        capture(app, "Concise onboarding imports")
        element(app, "onboarding.continue").tap()
        capture(app, "Concise onboarding mode tutorial")
        element(app, "onboarding.continue").tap()
        XCTAssertTrue(element(app, "booru.setupAddress").waitForExistence(timeout: 5))
        element(app, "app.mode.hitomi").tap()
        XCTAssertTrue(app.tabBars.buttons["설정"].waitForExistence(timeout: 5))
        XCTAssertFalse(element(app, "comics.enterAddress").exists)
    }

    func testEmptyLibraryCanConnectWithOnlyAnAddress() {
        let app = launch(extra: ["--onboarding-test"])
        element(app, "onboarding.continue").tap()
        element(app, "onboarding.continue").tap()
        element(app, "onboarding.continue").tap()
        XCTAssertTrue(element(app, "booru.setupAddress").waitForExistence(timeout: 5))
        capture(app, "No default sites - useful empty library")
        app.tabBars.buttons["Explore"].tap()
        XCTAssertFalse(app.staticTexts["No Posts"].exists)
        element(app, "booru.setupAddress").tap()
        let address = element(app, "booru.serverURL")
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        XCTAssertFalse(element(app, "booru.serverSave").isEnabled)
        address.tap(); address.typeText("safebooru.org")
        XCTAssertTrue(app.staticTexts["Gelbooru"].exists)
        capture(app, "Address only server setup")
        element(app, "booru.serverSave").tap()
        XCTAssertTrue(app.tabBars.buttons["Explore"].isSelected)
        XCTAssertFalse(element(app, "booru.setupAddress").exists)
        XCTAssertTrue(element(app, "booru.post.101").waitForExistence(timeout: 10))
    }

    func testModeSwitchSlidesBetweenLibraries() {
        let app = launch()
        let mode = element(app, "app.mode")
        mode.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5)).press(forDuration: 0.05,
            thenDragTo: mode.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)))
        XCTAssertTrue(app.tabBars.buttons["Settings"].waitForExistence(timeout: 5))
        mode.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)).press(forDuration: 0.05,
            thenDragTo: mode.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5)))
        XCTAssertTrue(app.tabBars.buttons["More"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.tabBars.buttons.element(boundBy: 0).label, "Saved")
    }

    func testRatingAndBrowserFallbackSettings() {
        let app = launch()
        element(app, "booru.rating").tap(); app.buttons["General / Safe"].tap()
        XCTAssertTrue(element(app, "booru.rating").label.contains("General / Safe"))
        element(app, "booru.rating").tap(); app.buttons["All Ratings"].tap()
        capture(app, "Booru shared search and rating controls")
        app.tabBars.buttons["More"].tap()
        let browserToggle = reveal(app, "booru.browserToggle")
        browserToggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertEqual(browserToggle.value as? String, "1")
        app.tabBars.buttons["Explore"].tap()
        XCTAssertTrue(element(app, "booru.nativeGrid").waitForExistence(timeout: 10))
        XCTAssertTrue(app.webViews.staticTexts["Validation browser is ready."].waitForExistence(timeout: 10))
        capture(app, "Booru embedded browser fallback")
        app.tabBars.buttons["Saved"].tap(); app.tabBars.buttons["Explore"].tap()
        XCTAssertTrue(app.webViews.staticTexts["Validation browser is ready."].waitForExistence(timeout: 10))
        element(app, "booru.nativeGrid").tap()
        XCTAssertTrue(element(app, "booru.post.101").waitForExistence(timeout: 5))
    }

    func testLiveLegacyGalleryWithRatingDisabled() throws {
        guard ProcessInfo.processInfo.environment["NUMBER_MEMO_BOORU_LIVE_TESTS"] == "1",
              let address = ProcessInfo.processInfo.environment["NUMBER_MEMO_LEGACY_SERVERS"]?.split(separator: ",").first,
              address.hasPrefix("https://") else { throw XCTSkip("Opt-in legacy server required") }
        let app = XCUIApplication()
        app.launchArguments = ["--booru-live-ui-test", "--booru-legacy-address", String(address), "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch(); app.tabBars.buttons["More"].tap()
        reveal(app, "booru.validate").tap()
        XCTAssertTrue(element(app, "booru.validationWeb").waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 8)
        element(app, "booru.validationDone").tap(); app.tabBars.buttons["Explore"].tap()
        XCTAssertTrue(element(app, "booru.rating").label.contains("All Ratings"))
        let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'booru.post.'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 40), "Legacy public gallery should load without a rating condition")
        card.tap()
        expectation(for: NSPredicate(format: "label == 'ready'"), evaluatedWith: element(app, "booru.mediaStatus"))
        waitForExpectations(timeout: 35)
    }

    func testLiveGelbooruPublicGalleryAfterValidation() throws {
        guard ProcessInfo.processInfo.environment["NUMBER_MEMO_BOORU_LIVE_TESTS"] == "1" else { throw XCTSkip("Opt-in network UI test") }
        let app = XCUIApplication()
        app.launchArguments = ["--booru-live-ui-test", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch(); app.tabBars.buttons["Explore"].tap()
        element(app, "booru.server").tap(); app.buttons["Gelbooru"].tap(); app.buttons["Safebooru"].tap()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).tap()
        let search = element(app, "booru.search")
        search.tap(); search.typeText("landscape rating:general"); app.keyboards.buttons["Search"].tap()
        app.tabBars.buttons["More"].tap()
        reveal(app, "booru.validate").tap()
        XCTAssertTrue(element(app, "booru.validationWeb").waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 8)
        XCTAssertFalse(app.staticTexts["Unable to Load"].exists, "The visible validation page itself must connect")
        element(app, "booru.validationDone").tap(); app.tabBars.buttons["Explore"].tap()
        let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'booru.post.'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 40), "Public Gelbooru gallery must load without an API key")
        card.tap()
        expectation(for: NSPredicate(format: "label == 'ready'"), evaluatedWith: element(app, "booru.mediaStatus"))
        waitForExpectations(timeout: 35)
        capture(app, "Gelbooru live landscape viewer")
    }

    func testLiveReportedGelbooruPostAfterValidation() throws {
        guard ProcessInfo.processInfo.environment["NUMBER_MEMO_BOORU_LIVE_TESTS"] == "1" else { throw XCTSkip("Opt-in network UI test") }
        let app = XCUIApplication()
        app.launchArguments = ["--booru-live-ui-test", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch(); app.tabBars.buttons["Explore"].tap()
        element(app, "booru.server").tap(); app.buttons["Gelbooru"].tap(); app.buttons["Safebooru"].tap()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).tap()
        let search = element(app, "booru.search")
        search.tap(); search.typeText("id:15029425"); app.keyboards.buttons["Search"].tap()
        app.tabBars.buttons["More"].tap()
        reveal(app, "booru.validate").tap()
        XCTAssertTrue(element(app, "booru.validationWeb").waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 8)
        XCTAssertFalse(app.staticTexts["Unable to Load"].exists, "The visible validation page itself must connect")
        element(app, "booru.validationDone").tap(); app.tabBars.buttons["Explore"].tap()
        let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'booru.post.'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 40), "Public Gelbooru gallery must load without an API key")
        XCTAssertTrue(element(app, "booru.post.15029425").exists)
        element(app, "booru.post.15029425").tap()
        let status = element(app, "booru.mediaStatus")
        expectation(for: NSPredicate(format: "value != 'unresolved'"), evaluatedWith: status)
        waitForExpectations(timeout: 45)
        let attachment = XCTAttachment(string: status.value as? String ?? "No original URL")
        attachment.name = "Resolved reported media URL"; attachment.lifetime = .keepAlways; add(attachment)
        expectation(for: NSPredicate(format: "label == 'ready' OR label == 'playing'"), evaluatedWith: status)
        waitForExpectations(timeout: 45)
        Thread.sleep(forTimeInterval: 5)
        XCTAssertTrue(["ready", "playing"].contains(status.label), "Original media must remain loaded after resolution")
        capture(app, "Gelbooru reported post 15029425 viewer")
    }

    func testPopularSortAndDanbooruAccountGuidance() {
        let app = launch(extra: ["--booru-tag-limit-test"])
        XCTAssertEqual(app.tabBars.buttons.element(boundBy: 0).label, "Saved")
        XCTAssertEqual(app.tabBars.buttons.element(boundBy: 1).label, "Explore")
        element(app, "booru.sort").tap(); app.buttons["Popular"].tap()
        XCTAssertTrue(element(app, "booru.sort").label.contains("Popular"))
        let search = element(app, "booru.search")
        search.tap(); search.typeText("scenery mountain")
        app.keyboards.buttons["Search"].tap()
        let account = element(app, "booru.accountSettings")
        XCTAssertTrue(account.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Gelbooru does not have this two-tag limit.")).firstMatch.exists)
        capture(app, "Danbooru tag limit account guidance")
        account.tap()
        XCTAssertTrue(app.secureTextFields["API Key"].waitForExistence(timeout: 5))
    }

    func testLanguageSettingsAndOnboardingReplay() {
        let app = launch()
        app.tabBars.buttons["More"].tap()
        element(app, "settings.translationLanguage").tap()
        XCTAssertTrue(element(app, "translation.language.system").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "translation.language.system").isSelected)
        reveal(app, "translation.language.en").tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        element(app, "settings.appLanguage").tap()
        app.buttons["한국어"].tap()
        XCTAssertTrue(app.tabBars.buttons["저장"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.tabBars.buttons.element(boundBy: 2).label, "태그")
        app.tabBars.buttons["더보기"].tap()
        element(app, "settings.translationLanguage").tap()
        XCTAssertTrue(reveal(app, "translation.language.en").isSelected)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        element(app, "settings.onboarding").tap()
        XCTAssertTrue(element(app, "onboarding.addServer").waitForExistence(timeout: 5))
        capture(app, "Korean replay onboarding")
        // A settings replay remains dismissible without changing the user's library.
        app.buttons["완료"].tap()
        element(app, "app.mode.hitomi").tap()
        app.tabBars.buttons["설정"].tap()
        element(app, "settings.translationLanguage").tap()
        XCTAssertTrue(element(app, "translation.language.system").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "translation.language.system").isSelected)
    }

    func testExplicitTranslationLanguageUsesAppleTranslation() {
        let app = launch()
        app.tabBars.buttons["More"].tap()
        element(app, "settings.translationLanguage").tap()
        reveal(app, "translation.language.en").tap()
        app.tabBars.buttons["Explore"].tap()
        let card = element(app, "booru.post.101")
        XCTAssertTrue(card.waitForExistence(timeout: 5)); card.tap()
        openMenu(app); element(app, "booru.translate").tap()
        let text = element(app, "reader.translation.text.0")
        // Apple may ask to download a language the first time this device uses it.
        if app.buttons["Continue"].waitForExistence(timeout: 3) { app.buttons["Continue"].tap() }
        XCTAssertTrue(text.waitForExistence(timeout: 45))
        XCTAssertTrue(text.label.lowercased().contains("weather") || text.label.lowercased().contains("day"))
        capture(app, "Explicit English translation")
        element(app, "reader.original").tap()
        XCTAssertTrue(element(app, "booru.media").waitForExistence(timeout: 5))
    }

    func testLiveDanbooruValidationBrowser() throws {
        guard ProcessInfo.processInfo.environment["NUMBER_MEMO_BOORU_LIVE_TESTS"] == "1" else { throw XCTSkip("Opt-in network UI test") }
        let app = XCUIApplication()
        app.launchArguments = ["--booru-live-ui-test", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        app.tabBars.buttons["Explore"].tap()
        XCTAssertTrue(element(app, "booru.server").waitForExistence(timeout: 10))
        element(app, "booru.server").tap(); app.buttons["Danbooru"].tap(); app.buttons["Safebooru"].tap()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).tap()
        let search = element(app, "booru.search")
        search.tap(); search.typeText("rating:g landscape"); app.keyboards.buttons["Search"].tap()
        app.tabBars.buttons["More"].tap()
        reveal(app, "booru.validate").tap()
        XCTAssertTrue(element(app, "booru.validationWeb").waitForExistence(timeout: 10))
        let error = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@ OR label BEGINSWITH %@", "Unable to connect securely.", "The server interrupted the connection.")).firstMatch
        if error.waitForExistence(timeout: 8) {
            throw XCTSkip("The live validation page could not connect on this device network")
        }
        element(app, "booru.validationDone").tap()
        app.tabBars.buttons["Explore"].tap()
        let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'booru.post.'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 35), "Explore must load through the retained validation browser")
        app.buttons["Clear Search"].tap()
        element(app, "booru.rating").tap(); app.buttons["General / Safe"].tap()
        element(app, "booru.sort").tap(); app.buttons["Popular"].tap()
        XCTAssertTrue(card.waitForExistence(timeout: 40), "Danbooru score sorting must recover from server timeouts")
        capture(app, "Danbooru score exploration after browser validation")
    }

    func testLiveDanbooruPoolsAfterValidation() throws {
        guard ProcessInfo.processInfo.environment["NUMBER_MEMO_BOORU_LIVE_TESTS"] == "1" else { throw XCTSkip("Opt-in network UI test") }
        let app = XCUIApplication()
        app.launchArguments = ["--booru-live-ui-test", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch(); app.tabBars.buttons["Explore"].tap()
        element(app, "booru.server").tap(); app.buttons["Danbooru"].tap(); app.buttons["Safebooru"].tap()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).tap()
        app.tabBars.buttons["More"].tap()
        reveal(app, "booru.validate").tap()
        XCTAssertTrue(element(app, "booru.validationWeb").waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 8)
        element(app, "booru.validationDone").tap()
        for _ in 0..<6 {
            if element(app, "booru.poolsLink").isHittable { break }
            app.swipeDown()
        }
        element(app, "booru.poolsLink").tap()
        let pool = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'booru.pool.'")).firstMatch
        XCTAssertTrue(pool.waitForExistence(timeout: 90), "Pool summaries must load in the validated browser")
        capture(app, "Danbooru live pool list after validation")
    }

    func testLiveSafebooruImageAndZoom() throws {
        guard ProcessInfo.processInfo.environment["NUMBER_MEMO_BOORU_LIVE_TESTS"] == "1" else { throw XCTSkip("Opt-in network UI test") }
        let app = XCUIApplication()
        app.launchArguments = ["--booru-live-ui-test", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        app.tabBars.buttons["Explore"].tap()
        let search = element(app, "booru.search")
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap(); search.typeText("landscape"); app.keyboards.buttons["Search"].tap()
        let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'booru.post.'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 30))
        capture(app, "Safebooru live landscape search")
        card.tap()
        let status = element(app, "booru.mediaStatus")
        expectation(for: NSPredicate(format: "label == 'ready'"), evaluatedWith: status)
        waitForExpectations(timeout: 30)
        let media = element(app, "booru.media")
        media.pinch(withScale: 2, velocity: 1)
        expectation(for: NSPredicate(format: "label ENDSWITH %@", ":zoomed"), evaluatedWith: element(app, "booru.viewerState")); waitForExpectations(timeout: 5)
        capture(app, "Safebooru live image zoom")
        XCTAssertFalse(app.staticTexts["Unable to Load"].exists)
    }
}
