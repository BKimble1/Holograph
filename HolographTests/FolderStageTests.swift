import XCTest
@testable import Holograph

/// Opening a folder happens *over* the wall rather than instead of it, so what
/// matters is that the wall is exactly where it was when the folder closes.
@MainActor
final class FolderStageTests: XCTestCase {
    private func library() -> (folder: LauncherItem, items: [LauncherItem]) {
        let folder = LauncherItem(kind: .folder, name: "Work", sortOrder: 1)
        let items = [
            LauncherItem(kind: .app, name: "Mail", launchURL: URL(string: "mail://x"), sortOrder: 0),
            folder,
            LauncherItem(kind: .app, name: "Slides", launchURL: URL(string: "slides://x"), sortOrder: 2),
            LauncherItem(
                kind: .app, name: "Notes", launchURL: URL(string: "notes://x"),
                parentFolderID: folder.id, sortOrder: 0
            ),
            LauncherItem(
                kind: .website, name: "Idlery", launchURL: URL(string: "https://idlery.com"),
                parentFolderID: folder.id, sortOrder: 1
            ),
        ]
        return (folder, items)
    }

    func testTheWallShowsTheRootUntilAFolderOpens() {
        let (folder, items) = library()
        let harness = LauncherHarness(items: items)
        harness.model.load()

        XCTAssertEqual(
            harness.model.items.map(\.name),
            ["Mail", "Work", "Slides", "Notes", "Idlery"],
            "everything is on the wall, including what is grouped in a folder"
        )

        harness.model.enterFolder(folder.id)
        XCTAssertEqual(harness.model.items.map(\.name), ["Notes", "Idlery"])
        XCTAssertTrue(harness.model.isFolderOpen)
        XCTAssertEqual(harness.model.openFolder?.name, "Work")
    }

    func testClosingPutsTheWallBackWhereItWas() {
        let (folder, items) = library()
        let harness = LauncherHarness(items: items)
        harness.model.load()
        harness.model.select(folder.id)

        harness.model.enterFolder(folder.id)
        harness.model.selectNext()
        harness.model.closeFolder()

        XCTAssertFalse(harness.model.isFolderOpen)
        XCTAssertEqual(harness.model.items.count, 5)
        XCTAssertEqual(harness.model.selectedID, folder.id, "back on the folder it came from")
    }

    func testTappingAFolderOpensItRatherThanLaunchingAnything() async {
        let (folder, items) = library()
        let harness = LauncherHarness(items: items)
        harness.model.load()
        harness.model.select(folder.id)

        await harness.model.launchSelected()

        XCTAssertTrue(harness.model.isFolderOpen)
        XCTAssertEqual(harness.launcher.openedURLs, [], "a folder goes nowhere")
        XCTAssertNil(harness.model.browsing)
        XCTAssertNil(harness.model.launchFailure)
    }

    func testAnAppInsideAFolderStillLeavesHolograph() async {
        let (folder, items) = library()
        let harness = LauncherHarness(items: items)
        harness.model.load()
        harness.model.enterFolder(folder.id)

        let notes = harness.model.items.first { $0.name == "Notes" }!
        harness.model.select(notes.id)
        await harness.model.launchSelected()

        XCTAssertEqual(harness.launcher.openedURLs.map(\.absoluteString), ["notes://x"])
    }

    func testAWebsiteInsideAFolderOpensTheHoloBrowser() async {
        let (folder, items) = library()
        let harness = LauncherHarness(items: items)
        harness.model.load()
        harness.model.enterFolder(folder.id)

        let site = harness.model.items.first { $0.name == "Idlery" }!
        harness.model.select(site.id)
        await harness.model.launchSelected()

        XCTAssertEqual(harness.model.browsing?.item.name, "Idlery")
        XCTAssertEqual(harness.launcher.openedURLs, [], "and it does not leave for Safari")
    }

    func testAnEmptyFolderStillOpens() {
        let empty = LauncherItem(kind: .folder, name: "Later", sortOrder: 0)
        let harness = LauncherHarness(items: [empty])
        harness.model.load()

        harness.model.enterFolder(empty.id)
        XCTAssertTrue(harness.model.isFolderOpen)
        XCTAssertTrue(harness.model.isEmpty)
    }

    func testAFolderDeletedUnderneathClosesItself() {
        let (folder, items) = library()
        let harness = LauncherHarness(items: items)
        harness.model.load()
        harness.model.enterFolder(folder.id)

        harness.model.delete(id: folder.id)

        XCTAssertFalse(harness.model.isFolderOpen)
        // Its members were never off the wall; only the grouping is gone.
        XCTAssertEqual(Set(harness.model.items.map(\.name)), ["Mail", "Slides", "Notes", "Idlery"])
    }

    func testFolderCountsAreReported() {
        let (folder, items) = library()
        let harness = LauncherHarness(items: items)
        harness.model.load()

        XCTAssertEqual(harness.model.itemCount(inFolder: folder.id), 2)
        XCTAssertEqual(harness.model.folderCounts[folder.id], 2)
    }

    func testAddingSomethingToAFolderLeavesItOnTheWall() {
        let (folder, items) = library()
        let harness = LauncherHarness(items: items)
        harness.model.load()
        let mail = harness.model.items.first { $0.name == "Mail" }!

        harness.model.setParent(of: mail.id, to: folder.id)

        XCTAssertTrue(harness.model.items.contains { $0.name == "Mail" }, "still on the wall")
        XCTAssertEqual(harness.model.children(of: folder.id).map(\.name), ["Notes", "Idlery", "Mail"])
        // Re-read rather than reusing the copy taken before the change.
        let updated = harness.model.allItems.first { $0.id == mail.id }!
        XCTAssertEqual(harness.model.folderName(containing: updated), "Work")
    }
}

/// What VoiceOver says about a tile. The kind matters more here than anywhere:
/// nothing else tells the user whether activating it will leave Holograph.
final class TileAccessibilityTests: XCTestCase {
    func testAnAppSaysItIsAnApp() {
        let item = LauncherItem(kind: .app, name: "CoreCredit", launchURL: URL(string: "a://b"))
        XCTAssertEqual(HolographicCarousel.label(for: item, folderCount: 0), "CoreCredit, app")
    }

    func testAWebsiteSaysItIsAWebsite() {
        let item = LauncherItem(kind: .website, name: "GitHub", launchURL: URL(string: "https://github.com"))
        XCTAssertEqual(HolographicCarousel.label(for: item, folderCount: 0), "GitHub, website")
    }

    func testAFolderSaysHowMuchIsInIt() {
        let item = LauncherItem(kind: .folder, name: "Work")
        XCTAssertEqual(HolographicCarousel.label(for: item, folderCount: 4), "Work, folder, 4 items")
        XCTAssertEqual(HolographicCarousel.label(for: item, folderCount: 1), "Work, folder, 1 item")
        XCTAssertEqual(HolographicCarousel.label(for: item, folderCount: 0), "Work, folder, 0 items")
    }

    func testTheHintSaysWhereActivatingWillTakeYou() {
        let app = LauncherItem(kind: .app, name: "Mail", launchURL: URL(string: "a://b"))
        let site = LauncherItem(kind: .website, name: "GitHub", launchURL: URL(string: "https://github.com"))
        let folder = LauncherItem(kind: .folder, name: "Work")

        XCTAssertEqual(HolographicCarousel.hint(for: app), "Opens Mail.")
        XCTAssertEqual(HolographicCarousel.hint(for: site), "Opens GitHub in Holograph.")
        XCTAssertEqual(HolographicCarousel.hint(for: folder), "Opens the Work folder.")
    }
}
