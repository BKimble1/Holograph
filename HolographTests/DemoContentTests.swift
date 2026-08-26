import XCTest
@testable import Holograph

final class DemoContentTests: XCTestCase {
    func testThereAreFiveDemoBlueprints() {
        XCTAssertEqual(DemoContent.blueprints.count, 5)
        XCTAssertEqual(
            Set(DemoContent.blueprints.map(\.artwork)),
            Set(DemoIconArtwork.allCases)
        )
    }

    func testTheEquipmentTagSitsInTheMiddleOfTheCarousel() {
        XCTAssertEqual(DemoContent.blueprints[2].artwork, .equipmentTag)
    }

    func testDemoSchemesAreObviouslyPlaceholdersAndUnique() {
        let schemes = DemoContent.blueprints.map(\.scheme)
        XCTAssertEqual(Set(schemes).count, schemes.count)
        for scheme in schemes {
            XCTAssertTrue(scheme.hasPrefix("idlery-demo-"), "\(scheme) should be an obvious placeholder")
            XCTAssertTrue(LaunchURLValidator.isValidScheme(scheme))
        }
    }

    func testEveryDemoDraftIsFlaggedAsADemoAndHasAValidLink() {
        let drafts = DemoContent.draftsWithoutIcons()

        XCTAssertEqual(drafts.count, 5)
        for draft in drafts {
            XCTAssertTrue(draft.isDemo)
            XCTAssertFalse(draft.name.isEmpty)
            guard let launchURL = draft.launchURL,
                  case .success = LaunchURLValidator.validate(launchURL.absoluteString) else {
                return XCTFail("\(String(describing: draft.launchURL)) should be a valid launch link")
            }
        }
    }

    func testPreviewItemsMirrorTheDemoSet() {
        let items = LauncherItem.previewItems()

        XCTAssertEqual(items.count, 5)
        XCTAssertEqual(items.map(\.sortOrder), [0, 1, 2, 3, 4])
        XCTAssertTrue(items.allSatisfy(\.isDemo))
    }
}

final class LaunchEnvironmentTests: XCTestCase {
    func testDefaultsToTheProductionConfiguration() {
        let environment = LaunchEnvironment.make(from: ["/path/to/app"])

        XCTAssertEqual(environment.store, .persistent)
        XCTAssertEqual(environment.seed, .untouched)
        XCTAssertEqual(environment.launcher, .system)
        XCTAssertFalse(environment.animationsDisabled)
        XCTAssertFalse(environment.isUITesting)
    }

    func testReadsEveryDeterministicSwitch() {
        let environment = LaunchEnvironment.make(from: [
            LaunchEnvironment.Argument.uiTesting,
            LaunchEnvironment.Argument.inMemoryStore,
            LaunchEnvironment.Argument.seedDemoApps,
            LaunchEnvironment.Argument.disableAnimations,
            LaunchEnvironment.Argument.mockLaunchFailure
        ])

        XCTAssertTrue(environment.isUITesting)
        XCTAssertEqual(environment.store, .inMemory)
        XCTAssertEqual(environment.seed, .demoApps)
        XCTAssertTrue(environment.animationsDisabled)
        XCTAssertEqual(environment.launcher, .stubbedFailure)
    }

    func testEmptySeedAndSuccessfulLaunchStub() {
        let environment = LaunchEnvironment.make(from: [
            LaunchEnvironment.Argument.seedEmpty,
            LaunchEnvironment.Argument.mockLaunchSuccess
        ])

        XCTAssertEqual(environment.seed, .empty)
        XCTAssertEqual(environment.launcher, .stubbedSuccess)
    }
}

@MainActor
final class HoloMotionTests: XCTestCase {
    func testContinuousEffectsStopWhenTheSceneIsNotActive() {
        let motion = HoloMotion()
        XCTAssertTrue(motion.runsContinuousEffects)

        motion.isSceneActive = false

        XCTAssertFalse(motion.runsContinuousEffects)
        XCTAssertTrue(motion.timelinePaused)
    }

    func testReduceMotionStopsContinuousEffectsAndDepth() {
        let motion = HoloMotion()
        motion.prefersReducedMotion = true

        XCTAssertFalse(motion.runsContinuousEffects)
        XCTAssertFalse(motion.appliesDepthEffects)
        XCTAssertEqual(motion.transition, HoloTheme.reducedMotionAnimation)
    }

    func testTestingModeCollapsesTheLaunchCeremony() {
        let motion = HoloMotion(isDisabledForTesting: true)

        XCTAssertFalse(motion.runsContinuousEffects)
        XCTAssertEqual(motion.launchCeremonyDuration, .milliseconds(1))
    }

    func testReduceMotionShortensButKeepsTheCeremony() {
        let motion = HoloMotion()
        motion.prefersReducedMotion = true

        XCTAssertEqual(motion.launchCeremonyDuration, .milliseconds(140))
    }
}
