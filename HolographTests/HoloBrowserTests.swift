import XCTest
@testable import Holograph

/// Where a navigation goes. The part of the browser with judgement in it, and
/// the part that decides whether Holograph keeps the user or loses them.
final class HoloBrowserPolicyTests: XCTestCase {
    func testOrdinaryWebNavigationStaysInside() {
        for raw in [
            "https://idlery.com",
            "http://example.com/page",
            "https://example.com/a?b=c#d",
        ] {
            XCTAssertEqual(
                HoloBrowserPolicy.decision(for: URL(string: raw)),
                .allowInHolograph,
                "\(raw) should stay in Holograph"
            )
        }
    }

    func testALinkToAnotherAppIsHandedOver() {
        // Tapping a phone number on a page means what it says; a web view just
        // cannot be the thing that answers it.
        let url = URL(string: "tel:+15551234567")!
        XCTAssertEqual(HoloBrowserPolicy.decision(for: url), .handToSystem(url))

        let mail = URL(string: "mailto:someone@example.com")!
        XCTAssertEqual(HoloBrowserPolicy.decision(for: mail), .handToSystem(mail))
    }

    func testWaysOfRunningSomethingAreBlocked() {
        for raw in [
            "javascript:alert(1)",
            "file:///etc/passwd",
            "data:text/html,<script>x</script>",
        ] {
            XCTAssertEqual(
                HoloBrowserPolicy.decision(for: URL(string: raw)),
                .block,
                "\(raw) should go nowhere"
            )
        }
    }

    func testABlankFrameIsNotADestination() {
        // What a web view opens a new window with. Pushing it at iPadOS would
        // be absurd, and blocking it breaks `target="_blank"`.
        XCTAssertEqual(HoloBrowserPolicy.decision(for: URL(string: "about:blank")), .allowInHolograph)
    }

    func testNothingIsBlocked() {
        XCTAssertEqual(HoloBrowserPolicy.decision(for: nil), .block)
        XCTAssertEqual(HoloBrowserPolicy.decision(for: URL(string: "notaurl")), .block)
    }

    func testTheChromeNamesThePageThenTheSite() {
        XCTAssertEqual(
            HoloBrowserPolicy.title(for: URL(string: "https://idlery.com/x"), pageTitle: "Tools"),
            "Tools"
        )
        XCTAssertEqual(
            HoloBrowserPolicy.title(for: URL(string: "https://www.idlery.com/x"), pageTitle: nil),
            "idlery.com",
            "the www is noise"
        )
        XCTAssertEqual(
            HoloBrowserPolicy.title(for: URL(string: "https://idlery.com"), pageTitle: "   "),
            "idlery.com",
            "a blank page title is no title"
        )
    }
}

@MainActor
final class HoloBrowserModelTests: XCTestCase {
    private let site = LauncherItem(
        kind: .website,
        name: "Idlery",
        launchURL: URL(string: "https://idlery.com")
    )

    func testItStartsWhereTheTileSaid() {
        let model = HoloBrowserModel(item: site, startURL: site.launchURL!)
        XCTAssertEqual(model.currentURL, site.launchURL)
        XCTAssertFalse(model.canGoBack)
        XCTAssertFalse(model.canGoForward)
    }

    func testItFallsBackToTheTileName() {
        // Before a page has loaded there is nothing to take a title from, and
        // an empty bar looks broken.
        let model = HoloBrowserModel(item: site, startURL: URL(string: "https://")!)
        XCTAssertEqual(model.title, "Idlery")
    }

    func testItPrefersThePageTitleOnceThereIsOne() {
        let model = HoloBrowserModel(item: site, startURL: site.launchURL!)
        XCTAssertEqual(model.title, "idlery.com")
        model.pageTitle = "Idlery — Tools"
        XCTAssertEqual(model.title, "Idlery — Tools")
    }

    func testBackAndForwardFollowThePage() {
        let model = HoloBrowserModel(item: site, startURL: site.launchURL!)
        model.canGoBack = true
        XCTAssertTrue(model.canGoBack)
        model.canGoBack = false
        model.canGoForward = true
        XCTAssertTrue(model.canGoForward)
    }
}

/// Browsing is not part of the library, and must never write to it.
@MainActor
final class BrowsingSessionTests: XCTestCase {
    func testOpeningAWebsiteDoesNotTouchTheLibrary() async {
        let harness = LauncherHarness(items: [
            LauncherItem(
                kind: .website,
                name: "Idlery",
                launchURL: URL(string: "https://idlery.com"),
                sortOrder: 0
            )
        ])
        harness.model.load()
        let before = harness.model.allItems

        harness.model.select(before[0].id)
        await harness.model.launchSelected()

        XCTAssertNotNil(harness.model.browsing, "a website opens in Holograph")
        XCTAssertEqual(harness.model.allItems, before, "browsing is not a library change")
        XCTAssertEqual(harness.launcher.openedURLs, [], "and it does not leave for Safari")
    }

    func testClosingReturnsToTheSamePlace() async {
        let harness = LauncherHarness(items: [
            LauncherItem(kind: .app, name: "Mail", launchURL: URL(string: "a://b"), sortOrder: 0),
            LauncherItem(kind: .website, name: "Idlery", launchURL: URL(string: "https://idlery.com"), sortOrder: 1),
        ])
        harness.model.load()
        let website = harness.model.items[1]
        harness.model.select(website.id)

        await harness.model.launchSelected()
        XCTAssertNotNil(harness.model.browsing)

        harness.model.closeBrowser()
        XCTAssertNil(harness.model.browsing)
        XCTAssertEqual(harness.model.selectedID, website.id, "the wall is where it was left")
    }
}
