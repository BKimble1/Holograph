import XCTest

/// Shared plumbing: every test launches the app with an explicit, deterministic
/// configuration so nothing depends on what a previous run left behind.
class LauncherUITestCase: XCTestCase {
    enum Seed {
        case demoApps
        case empty
    }

    enum LaunchStub {
        case succeeds
        case fails
    }

    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    override func tearDown() {
        app = nil
        super.tearDown()
    }

    @discardableResult
    func launchApp(seed: Seed, launcher: LaunchStub = .succeeds) -> XCUIApplication {
        let application = XCUIApplication()
        application.launchArguments = [
            "-uiTesting",
            "-inMemoryStore",
            "-disableAnimations",
            seed == .demoApps ? "-seedDemoApps" : "-seedEmpty",
            launcher == .succeeds ? "-mockLaunchSuccess" : "-mockLaunchFailure"
        ]
        application.launch()
        app = application
        return application
    }

    // MARK: - Element accessors

    var settingsButton: XCUIElement { app.buttons["launcher.settingsButton"] }
    var settingsDone: XCUIElement { app.buttons["settings.done"] }
    var addApp: XCUIElement { app.buttons["settings.addApp"] }
    var emptyState: XCUIElement { app.buttons["launcher.emptyState"] }
    var selectedAppName: XCUIElement { app.staticTexts["launcher.selectedAppName"] }
    var carousel: XCUIElement {
        let identified = app.descendants(matching: .any)["launcher.carousel"].firstMatch
        return identified.exists ? identified : app.scrollViews.firstMatch
    }

    func carouselItem(_ name: String) -> XCUIElement {
        app.descendants(matching: .any)["launcher.item.\(name)"].firstMatch
    }

    func appRow(_ name: String) -> XCUIElement {
        app.descendants(matching: .any)["settings.row.\(name)"].firstMatch
    }

    func rowMenu(_ name: String) -> XCUIElement {
        app.buttons["settings.row.menu.\(name)"].firstMatch
    }

    func openSettings(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 10), "Settings button never appeared", file: file, line: line)
        settingsButton.tap()
        XCTAssertTrue(addApp.waitForExistence(timeout: 10), "Settings sheet never appeared", file: file, line: line)
    }

    func closeSettings() {
        if settingsDone.exists {
            settingsDone.tap()
        }
    }

    /// Taps a menu entry that lives inside a row's "…" menu.
    func tapRowMenuItem(row name: String, item identifier: String, file: StaticString = #filePath, line: UInt = #line) {
        let menu = rowMenu(name)
        XCTAssertTrue(menu.waitForExistence(timeout: 10), "No menu for \(name)", file: file, line: line)
        menu.tap()
        let entry = app.buttons[identifier].firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 10), "Menu item \(identifier) never appeared", file: file, line: line)
        entry.tap()
    }

    func typeInto(_ element: XCUIElement, text: String, clearFirst: Bool = false, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: 10), "Field \(element) never appeared", file: file, line: line)
        element.tap()
        if clearFirst, let current = element.value as? String, !current.isEmpty {
            element.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        element.typeText(text)
    }
}
