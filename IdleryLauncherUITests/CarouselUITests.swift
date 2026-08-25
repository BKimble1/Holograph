import XCTest

final class CarouselUITests: LauncherUITestCase {
    /// The demo set, left to right.
    private let demoOrder = ["Truebearing", "Aquify", "Tagfield", "Scanpoint", "Corevault"]

    func testSwipingLeftMovesTheSelectionTowardsTheEnd() {
        launchApp(seed: .demoApps)
        XCTAssertTrue(selectedAppName.waitForExistence(timeout: 20))
        XCTAssertEqual(selectedAppName.label, "Tagfield")

        carousel.swipeLeft(velocity: .slow)

        let landed = waitForLabelChange(from: "Tagfield", on: selectedAppName)
        XCTAssertTrue(
            ["Scanpoint", "Corevault"].contains(landed),
            "Swiping left should settle on an app to the right of Tagfield, landed on \(landed)"
        )
    }

    func testSwipingRightMovesTheSelectionTowardsTheStart() {
        launchApp(seed: .demoApps)
        XCTAssertTrue(selectedAppName.waitForExistence(timeout: 20))

        carousel.swipeRight(velocity: .slow)

        let landed = waitForLabelChange(from: "Tagfield", on: selectedAppName)
        XCTAssertTrue(
            ["Aquify", "Truebearing"].contains(landed),
            "Swiping right should settle on an app to the left of Tagfield, landed on \(landed)"
        )
    }

    func testTheCarouselAlwaysSettlesOnOneOfTheApps() {
        launchApp(seed: .demoApps)
        XCTAssertTrue(selectedAppName.waitForExistence(timeout: 20))

        carousel.swipeLeft(velocity: .fast)
        _ = waitForLabelChange(from: "Tagfield", on: selectedAppName)

        XCTAssertTrue(
            demoOrder.contains(selectedAppName.label),
            "Snapping must land exactly on an app, not between two, got \(selectedAppName.label)"
        )
    }

    func testTappingASideAppCentresItWithoutLaunching() {
        launchApp(seed: .demoApps, launcher: .fails)
        XCTAssertTrue(selectedAppName.waitForExistence(timeout: 20))

        let neighbour = carouselItem("Scanpoint")
        XCTAssertTrue(neighbour.waitForExistence(timeout: 10))
        neighbour.tap()

        waitForLabel("Scanpoint", on: selectedAppName)
        // A failing launcher would have raised recovery had this tap launched.
        XCTAssertFalse(app.alerts.element.exists, "The first tap must centre, not launch")
    }

    func testCentringASideAppThenLaunchingItTakesTwoTaps() {
        launchApp(seed: .demoApps, launcher: .fails)
        XCTAssertTrue(selectedAppName.waitForExistence(timeout: 20))

        let neighbour = carouselItem("Aquify")
        XCTAssertTrue(neighbour.waitForExistence(timeout: 10))

        neighbour.tap()
        waitForLabel("Aquify", on: selectedAppName)
        XCTAssertFalse(app.alerts.element.exists)

        carouselItem("Aquify").tap()
        XCTAssertTrue(app.alerts.element.waitForExistence(timeout: 20), "The second tap should launch")
    }

    func testLaunchingTheCentredAppSucceedsQuietly() {
        launchApp(seed: .demoApps, launcher: .succeeds)
        XCTAssertTrue(selectedAppName.waitForExistence(timeout: 20))

        carouselItem("Tagfield").tap()

        XCTAssertFalse(
            app.alerts.element.waitForExistence(timeout: 5),
            "A launch the system accepts should not interrupt the user"
        )
        XCTAssertEqual(selectedAppName.label, "Tagfield")
    }

    func testFailedLaunchOffersRecoveryAndCanBeDismissed() {
        launchApp(seed: .demoApps, launcher: .fails)
        XCTAssertTrue(selectedAppName.waitForExistence(timeout: 20))

        carouselItem("Tagfield").tap()

        let alert = app.alerts.element
        XCTAssertTrue(alert.waitForExistence(timeout: 20), "A refused launch must explain itself")
        XCTAssertTrue(alert.buttons["Edit App"].exists)
        XCTAssertTrue(alert.buttons["Cancel"].exists)

        alert.buttons["Cancel"].tap()
        XCTAssertFalse(app.alerts.element.waitForExistence(timeout: 3))
        XCTAssertEqual(selectedAppName.label, "Tagfield", "Cancelling leaves the launcher untouched")
    }

    func testFailedLaunchCanJumpStraightToEditingTheApp() {
        launchApp(seed: .demoApps, launcher: .fails)
        XCTAssertTrue(selectedAppName.waitForExistence(timeout: 20))

        carouselItem("Tagfield").tap()

        let alert = app.alerts.element
        XCTAssertTrue(alert.waitForExistence(timeout: 20))
        alert.buttons["Edit App"].tap()

        let nameField = app.textFields["editor.name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 20), "Recovery should open the editor for that app")
        XCTAssertEqual(nameField.value as? String, "Tagfield")
    }

    // MARK: - Helpers

    @discardableResult
    private func waitForLabelChange(
        from previous: String,
        on element: XCUIElement,
        timeout: TimeInterval = 20,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> String {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label != %@", previous),
            object: element
        )
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
        XCTAssertEqual(result, .completed, "Selection never moved away from \(previous)", file: file, line: line)
        return element.label
    }

    private func waitForLabel(
        _ label: String,
        on element: XCUIElement,
        timeout: TimeInterval = 20,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", label),
            object: element
        )
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
        XCTAssertEqual(result, .completed, "Expected “\(label)”, found “\(element.label)”", file: file, line: line)
    }
}
