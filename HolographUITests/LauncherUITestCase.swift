import XCTest

/// Shared plumbing: every test launches the app with an explicit, deterministic
/// configuration so nothing depends on what a previous run left behind.
///
/// Main-actor isolated because every `XCUIElement` API is. Setup happens inside
/// `launchApp` rather than a `setUp` override, which keeps the isolation of this
/// class independent of `XCTestCase`'s.
@MainActor
class LauncherUITestCase: XCTestCase {
    enum Seed {
        case demoApps
        case empty
    }

    enum LaunchStub {
        case succeeds
        case fails
    }

    enum Animations {
        /// The default for behavioural tests: continuous effects off and the
        /// loading screen shortened, so the suite is not paced by animation.
        case shortened
        /// Full-length motion, with the loading screen held open long enough to
        /// be asserted on and photographed.
        case holdIntro
    }

    var app: XCUIApplication!

    @discardableResult
    func launchApp(
        seed: Seed,
        launcher: LaunchStub = .succeeds,
        animations: Animations = .shortened
    ) -> XCUIApplication {
        continueAfterFailure = false
        let application = XCUIApplication()
        var arguments = [
            "-uiTesting",
            "-inMemoryStore",
            seed == .demoApps ? "-seedDemoApps" : "-seedEmpty",
            launcher == .succeeds ? "-mockLaunchSuccess" : "-mockLaunchFailure"
        ]
        switch animations {
        case .shortened:
            arguments.append("-disableAnimations")
        case .holdIntro:
            arguments.append("-holdLoadingScreen")
        }
        application.launchArguments = arguments
        application.launch()
        app = application
        return application
    }

    var loadingScreen: XCUIElement {
        app.descendants(matching: .any)[AccessibilityIdentifiers.loadingScreen].firstMatch
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

    /// A row's "…" menu, resolved by identifier or by accessibility label.
    ///
    /// Both are polled rather than one being preferred outright: whether a
    /// `Menu` surfaces the identifier SwiftUI is given depends on what the rest
    /// of the row does with accessibility, and the label is the sturdier of the
    /// two. Returns whichever resolves first, or the label query on timeout so
    /// the caller's assertion reports something meaningful.
    func rowMenu(_ name: String, timeout: TimeInterval = 20) -> XCUIElement {
        let byIdentifier = app.descendants(matching: .any)["settings.row.menu.\(name)"].firstMatch
        let byLabel = app.descendants(matching: .any)["Actions for \(name)"].firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if byLabel.exists { return byLabel }
            if byIdentifier.exists { return byIdentifier }
            // Doubles as the poll interval; there is nothing to wait on that is
            // not already covered by the two queries.
            _ = byLabel.waitForExistence(timeout: 0.5)
        } while Date() < deadline
        return byLabel
    }

    /// A compact dump of what is actually on screen, for failure messages.
    ///
    /// A UI test that cannot find an element is only useful if it says what it
    /// did find — otherwise the next run is another guess.
    func visibleElementSummary(limit: Int = 80) -> String {
        let elements = app.descendants(matching: .any).allElementsBoundByIndex
        let lines = elements.prefix(limit).map { element -> String in
            "type=\(element.elementType.rawValue) id=\(element.identifier) label=\(element.label)"
        }
        let suffix = elements.count > limit ? "\n… and \(elements.count - limit) more" : ""
        return lines.joined(separator: "\n") + suffix
    }

    /// Settings is a form sheet; the lower sections need scrolling into view
    /// before they can be tapped.
    @discardableResult
    func revealInSettings(_ identifier: String, attempts: Int = 6) -> XCUIElement {
        let element = app.descendants(matching: .any)[identifier].firstMatch
        for _ in 0..<attempts {
            if element.exists, element.isHittable { return element }
            app.swipeUp(velocity: .slow)
        }
        return element
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

    /// Taps an entry inside a row's "…" menu.
    ///
    /// `UIMenu` does not always carry the accessibility identifier SwiftUI puts
    /// on the button, so this falls back to the visible title.
    func tapRowMenuItem(
        row name: String,
        item identifier: String,
        titled title: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let menu = rowMenu(name)
        guard menu.exists else {
            XCTFail("No menu for \(name). On screen:\n\(visibleElementSummary())", file: file, line: line)
            return
        }
        menu.tap()

        let byIdentifier = app.descendants(matching: .any)[identifier].firstMatch
        if byIdentifier.waitForExistence(timeout: 4) {
            byIdentifier.tap()
            return
        }
        let byTitle = app.buttons[title].firstMatch
        XCTAssertTrue(
            byTitle.waitForExistence(timeout: 10),
            "Neither \(identifier) nor a button titled “\(title)” appeared in the menu",
            file: file,
            line: line
        )
        byTitle.tap()
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

/// Mirrors `AccessibilityID` in the app target. UI tests run out of process, so
/// they cannot import it — keeping the strings in one place here means a rename
/// is a single edit on each side.
enum AccessibilityIdentifiers {
    static let loadingScreen = "loading.screen"
    static let poweredByIdlery = "loading.poweredByIdlery"
}
