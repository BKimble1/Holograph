import XCTest
@testable import Holograph

@MainActor
final class LauncherViewModelTests: XCTestCase {
    private struct Harness {
        let model: LauncherViewModel
        let repository: InMemoryLauncherRepository
        let launcher: StubAppLauncher
        let feedback: SilentFeedback
        let sound: SilentSound
        let selectionStore: InMemorySelectionStore
        let motion: HoloMotion
    }

    private func makeHarness(
        items: [LauncherItem] = [],
        launchSucceeds: Bool = true,
        rememberedSelection: UUID? = nil
    ) -> Harness {
        let repository = InMemoryLauncherRepository(items: items)
        let launcher = StubAppLauncher(outcome: launchSucceeds)
        let feedback = SilentFeedback()
        let sound = SilentSound()
        let selectionStore = InMemorySelectionStore(stored: rememberedSelection)
        // Testing mode collapses the launch ceremony to a single millisecond.
        let motion = HoloMotion(isDisabledForTesting: true)
        let model = LauncherViewModel(
            repository: repository,
            launcher: launcher,
            feedback: feedback,
            sound: sound,
            selectionStore: selectionStore,
            motion: motion
        )
        return Harness(
            model: model,
            repository: repository,
            launcher: launcher,
            feedback: feedback,
            sound: sound,
            selectionStore: selectionStore,
            motion: motion
        )
    }

    private func fiveItems() -> [LauncherItem] {
        ["Alpha", "Bravo", "Charlie", "Delta", "Echo"].enumerated().map { index, name in
            TestFixtures.item(name: name, sortOrder: index)
        }
    }

    // MARK: - Loading and selection

    func testLoadSelectsTheMiddleItemOnAFreshLibrary() {
        let harness = makeHarness(items: fiveItems())
        harness.model.load()

        XCTAssertEqual(harness.model.items.count, 5)
        XCTAssertEqual(harness.model.selectedItem?.name, "Charlie")
        XCTAssertEqual(harness.model.selectedIndex, 2)
    }

    func testLoadRestoresARememberedSelection() {
        let items = fiveItems()
        let harness = makeHarness(items: items, rememberedSelection: items[4].id)
        harness.model.load()

        XCTAssertEqual(harness.model.selectedItem?.name, "Echo")
    }

    func testLoadIgnoresARememberedSelectionThatNoLongerExists() {
        let harness = makeHarness(items: fiveItems(), rememberedSelection: UUID())
        harness.model.load()

        XCTAssertEqual(harness.model.selectedItem?.name, "Charlie")
    }

    func testSelectionIsWrittenThroughToTheStore() {
        let harness = makeHarness(items: fiveItems())
        harness.model.load()

        let target = harness.model.items[0].id
        harness.model.select(target)

        XCTAssertEqual(harness.selectionStore.loadSelection(), target)
    }

    func testSelectIgnoresUnknownIdentifiers() {
        let harness = makeHarness(items: fiveItems())
        harness.model.load()
        let before = harness.model.selectedID

        harness.model.select(UUID())

        XCTAssertEqual(harness.model.selectedID, before)
    }

    func testNextAndPreviousStopAtTheEnds() {
        let harness = makeHarness(items: fiveItems())
        harness.model.load()

        harness.model.select(harness.model.items[0].id)
        harness.model.selectPrevious()
        XCTAssertEqual(harness.model.selectedIndex, 0)

        harness.model.selectNext()
        XCTAssertEqual(harness.model.selectedIndex, 1)

        harness.model.select(harness.model.items[4].id)
        harness.model.selectNext()
        XCTAssertEqual(harness.model.selectedIndex, 4)
    }

    // MARK: - Empty state

    func testEmptyLibraryHasNoSelection() {
        let harness = makeHarness()
        harness.model.load()

        XCTAssertTrue(harness.model.isEmpty)
        XCTAssertNil(harness.model.selectedID)
        XCTAssertNil(harness.model.selectedItem)
    }

    func testRemovingEveryAppReturnsToTheEmptyState() {
        let harness = makeHarness(items: fiveItems())
        harness.model.load()

        harness.model.removeAll()

        XCTAssertTrue(harness.model.isEmpty)
        XCTAssertNil(harness.model.selectedID)
    }

    func testAddingToAnEmptyLibrarySelectsTheNewApp() {
        let harness = makeHarness()
        harness.model.load()

        harness.model.add(TestFixtures.draft(name: "First"))

        XCTAssertEqual(harness.model.items.count, 1)
        XCTAssertEqual(harness.model.selectedItem?.name, "First")
    }

    // MARK: - Selection after deletion

    func testDeletingTheSelectedAppSelectsWhateverTakesItsPlace() throws {
        let harness = makeHarness(items: fiveItems())
        harness.model.load()
        XCTAssertEqual(harness.model.selectedItem?.name, "Charlie")

        harness.model.delete(id: try XCTUnwrap(harness.model.selectedID))

        XCTAssertEqual(harness.model.items.map(\.name), ["Alpha", "Bravo", "Delta", "Echo"])
        XCTAssertEqual(harness.model.selectedItem?.name, "Delta")
        XCTAssertEqual(harness.model.selectedIndex, 2)
    }

    func testDeletingTheLastAppSelectsTheNewLastApp() throws {
        let harness = makeHarness(items: fiveItems())
        harness.model.load()
        harness.model.select(harness.model.items[4].id)

        harness.model.delete(id: try XCTUnwrap(harness.model.selectedID))

        XCTAssertEqual(harness.model.selectedItem?.name, "Delta")
        XCTAssertEqual(harness.model.selectedIndex, 3)
    }

    func testDeletingAnUnselectedAppKeepsTheSelection() {
        let harness = makeHarness(items: fiveItems())
        harness.model.load()
        let selected = harness.model.selectedID

        harness.model.delete(id: harness.model.items[0].id)

        XCTAssertEqual(harness.model.selectedID, selected)
        XCTAssertEqual(harness.model.selectedItem?.name, "Charlie")
    }

    func testDeletingTheOnlyAppClearsTheSelection() throws {
        let harness = makeHarness(items: [TestFixtures.item(name: "Solo")])
        harness.model.load()

        harness.model.delete(id: try XCTUnwrap(harness.model.selectedID))

        XCTAssertNil(harness.model.selectedID)
        XCTAssertTrue(harness.model.isEmpty)
    }

    // MARK: - Reordering

    func testMoveKeepsTheSameAppSelected() {
        let harness = makeHarness(items: fiveItems())
        harness.model.load()
        let selected = harness.model.selectedID

        harness.model.move(fromOffsets: IndexSet(integer: 4), toOffset: 0)

        XCTAssertEqual(harness.model.items.map(\.name), ["Echo", "Alpha", "Bravo", "Charlie", "Delta"])
        XCTAssertEqual(harness.model.selectedID, selected)
        XCTAssertEqual(harness.model.selectedIndex, 3)
    }

    // MARK: - Launching

    // MARK: - Sound

    func testMovingBetweenAppsTicksOncePerApp() {
        let harness = makeHarness(items: fiveItems())
        harness.model.load()
        XCTAssertEqual(harness.sound.tickCount, 0, "landing on the first app is not a move")

        harness.model.selectNext()
        harness.model.selectNext()
        harness.model.selectPrevious()

        XCTAssertEqual(harness.sound.tickCount, 3)
    }

    func testReselectingTheSameAppDoesNotTick() throws {
        let harness = makeHarness(items: fiveItems())
        harness.model.load()
        let current = try XCTUnwrap(harness.model.selectedID)

        harness.model.select(current)
        harness.model.select(current)

        XCTAssertEqual(harness.sound.tickCount, 0, "a scroll that settles where it began is silent")
    }

    func testLaunchingSpeaksTheAppName() async {
        let harness = makeHarness(items: fiveItems())
        harness.model.load()

        await harness.model.launchSelected()

        XCTAssertEqual(harness.sound.announcements, ["Charlie"])
    }

    func testARefusedLaunchCutsTheAnnouncement() async {
        let harness = makeHarness(items: fiveItems(), launchSucceeds: false)
        harness.model.load()

        await harness.model.launchSelected()

        // It said "Opening Charlie" and then nothing opened; leaving that
        // hanging over the recovery alert would be worse than silence.
        XCTAssertEqual(harness.sound.announcements, ["Charlie"])
        XCTAssertEqual(harness.sound.cancelCount, 1)
    }

    func testCentringASideAppTicksWithoutAnnouncingIt() async {
        let harness = makeHarness(items: fiveItems())
        harness.model.load()
        let neighbour = harness.model.items[0]

        await harness.model.activate(neighbour)

        XCTAssertEqual(harness.sound.tickCount, 1)
        XCTAssertTrue(harness.sound.announcements.isEmpty, "nothing opened, so nothing is announced")
    }

    func testLaunchingTheSelectedAppOpensItsPrimaryLink() async {
        let harness = makeHarness(items: fiveItems())
        harness.model.load()

        await harness.model.launchSelected()

        XCTAssertEqual(harness.launcher.openedURLs.map(\.absoluteString), ["idlery-test-charlie://launch"])
        XCTAssertNil(harness.model.launchFailure)
        XCTAssertEqual(harness.feedback.impactCount, 1)
    }

    func testAFailedLaunchRaisesRecoveryWithoutOpeningAnythingElse() async {
        let harness = makeHarness(items: fiveItems(), launchSucceeds: false)
        harness.model.load()

        await harness.model.launchSelected()

        XCTAssertEqual(harness.launcher.openedURLs.count, 1)
        XCTAssertEqual(harness.model.launchFailure?.item.name, "Charlie")
        XCTAssertEqual(harness.model.launchFailure?.canOfferFallback, false)
        XCTAssertEqual(harness.feedback.failureCount, 1)
    }

    func testFailureOffersAFallbackOnlyWhenOneIsConfigured() async {
        let items = [TestFixtures.item(name: "Solo", fallback: "https://example.com/get")]
        let harness = makeHarness(items: items, launchSucceeds: false)
        harness.model.load()

        await harness.model.launchSelected()

        XCTAssertEqual(harness.model.launchFailure?.canOfferFallback, true)
    }

    func testOpeningTheFallbackUsesTheFallbackURL() async throws {
        let items = [TestFixtures.item(name: "Solo", fallback: "https://example.com/get")]
        let harness = makeHarness(items: items, launchSucceeds: true)
        harness.model.load()
        let item = try XCTUnwrap(harness.model.selectedItem)

        await harness.model.launchFallback(for: item)

        XCTAssertEqual(harness.launcher.openedURLs.map(\.absoluteString), ["https://example.com/get"])
        XCTAssertNil(harness.model.alert)
    }

    func testAFailedFallbackExplainsItself() async throws {
        let items = [TestFixtures.item(name: "Solo", fallback: "https://example.com/get")]
        let harness = makeHarness(items: items, launchSucceeds: false)
        harness.model.load()
        let item = try XCTUnwrap(harness.model.selectedItem)

        await harness.model.launchFallback(for: item)

        XCTAssertEqual(harness.model.alert?.title, "Fallback didn’t open")
    }

    func testFallbackDoesNothingWhenNoneIsConfigured() async throws {
        let harness = makeHarness(items: [TestFixtures.item(name: "Solo")], launchSucceeds: true)
        harness.model.load()
        let item = try XCTUnwrap(harness.model.selectedItem)

        await harness.model.launchFallback(for: item)

        XCTAssertTrue(harness.launcher.openedURLs.isEmpty)
        XCTAssertNotNil(harness.model.alert)
    }

    func testActivatingASideAppCentresItInsteadOfLaunching() async {
        let harness = makeHarness(items: fiveItems())
        harness.model.load()
        let side = harness.model.items[0]

        await harness.model.activate(side)

        XCTAssertEqual(harness.model.selectedID, side.id)
        XCTAssertTrue(harness.launcher.openedURLs.isEmpty)
    }

    func testActivatingTheCentredAppLaunchesIt() async throws {
        let harness = makeHarness(items: fiveItems())
        harness.model.load()
        let centred = try XCTUnwrap(harness.model.selectedItem)

        await harness.model.activate(centred)

        XCTAssertEqual(harness.launcher.openedURLs.map(\.absoluteString), ["idlery-test-charlie://launch"])
    }

    func testTestLaunchReportsTheRealOutcome() async {
        let succeeding = makeHarness(launchSucceeds: true)
        let failing = makeHarness(launchSucceeds: false)
        let url = TestFixtures.placeholderURL

        let opened = await succeeding.model.testLaunch(url)
        let refused = await failing.model.testLaunch(url)

        XCTAssertTrue(opened)
        XCTAssertFalse(refused)
    }

    func testLaunchProgressReturnsToZeroAfterTheCeremony() async {
        let harness = makeHarness(items: fiveItems())
        harness.model.load()

        await harness.model.launchSelected()

        XCTAssertEqual(harness.model.launchProgress, 0, accuracy: 0.0001)
        XCTAssertFalse(harness.model.isLaunching)
    }

    // MARK: - Demo content

    func testRestoringDemoAppsReplacesTheLibraryAndCentresIt() {
        let harness = makeHarness(items: fiveItems())
        harness.model.load()

        harness.model.restoreDemoApps()

        XCTAssertEqual(harness.model.items.count, DemoContent.blueprints.count)
        XCTAssertTrue(harness.model.items.allSatisfy(\.isDemo))
        XCTAssertEqual(harness.model.selectedItem?.name, "Tagfield")
    }
}
