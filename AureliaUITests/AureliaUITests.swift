//
//  AureliaUITests.swift
//  AureliaUITests
//
//  Created by Grafton on 10/17/25.
//

import XCTest

final class AureliaUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testExample() throws {
        // UI tests must launch the application that they test.
        let app = XCUIApplication()
        app.launch()

        // Use XCTAssert and related functions to verify your tests produce the correct results.
    }

    @MainActor
    func testDiscoverPresentationKeepsNowPlayingCentered() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-player-layout"]
        app.launch()

        let mixesTitle = app.staticTexts["discovery-mixes-title"]
        let recentTitle = app.staticTexts["discovery-recent-title"]
        XCTAssertTrue(mixesTitle.waitForExistence(timeout: 5))
        XCTAssertTrue(recentTitle.waitForExistence(timeout: 5))
        XCTAssertLessThan(mixesTitle.frame.minY, recentTitle.frame.minY)

        let discoveryMix = app.buttons["discovery-mix-ui-layout-mix"]
        XCTAssertTrue(discoveryMix.waitForExistence(timeout: 5))
        discoveryMix.tap()

        let miniPlayer = app.buttons["mini-player"]
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForHittable(miniPlayer, timeout: 5))
        let closeButton = app.buttons["now-playing-close"]
        XCTAssertFalse(closeButton.exists)

        let nextButton = app.buttons["mini-player-next"]
        let playbackButton = app.buttons["mini-player-playback"]
        XCTAssertTrue(nextButton.waitForExistence(timeout: 5))
        XCTAssertTrue(playbackButton.waitForExistence(timeout: 5))
        XCTAssertTrue(nextButton.isEnabled)
        nextButton.tap()
        XCTAssertTrue(waitForLabel(miniPlayer, containing: "Next Test Track", timeout: 5))

        miniPlayer.tap()
        let artwork = app.descendants(matching: .any)["now-playing-artwork"]
        let waveform = app.descendants(matching: .any)["now-playing-waveform"]
        let title = app.staticTexts["now-playing-title"]
        let favorite = app.buttons["now-playing-favorite"]
        XCTAssertTrue(closeButton.waitForExistence(timeout: 5))
        XCTAssertTrue(artwork.waitForExistence(timeout: 5))
        XCTAssertTrue(waveform.waitForExistence(timeout: 5))
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertTrue(favorite.waitForExistence(timeout: 5))

        let windowFrame = app.windows.firstMatch.frame
        XCTAssertEqual(artwork.frame.midX, windowFrame.midX, accuracy: 2)
        XCTAssertGreaterThanOrEqual(artwork.frame.minX, windowFrame.minX)
        XCTAssertLessThanOrEqual(artwork.frame.maxX, windowFrame.maxX)
        XCTAssertGreaterThanOrEqual(waveform.frame.minX, windowFrame.minX)
        XCTAssertLessThanOrEqual(waveform.frame.maxX, windowFrame.maxX)
        XCTAssertLessThan(closeButton.frame.midX, windowFrame.midX)
        XCTAssertFalse(title.frame.intersects(favorite.frame))

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Centered Discover to Now Playing"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testMiniPlayerAndNowPlayingPresentationCycle() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-player-layout"]
        app.launch()

        let discoveryMix = app.buttons["discovery-mix-ui-layout-mix"]
        XCTAssertTrue(discoveryMix.waitForExistence(timeout: 5))
        discoveryMix.tap()

        let miniPlayer = app.buttons["mini-player"]
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForHittable(miniPlayer, timeout: 5))
        let closeButton = app.buttons["now-playing-close"]
        XCTAssertFalse(closeButton.exists)
        miniPlayer.tap()
        XCTAssertTrue(closeButton.waitForExistence(timeout: 5))
        closeButton.tap()

        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForHittable(miniPlayer, timeout: 5))
        miniPlayer.tap()

        XCTAssertTrue(closeButton.waitForExistence(timeout: 5))
        let artwork = app.descendants(matching: .any)["now-playing-artwork"]
        XCTAssertTrue(artwork.waitForExistence(timeout: 5))
        XCTAssertEqual(artwork.frame.midX, app.windows.firstMatch.frame.midX, accuracy: 2)

        // From the top of the player, a downward swipe is a dismissal rather
        // than a scroll.
        let scrollView = app.scrollViews["now-playing-scroll"]
        XCTAssertTrue(scrollView.waitForExistence(timeout: 5))
        scrollView.swipeDown()
        XCTAssertTrue(closeButton.waitForNonExistence(timeout: 5))
        XCTAssertTrue(waitForHittable(miniPlayer, timeout: 5))
        miniPlayer.tap()
        XCTAssertTrue(closeButton.waitForExistence(timeout: 5))

        let dismissHandle = app.descendants(matching: .any)["now-playing-dismiss-handle"]
        XCTAssertTrue(dismissHandle.waitForExistence(timeout: 5))
        let swipeStart = dismissHandle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let swipeEnd = swipeStart.withOffset(CGVector(dx: 0, dy: 420))
        swipeStart.press(forDuration: 0.05, thenDragTo: swipeEnd)
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForHittable(miniPlayer, timeout: 5))
    }

    @MainActor
    func testUpNextTrackCanBeSelected() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-player-layout"]
        app.launch()

        let discoveryMix = app.buttons["discovery-mix-ui-layout-mix"]
        XCTAssertTrue(discoveryMix.waitForExistence(timeout: 5))
        discoveryMix.tap()

        let miniPlayer = app.buttons["mini-player"]
        XCTAssertTrue(waitForHittable(miniPlayer, timeout: 5))
        miniPlayer.tap()

        let playerScrollView = app.scrollViews["now-playing-scroll"]
        XCTAssertTrue(playerScrollView.waitForExistence(timeout: 5))
        let nextTrack = app.buttons["now-playing-up-next-ui-layout-next"]
        XCTAssertTrue(scrollToHittable(nextTrack, in: playerScrollView))
        let delete = app.buttons["Delete Next Test Track from queue"]
        XCTAssertFalse(delete.exists)
        let swipeStart = nextTrack.coordinate(
            withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)
        )
        let swipeEnd = swipeStart.withOffset(CGVector(dx: -160, dy: 0))
        swipeStart.press(forDuration: 0.05, thenDragTo: swipeEnd)
        XCTAssertTrue(waitForHittable(delete, timeout: 5))
        delete.tap()

        let title = app.staticTexts["now-playing-title"]
        XCTAssertTrue(waitForLabel(
            title,
            containing: "The Age Of Love",
            timeout: 5
        ))
        let remainingTrack = app.buttons["now-playing-up-next-ui-layout-after-next"]
        XCTAssertTrue(scrollToHittable(remainingTrack, in: playerScrollView))
        remainingTrack.tap()
        XCTAssertTrue(waitForLabel(title, containing: "After Delete Test Track", timeout: 5))
    }

    @MainActor
    func testSwitchingTabsDismissesNowPlaying() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-player-layout"]
        app.launch()

        let discoveryMix = app.buttons["discovery-mix-ui-layout-mix"]
        XCTAssertTrue(discoveryMix.waitForExistence(timeout: 5))
        discoveryMix.tap()

        let miniPlayer = app.buttons["mini-player"]
        XCTAssertTrue(waitForHittable(miniPlayer, timeout: 5))
        miniPlayer.tap()

        let closeButton = app.buttons["now-playing-close"]
        XCTAssertTrue(closeButton.waitForExistence(timeout: 5))

        let libraryTab = app.tabBars.buttons["Library"]
        XCTAssertTrue(waitForHittable(libraryTab, timeout: 5))
        libraryTab.tap()

        XCTAssertTrue(waitForSelected(libraryTab, timeout: 5))
        XCTAssertFalse(app.tabBars.buttons["Discover"].isSelected)
        XCTAssertTrue(closeButton.waitForNonExistence(timeout: 5))
        XCTAssertTrue(waitForHittable(miniPlayer, timeout: 5))
    }

    @MainActor
    func testSearchResultsStayAboveMiniPlayerWithKeyboardVisible() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-player-layout"]
        app.launch()

        let discoveryMix = app.buttons["discovery-mix-ui-layout-mix"]
        XCTAssertTrue(discoveryMix.waitForExistence(timeout: 5))
        discoveryMix.tap()

        let miniPlayer = app.buttons["mini-player"]
        XCTAssertTrue(waitForHittable(miniPlayer, timeout: 5))
        app.tabBars.buttons["Search"].tap()

        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        searchField.tap()
        searchField.typeText("layout")

        let keyboardOnboardingContinue = app.buttons["Continue"]
        if keyboardOnboardingContinue.waitForExistence(timeout: 2) {
            keyboardOnboardingContinue.tap()
        }

        let resultsList = app.scrollViews["search-results-list"]
        let lastResult = app.buttons["search-result-ui-search-8"]
        XCTAssertTrue(resultsList.waitForExistence(timeout: 5))
        XCTAssertTrue(lastResult.waitForExistence(timeout: 5))

        let dragStart = resultsList.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        let dragEnd = resultsList.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05))
        for _ in 0..<6 where lastResult.frame.maxY > miniPlayer.frame.minY {
            dragStart.press(
                forDuration: 0.05,
                thenDragTo: dragEnd,
                withVelocity: .fast,
                thenHoldForDuration: 0
            )
        }

        XCTAssertTrue(lastResult.isHittable)
        XCTAssertLessThanOrEqual(lastResult.frame.maxY, miniPlayer.frame.minY + 1)

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Search results clear the mini player"
        attachment.lifetime = .keepAlways
        add(attachment)

        lastResult.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
    }

    @MainActor
    func testRootTabsKeepNavigationTitlesCompact() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-player-layout"]
        app.launch()

        for title in ["Discover", "Search", "Favorites", "Settings"] {
            if title != "Discover" {
                app.tabBars.buttons[title].tap()
            }

            let navigationBar = app.navigationBars[title]
            let titleLabel = navigationBar.staticTexts[title]
            XCTAssertTrue(navigationBar.waitForExistence(timeout: 5))
            XCTAssertTrue(titleLabel.waitForExistence(timeout: 5))
            XCTAssertLessThanOrEqual(
                titleLabel.frame.midY,
                navigationBar.frame.minY + 48,
                "\(title) should use the compact inline title position"
            )
        }
    }

    @MainActor
    func testDownloadsUseLiteralYearAndExposeLongPressActions() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-downloads"]
        app.launch()

        let album = app.buttons["downloaded-album-ui-download-album"]
        let year = app.staticTexts["downloaded-album-year-ui-download-album"]
        XCTAssertTrue(album.waitForExistence(timeout: 5))
        XCTAssertTrue(year.waitForExistence(timeout: 5))
        XCTAssertEqual(year.label, "2026")

        album.press(forDuration: 0.8)
        for action in ["Play", "Shuffle", "Play Next", "Add to Queue", "Go to Artist", "Delete Download"] {
            XCTAssertTrue(app.buttons[action].waitForExistence(timeout: 5), "Missing album action: \(action)")
        }

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.1)).tap()
        album.tap()

        let track = app.buttons["downloaded-track-ui-download-track"]
        XCTAssertTrue(track.waitForExistence(timeout: 5))
        track.press(forDuration: 0.8)
        for action in ["Go to Album", "Go to Artist", "Play Next", "Play Last", "Add to Queue", "Delete Download"] {
            XCTAssertTrue(app.buttons[action].waitForExistence(timeout: 5), "Missing track action: \(action)")
        }
    }

    @MainActor
    private func waitForHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true"),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor
    private func waitForSelected(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "selected == true"),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor
    private func scrollToHittable(
        _ element: XCUIElement,
        in scrollView: XCUIElement,
        maxAttempts: Int = 6
    ) -> Bool {
        // Rows far enough down the queue are not built until they are scrolled
        // towards, so keep scrolling while the element is still missing.
        for _ in 0..<maxAttempts where !element.exists || !element.isHittable {
            let start = scrollView.coordinate(
                withNormalizedOffset: CGVector(dx: 0.15, dy: 0.8)
            )
            let end = scrollView.coordinate(
                withNormalizedOffset: CGVector(dx: 0.15, dy: 0.3)
            )
            start.press(
                forDuration: 0.05,
                thenDragTo: end,
                withVelocity: .fast,
                thenHoldForDuration: 0
            )
        }

        return element.exists && element.isHittable
    }

    @MainActor
    private func waitForLabel(
        _ element: XCUIElement,
        containing text: String,
        timeout: TimeInterval
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", text),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor
    func testAlbumDetailWithArtworkStaysInsideViewport() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-album-layout"]
        app.launch()

        let artwork = app.images["album-detail-artwork"]
        let playAll = app.buttons["album-play-all"]
        let artistLink = app.buttons["album-artist-link"]
        let shuffle = app.buttons["album-shuffle"]
        let favorite = app.buttons["album-favorite"]
        let download = app.buttons["album-download"]
        let firstTrack = app.descendants(matching: .any)["album-track-ui-album-track-1"]
        XCTAssertTrue(artwork.waitForExistence(timeout: 5))
        XCTAssertTrue(playAll.waitForExistence(timeout: 5))
        XCTAssertTrue(artistLink.waitForExistence(timeout: 5))
        XCTAssertTrue(shuffle.waitForExistence(timeout: 5))
        XCTAssertTrue(favorite.waitForExistence(timeout: 5))
        XCTAssertTrue(download.waitForExistence(timeout: 5))
        XCTAssertTrue(firstTrack.waitForExistence(timeout: 5))

        let windowFrame = app.windows.firstMatch.frame
        XCTAssertEqual(artwork.frame.midX, windowFrame.midX, accuracy: 2)
        for element in [artwork, artistLink, playAll, shuffle, favorite, download, firstTrack] {
            XCTAssertGreaterThanOrEqual(element.frame.minX, windowFrame.minX)
            XCTAssertLessThanOrEqual(element.frame.maxX, windowFrame.maxX)
        }

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Bounded Album Detail"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
