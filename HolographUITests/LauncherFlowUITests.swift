import XCTest

final class LauncherFlowUITests: LauncherUITestCase {
    func testTheAppOpensOnTheLoadingScreenAndThenHandsOver() {
        launchApp(seed: .demoApps, animations: .holdIntro)

        XCTAssertTrue(loadingScreen.waitForExistence(timeout: 20), "The app should open on the loading screen")
        XCTAssertTrue(
            app.descendants(matching: .any)[AccessibilityIdentifiers.poweredByIdlery].firstMatch.exists,
            "The loading screen carries the Idlery credit"
        )

        XCTAssertTrue(selectedAppName.waitForExistence(timeout: 20), "The launcher should take over on its own")
        XCTAssertFalse(loadingScreen.waitForExistence(timeout: 3), "The loading screen should be gone")
    }

    func testEmptyStatePlaceholderOpensSettings() {
        launchApp(seed: .empty)

        XCTAssertTrue(emptyState.waitForExistence(timeout: 20), "The empty placeholder should be on screen")
        emptyState.tap()

        XCTAssertTrue(addApp.waitForExistence(timeout: 20), "Tapping the placeholder should open Settings")
    }

    func testSeededLauncherShowsTheCentredAppAndItsCaption() {
        launchApp(seed: .demoApps)

        XCTAssertTrue(selectedAppName.waitForExistence(timeout: 20))
        XCTAssertEqual(selectedAppName.label, "Tagfield", "The demo set centres on the equipment tag")
        XCTAssertTrue(app.staticTexts["launcher.tapToOpen"].exists)
        XCTAssertFalse(emptyState.exists)
    }

    func testAddingAnAppFromAnEmptyLauncher() {
        launchApp(seed: .empty)

        XCTAssertTrue(emptyState.waitForExistence(timeout: 20))
        emptyState.tap()

        XCTAssertTrue(addApp.waitForExistence(timeout: 20), "The placeholder should open Settings")
        addApp.tap()

        typeInto(app.textFields["editor.name"], text: "Field Notes")
        typeInto(app.textFields["editor.launchURL"], text: "idler-offrent://launch")
        app.buttons["editor.save"].tap()

        XCTAssertTrue(appRow("Field Notes").waitForExistence(timeout: 20), "The new app should be listed")
        closeSettings()

        XCTAssertTrue(selectedAppName.waitForExistence(timeout: 20))
        XCTAssertEqual(selectedAppName.label, "Field Notes")
    }

    func testEditingAnAppRenamesItOnTheLauncher() {
        launchApp(seed: .demoApps)
        openSettings()

        tapRowMenuItem(row: "Aquify", item: "settings.row.edit.Aquify", titled: "Edit App")

        typeInto(app.textFields["editor.name"], text: "Aquify Pro", clearFirst: true)
        app.buttons["editor.save"].tap()

        XCTAssertTrue(appRow("Aquify Pro").waitForExistence(timeout: 20))
        closeSettings()

        XCTAssertTrue(carouselItem("Aquify Pro").waitForExistence(timeout: 20))
    }

    func testInvalidLaunchLinkBlocksSaving() {
        launchApp(seed: .empty)
        openSettings()
        addApp.tap()

        typeInto(app.textFields["editor.name"], text: "Broken")
        typeInto(app.textFields["editor.launchURL"], text: "nonsense")
        app.buttons["editor.save"].tap()

        XCTAssertTrue(
            app.staticTexts["editor.validationMessage"].waitForExistence(timeout: 10),
            "An invalid link should explain itself rather than saving"
        )
        XCTAssertTrue(app.buttons["editor.save"].exists, "The editor should still be open")
    }

    func testReorderingMovesAnAppAndKeepsTheSameAppCentred() {
        launchApp(seed: .demoApps)
        openSettings()

        XCTAssertTrue(appRow("Corevault").waitForExistence(timeout: 20))
        XCTAssertGreaterThan(
            appRow("Corevault").frame.minY,
            appRow("Scanpoint").frame.minY,
            "Corevault starts below Scanpoint"
        )

        // Corevault is last in the demo set; walk it up one place.
        tapRowMenuItem(row: "Corevault", item: "settings.row.moveUp.Corevault", titled: "Move Up")

        XCTAssertTrue(appRow("Corevault").waitForExistence(timeout: 20))
        XCTAssertLessThan(
            appRow("Corevault").frame.minY,
            appRow("Scanpoint").frame.minY,
            "Corevault should now sit above Scanpoint"
        )

        closeSettings()

        // Reordering must not disturb which app is centred.
        XCTAssertTrue(selectedAppName.waitForExistence(timeout: 20))
        XCTAssertEqual(selectedAppName.label, "Tagfield")
    }

    func testDeletingTheCentredAppSelectsItsNeighbour() {
        launchApp(seed: .demoApps)
        XCTAssertTrue(selectedAppName.waitForExistence(timeout: 20))
        XCTAssertEqual(selectedAppName.label, "Tagfield")

        openSettings()
        tapRowMenuItem(row: "Tagfield", item: "settings.row.delete.Tagfield", titled: "Delete")

        let confirm = app.alerts.buttons["Delete"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "Deleting should ask for confirmation")
        confirm.tap()

        XCTAssertFalse(appRow("Tagfield").waitForExistence(timeout: 3))
        closeSettings()

        XCTAssertTrue(selectedAppName.waitForExistence(timeout: 20))
        XCTAssertEqual(selectedAppName.label, "Scanpoint", "The slot the deleted app occupied should take over")
    }

    func testRemoveAllAppsReturnsToTheEmptyState() {
        launchApp(seed: .demoApps)
        openSettings()

        revealInSettings("settings.removeAllApps").tap()
        let confirm = app.alerts.buttons["Remove All"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        confirm.tap()

        closeSettings()
        XCTAssertTrue(emptyState.waitForExistence(timeout: 20))
    }

    func testRestoreDemoAppsRepopulatesTheLauncher() {
        launchApp(seed: .empty)
        openSettings()

        revealInSettings("settings.restoreDemoApps").tap()

        XCTAssertTrue(appRow("Tagfield").waitForExistence(timeout: 20))
        closeSettings()
        XCTAssertTrue(selectedAppName.waitForExistence(timeout: 20))
        XCTAssertEqual(selectedAppName.label, "Tagfield")
    }
}
