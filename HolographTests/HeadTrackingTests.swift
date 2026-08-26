import XCTest
@testable import Holograph

/// The parallax maths, with no camera and no face anywhere near it.
///
/// This is the part that decides whether the effect reads as a window or as a
/// wobble, so every one of its behaviours — dead zone, clamp, smoothing,
/// settling — is checked on its own.
final class HeadTrackerTests: XCTestCase {
    private let start: TimeInterval = 100
    private let step: TimeInterval = 1.0 / 30.0

    /// Plays a head held at one position for a while, so the smoothing settles.
    private func settled(
        at x: Double,
        y: Double = 0,
        from origin: (x: Double, y: Double) = (0, 0),
        seconds: TimeInterval = 2.0
    ) -> (tracker: HeadTracker, perspective: HeadPerspective) {
        var tracker = HeadTracker()
        var time = start
        // Where the viewer starts is "straight on", so the origin is
        // established first and the movement measured from it.
        for _ in 0..<20 {
            tracker.headSeen(HeadReading(x: origin.x, y: origin.y, scale: 0.2), at: time)
            time += step
        }
        var perspective = HeadPerspective.neutral
        for _ in 0..<Int(seconds / step) {
            perspective = tracker.headSeen(HeadReading(x: x, y: y, scale: 0.2), at: time)
            time += step
        }
        return (tracker, perspective)
    }

    func testAStillHeadGivesAStillScene() {
        // The most important one: somebody sitting still must not get a scene
        // that trembles.
        let (_, perspective) = settled(at: 0)
        XCTAssertEqual(perspective.x, 0, accuracy: 0.001)
        XCTAssertEqual(perspective.y, 0, accuracy: 0.001)
    }

    func testASmallShiftIsInsideTheDeadZone() {
        // Half a per cent of the frame is somebody breathing.
        let (_, perspective) = settled(at: 0.004)
        XCTAssertEqual(perspective.x, 0, accuracy: 0.001, "the dead zone should absorb this")
    }

    func testAnOrdinaryShiftOfTheHeadIsFeltProperly() {
        // The first device test said the effect was too small to read as depth.
        // The range is what decides that: a shift a person actually makes while
        // looking around their own screen has to reach most of the effect, not
        // a tenth of it.
        let (_, perspective) = settled(at: 0.12)
        XCTAssertGreaterThan(perspective.x, 0.6, "an ordinary lean should be most of the way")
    }

    func testLeaningOneWayMovesTheSceneThatWay() {
        let (_, right) = settled(at: 0.2)
        let (_, left) = settled(at: -0.2)
        XCTAssertGreaterThan(right.x, 0.2)
        XCTAssertLessThan(left.x, -0.2)
    }

    func testTheEffectIsClampedHoweverFarTheHeadGoes() {
        // Somebody walking across the room must not send the scene into orbit.
        for extreme in [0.5, 1.0, 5.0] {
            let (_, perspective) = settled(at: extreme)
            XCTAssertLessThanOrEqual(perspective.x, 1.0, "\(extreme) should still clamp to 1")
            XCTAssertGreaterThanOrEqual(perspective.x, -1.0)
        }
    }

    func testVerticalWorksTheSameWay() {
        let (_, up) = settled(at: 0, y: 0.2)
        XCTAssertGreaterThan(up.y, 0.2)
        XCTAssertLessThanOrEqual(up.y, 1.0)
    }

    func testTheEffectFadesInRatherThanSnapping() {
        var tracker = HeadTracker()
        let first = tracker.headSeen(HeadReading(x: 0.3, y: 0, scale: 0.2), at: start)
        XCTAssertEqual(first.strength, 0, "the very first frame cannot already be at full strength")

        var time = start + step
        var perspective = first
        for _ in 0..<5 {
            perspective = tracker.headSeen(HeadReading(x: 0.3, y: 0, scale: 0.2), at: time)
            time += step
        }
        XCTAssertGreaterThan(perspective.strength, 0)
        XCTAssertLessThan(perspective.strength, 1, "and it should still be arriving")
    }

    func testLosingTheViewerSettlesTheSceneRatherThanFreezingIt() {
        var (tracker, before) = settled(at: 0.3)
        XCTAssertGreaterThan(before.strength, 0.9)

        var time = start + 5
        var after = before
        for _ in 0..<Int(2.0 / step) {
            after = tracker.headLost(at: time)
            time += step
        }
        XCTAssertEqual(after.strength, 0, accuracy: 0.001, "nobody there means straight on")
        XCTAssertEqual(after.offset(depth: 1, travel: 30).width, 0, accuracy: 0.001)
    }

    func testItDoesNotSnapWhenTheViewerLeaves() {
        var (tracker, _) = settled(at: 0.3)
        let immediately = tracker.headLost(at: start + 2.0 + step)
        XCTAssertGreaterThan(immediately.strength, 0.5, "one lost frame is not a reason to lurch")
    }

    func testSittingOffToOneSideIsStillStraightOn() {
        // The origin is where the viewer was when they arrived, not the middle
        // of the camera's frame — somebody using their iPad from an armchair
        // off to one side should get a level scene, not a permanently tilted
        // one.
        let (_, perspective) = settled(at: 0.35, from: (0.35, 0), seconds: 0.5)
        XCTAssertEqual(perspective.x, 0, accuracy: 0.02)
    }

    func testAGapInTheStreamIsNotAMovement() {
        var tracker = HeadTracker()
        var time = start
        for _ in 0..<20 {
            tracker.headSeen(HeadReading(x: 0, y: 0, scale: 0.2), at: time)
            time += step
        }
        // The camera stopped for two seconds; the head did not travel there.
        let after = tracker.headSeen(HeadReading(x: 0.9, y: 0, scale: 0.2), at: time + 2.0)
        XCTAssertEqual(after.x, 0, accuracy: 0.001, "a resumed stream starts again from straight on")
    }

    func testResettingForgetsEverything() {
        var (tracker, _) = settled(at: 0.3)
        tracker.reset()
        XCTAssertEqual(tracker.current, .neutral)
    }

    // MARK: - Shaping

    func testTheResponseStartsFromZeroAtTheEdgeOfTheDeadZone() {
        // A dead zone that simply subtracts leaves a step at its edge, which is
        // exactly the twitchiness it was meant to remove.
        let thresholds = HeadTracker.Thresholds()
        let justInside = HeadTracker.shaped(thresholds.range * thresholds.deadZone * 0.99, thresholds: thresholds)
        let justOutside = HeadTracker.shaped(thresholds.range * thresholds.deadZone * 1.01, thresholds: thresholds)
        XCTAssertEqual(justInside, 0)
        XCTAssertLessThan(justOutside, 0.02, "and it should creep out of it, not jump")
    }

    func testShapingIsSymmetrical() {
        let thresholds = HeadTracker.Thresholds()
        XCTAssertEqual(
            HeadTracker.shaped(0.2, thresholds: thresholds),
            -HeadTracker.shaped(-0.2, thresholds: thresholds),
            accuracy: 0.0001
        )
    }
}

/// How a viewing position becomes movement on screen.
final class HeadPerspectiveTests: XCTestCase {
    func testNearerLayersMoveMoreThanFurtherOnes() {
        // The whole illusion: if everything moved together it would be a
        // sliding picture rather than a window.
        let perspective = HeadPerspective(x: 1, y: 0, strength: 1)
        let near = perspective.offset(depth: 1.0, travel: 30).width
        let far = perspective.offset(depth: 0.3, travel: 30).width
        XCTAssertGreaterThan(near, far)
        XCTAssertEqual(near, 30, accuracy: 0.001)
        XCTAssertEqual(far, 9, accuracy: 0.001)
    }

    func testVerticalMovementIsGentlerThanHorizontal() {
        // Heads move side to side far more than up and down, and matching the
        // two makes the vertical feel exaggerated.
        let perspective = HeadPerspective(x: 1, y: 1, strength: 1)
        let offset = perspective.offset(depth: 1, travel: 30)
        XCTAssertLessThan(offset.height, offset.width)
    }

    func testStrengthScalesEverything() {
        let half = HeadPerspective(x: 1, y: 0, strength: 0.5)
        XCTAssertEqual(half.offset(depth: 1, travel: 30).width, 15, accuracy: 0.001)
        XCTAssertEqual(half.rotation(maximum: 4), 2, accuracy: 0.001)
    }

    func testNeutralMovesNothing() {
        XCTAssertEqual(HeadPerspective.neutral.offset(depth: 1, travel: 40), .zero)
        XCTAssertEqual(HeadPerspective.neutral.rotation(maximum: 10), 0)
    }
}

/// Reduce Motion, and the test harness, both go through `HoloMotion`.
@MainActor
final class HeadTrackingMotionTests: XCTestCase {
    func testFullMovementByDefault() {
        XCTAssertEqual(HoloMotion().headParallaxScale, 1)
    }

    func testReduceMotionKeepsTheDepthAndLosesMostOfTheTravel() {
        let motion = HoloMotion()
        motion.prefersReducedMotion = true
        XCTAssertEqual(motion.headParallaxScale, 0.25)
    }

    func testTestsGetNoneOfIt() {
        // Screenshots must not depend on whether a face happened to be in front
        // of the runner.
        XCTAssertEqual(HoloMotion(isDisabledForTesting: true).headParallaxScale, 0)
    }
}

@MainActor
final class HeadTrackingPreferenceTests: XCTestCase {
    private let defaults = UserDefaults.standard
    private var saved: Any?

    override func setUp() {
        super.setUp()
        saved = defaults.object(forKey: HeadTrackingPreferences.enabledKey)
        defaults.removeObject(forKey: HeadTrackingPreferences.enabledKey)
    }

    override func tearDown() {
        if let saved {
            defaults.set(saved, forKey: HeadTrackingPreferences.enabledKey)
        } else {
            defaults.removeObject(forKey: HeadTrackingPreferences.enabledKey)
        }
        super.tearDown()
    }

    func testItIsOffUntilItIsAskedFor() {
        XCTAssertFalse(HeadTrackingPreferences.isEnabled)
    }

    func testItIsItsOwnSwitch() {
        // Sharing a camera must not mean sharing a switch: somebody may want
        // depth without gestures, or the other way round.
        XCTAssertNotEqual(HeadTrackingPreferences.enabledKey, AirGesturePreferences.enabledKey)
    }

    func testTheStubReportsWhatTheLauncherAskedItToDo() {
        let source = InertHeadTrackingSource()
        var seen: [HeadPerspective] = []
        source.onPerspective = { seen.append($0) }

        source.start()
        source.emit(HeadPerspective(x: 0.4, y: 0, strength: 1))
        source.stop()

        XCTAssertEqual(seen.count, 1)
        XCTAssertEqual(source.startCount, 1)
        XCTAssertEqual(source.stopCount, 1)
        XCTAssertFalse(source.isWatching)
    }
}
