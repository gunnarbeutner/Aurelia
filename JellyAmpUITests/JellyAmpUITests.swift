//
//  JellyAmpUITests.swift
//  JellyAmpUITests
//
//  Created by Grafton on 10/17/25.
//

import XCTest

final class JellyAmpUITests: XCTestCase {

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

        let discoveryTrack = app.buttons["discovery-track-ui-layout-track"]
        XCTAssertTrue(discoveryTrack.waitForExistence(timeout: 5))
        discoveryTrack.tap()

        let miniPlayer = app.buttons["mini-player"]
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForHittable(miniPlayer, timeout: 5))
        let closeButton = app.buttons["now-playing-close"]
        XCTAssertFalse(closeButton.exists)

        let nextButton = app.buttons["mini-player-next"]
        XCTAssertTrue(nextButton.waitForExistence(timeout: 5))
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

        let discoveryTrack = app.buttons["discovery-track-ui-layout-track"]
        XCTAssertTrue(discoveryTrack.waitForExistence(timeout: 5))
        discoveryTrack.tap()

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

        let window = app.windows.firstMatch
        let swipeStart = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        let swipeEnd = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
        swipeStart.press(forDuration: 0.05, thenDragTo: swipeEnd)
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForHittable(miniPlayer, timeout: 5))
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
        let shuffle = app.buttons["album-shuffle"]
        let favorite = app.buttons["album-favorite"]
        let download = app.buttons["album-download"]
        let firstTrack = app.descendants(matching: .any)["album-track-ui-album-track-1"]
        XCTAssertTrue(artwork.waitForExistence(timeout: 5))
        XCTAssertTrue(playAll.waitForExistence(timeout: 5))
        XCTAssertTrue(shuffle.waitForExistence(timeout: 5))
        XCTAssertTrue(favorite.waitForExistence(timeout: 5))
        XCTAssertTrue(download.waitForExistence(timeout: 5))
        XCTAssertTrue(firstTrack.waitForExistence(timeout: 5))

        let windowFrame = app.windows.firstMatch.frame
        XCTAssertEqual(artwork.frame.midX, windowFrame.midX, accuracy: 2)
        for element in [artwork, playAll, shuffle, favorite, download, firstTrack] {
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
