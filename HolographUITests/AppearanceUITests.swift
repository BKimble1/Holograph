import XCTest

/// Captures the launcher in the states that matter and attaches the images to
/// the test results, so a design change can be reviewed without a device to
/// hand. These are attachments, not assertions — nothing here fails on pixels.
final class AppearanceUITests: LauncherUITestCase {
    func testCaptureLauncherAppearance() {
        launchApp(seed: .demoApps)
        XCTAssertTrue(selectedAppName.waitForExistence(timeout: 30))

        XCUIDevice.shared.orientation = .landscapeLeft
        settle()
        attachScreenshot(named: "01-launcher-landscape")

        // A neighbour brought to the centre, to show the depth curve mid-row.
        carouselItem("Scanpoint").tap()
        settle()
        attachScreenshot(named: "02-launcher-after-centring")

        XCUIDevice.shared.orientation = .portrait
        settle()
        attachScreenshot(named: "03-launcher-portrait")

        XCUIDevice.shared.orientation = .landscapeLeft
        settle()

        settingsButton.tap()
        XCTAssertTrue(addApp.waitForExistence(timeout: 30))
        settle()
        attachScreenshot(named: "04-settings-sheet")

        addApp.tap()
        XCTAssertTrue(app.textFields["editor.name"].waitForExistence(timeout: 30))
        typeInto(app.textFields["editor.name"], text: "Field Notes")
        settle()
        attachScreenshot(named: "05-editor-with-preview")
    }

    func testCaptureLoadingScreen() {
        launchApp(seed: .demoApps, animations: .full)
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(loadingScreen.waitForExistence(timeout: 20))
        settle(0.5)
        attachScreenshot(named: "00-loading-screen")
    }

    func testCaptureEmptyState() {
        launchApp(seed: .empty)
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(emptyState.waitForExistence(timeout: 30))
        settle()
        attachScreenshot(named: "06-empty-state")
    }

    func testCaptureFailedLaunchRecovery() {
        launchApp(seed: .demoApps, launcher: .fails)
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(selectedAppName.waitForExistence(timeout: 30))

        carouselItem("Tagfield").tap()
        XCTAssertTrue(app.alerts.element.waitForExistence(timeout: 30))
        settle()
        attachScreenshot(named: "07-launch-failure-recovery")
    }

    // MARK: - Helpers

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Lets the interface finish settling before the shutter. Rotation and sheet
    /// presentation both animate even with continuous effects switched off.
    private func settle(_ seconds: TimeInterval = 1.2) {
        _ = app.wait(for: .runningForeground, timeout: 5)
        // An expectation that is never fulfilled is the standard way to spin the
        // run loop for a fixed interval without blocking it.
        _ = XCTWaiter().wait(for: [XCTestExpectation(description: "settle")], timeout: seconds)
    }
}
