import XCTest
@testable import Holograph

/// The gesture logic is a value type over plain numbers, so a hand can be played
/// through it frame by frame — no camera, no hand, no running app.
///
/// Distances are written in inches and converted, because inches are what the
/// gesture was asked for in. A hand is about three inches across the knuckles,
/// and every threshold is in those spans, so the same flick works at any
/// distance from the screen.
///
/// Readings carry the landmark noise a real camera produces. A test on a clean
/// signal proves nothing about a gesture whose whole difficulty is noise.
final class AirGestureDetectorTests: XCTestCase {
    /// A hand a foot or two away, in frame units.
    private static let span = 0.24
    private static let inch = span / 3.0
    private static let frameRate = 18.0

    /// Fingertip spreads a real hand reads at, in spans. Pinched fingertips sit
    /// about this far from their own centre; a splayed hand about 0.69.
    private static let pinched = 0.13
    private static let openHand = 0.45

    /// Plays a hand through the detector, carrying position and time forward the
    /// way a real one does, and jittering every reading.
    private struct Hand {
        var detector = AirGestureDetector()
        var fired: [AirGesture] = []

        private var x = 0.0
        private var time: TimeInterval = 100
        private var noise: SeededNoise
        private let spanNoise: Double
        private let positionNoise: Double

        init(seed: UInt64 = 1, spanNoise: Double = 0.06, positionNoise: Double = 0.3) {
            noise = SeededNoise(seed: seed)
            self.spanNoise = spanNoise
            self.positionNoise = positionNoise
            // The hand is in frame, and still, before it does anything.
            rest(for: 0.3)
        }

        mutating func move(
            _ inches: Double,
            over duration: TimeInterval,
            spread: Double? = AirGestureDetectorTests.openHand
        ) {
            let steps = max(1, Int((duration * AirGestureDetectorTests.frameRate).rounded()))
            let start = x
            for step in 1...steps {
                x = start + inches * AirGestureDetectorTests.inch * (Double(step) / Double(steps))
                time += duration / Double(steps)
                let reading = HandReading(
                    x: x + noise.next(spread: positionNoise) * AirGestureDetectorTests.inch,
                    span: AirGestureDetectorTests.span * (1 + noise.next(spread: spanNoise)),
                    spread: spread
                )
                if let gesture = detector.handSeen(reading, time: time) { fired.append(gesture) }
            }
        }

        mutating func rest(
            for duration: TimeInterval,
            spread: Double? = AirGestureDetectorTests.openHand
        ) {
            move(0, over: duration, spread: spread)
        }

        /// Brings the fingertips together and holds long enough for the drag to
        /// take hold.
        mutating func pinch() {
            rest(for: 0.25, spread: AirGestureDetectorTests.pinched)
        }

        /// Moves with the fingers still together.
        mutating func sweep(_ inches: Double, over duration: TimeInterval) {
            move(inches, over: duration, spread: AirGestureDetectorTests.pinched)
        }

        /// Opens the hand again.
        mutating func release() {
            rest(for: 0.2, spread: 0.66)
        }
    }

    /// Deterministic jitter: the same run every time, or a failure means nothing.
    private struct SeededNoise {
        private var state: UInt64
        init(seed: UInt64) { state = seed }

        mutating func next(spread: Double) -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let unit = Double(state >> 11) / Double(1 << 53)
            return (unit * 2 - 1) * spread
        }
    }

    // MARK: - Which way the wall goes

    func testTheWallFollowsTheHand() {
        // Sweep left and the apps travel left, so the next one arrives from the
        // right — the same way a swipe on glass behaves.
        XCTAssertEqual(AirSwipe.left.selectionStep, 1)
        XCTAssertEqual(AirSwipe.right.selectionStep, -1)
    }

    func testAFlickAndADragAgreeOnDirection() {
        // One mapping, used by both, so they can never drift apart.
        XCTAssertEqual(AirGesture.swipe(.left).selectionStep, AirGesture.drag(.left).selectionStep)
        XCTAssertEqual(AirGesture.swipe(.right).selectionStep, AirGesture.drag(.right).selectionStep)
    }

    // MARK: - Flicks that should register

    func testFlicksOfEverySizeRegister() {
        // The complaint was that it rarely moved. Everything from a short flick
        // to a full arm sweep has to work. These sizes were each measured over
        // two hundred noise realisations before being written down here.
        for (inches, duration) in [(3.0, 0.25), (4.0, 0.30), (6.0, 0.30), (10.0, 0.40), (16.0, 0.60)] {
            var hand = Hand()
            hand.move(inches, over: duration)
            XCTAssertEqual(
                hand.fired, [.swipe(.right)],
                "a \(inches)in flick over \(duration)s should move exactly one app"
            )
        }
    }

    func testAFlickWorksWhenTheFingertipsCannotBeSeen() {
        // A hand mid-flick is motion-blurred and its fingertips drop below
        // confidence, so the camera reports no spread at all.
        var hand = Hand()
        hand.move(6, over: 0.30, spread: nil)
        XCTAssertEqual(hand.fired, [.swipe(.right)])
    }

    func testAFlickToTheLeftGoesLeft() {
        var hand = Hand()
        hand.move(-6, over: 0.30)
        XCTAssertEqual(hand.fired, [.swipe(.left)])
    }

    func testAFlickWithALooselyClosedHandIsStillAFlick() {
        // Not everyone flicks with an open palm, and a half-closed hand must not
        // be mistaken for the pinch that starts a drag.
        var hand = Hand()
        hand.move(6, over: 0.30, spread: 0.30)
        XCTAssertEqual(hand.fired, [.swipe(.right)])
    }

    // MARK: - Exactly once

    /// The complaint: one flick moving two apps.
    func testOneFlickMovesExactlyOneApp() {
        for (inches, duration) in [(8.0, 0.35), (12.0, 0.45), (16.0, 0.60), (20.0, 0.80)] {
            var hand = Hand()
            hand.move(inches, over: duration)
            XCTAssertEqual(
                hand.fired.count, 1,
                "a \(inches)in sweep should still be one gesture, not several"
            )
        }
    }

    func testTheHandComingStraightBackDoesNotUndoTheSwipe() {
        var hand = Hand()
        hand.move(8, over: 0.30)
        hand.move(-8, over: 0.35)
        XCTAssertEqual(hand.fired, [.swipe(.right)], "the journey back is not a gesture")
    }

    func testAContinuousSweepIsStillOneGesture() {
        // Delivered as three segments, but the hand never stops, so it is one
        // movement and should be one gesture.
        var hand = Hand()
        hand.move(5, over: 0.15)
        hand.move(5, over: 0.15)
        hand.move(5, over: 0.15)
        XCTAssertEqual(hand.fired.count, 1)
    }

    // MARK: - The settling pause

    func testASecondFlickTooSoonIsIgnored() {
        // The pause is the point: it is there so the hand can be brought back
        // and set up again without any of that counting.
        var hand = Hand()
        hand.move(6, over: 0.30)
        hand.rest(for: 0.4)
        hand.move(6, over: 0.30)
        XCTAssertEqual(hand.fired, [.swipe(.right)])
    }

    func testFlickingAgainAfterTheSettlingPauseWorks() {
        var hand = Hand()
        hand.move(6, over: 0.30)
        hand.rest(for: 1.25)
        hand.move(6, over: 0.30)
        XCTAssertEqual(hand.fired, [.swipe(.right), .swipe(.right)])
    }

    func testTheReturnStrokeCountsTowardsTheSettlingPause() {
        // The pause runs from the flick, not from the moment the hand stops, so
        // bringing it back is not dead time on top of the wait.
        var hand = Hand()
        hand.move(6, over: 0.30)
        hand.move(-6, over: 0.35)
        hand.rest(for: 0.9)
        hand.move(6, over: 0.30)
        XCTAssertEqual(hand.fired, [.swipe(.right), .swipe(.right)])
    }

    func testReversingAfterTheSettlingPauseWorks() {
        var hand = Hand()
        hand.move(6, over: 0.30)
        hand.rest(for: 1.25)
        hand.move(-6, over: 0.30)
        XCTAssertEqual(hand.fired, [.swipe(.right), .swipe(.left)])
    }

    func testThreeFlicksInARowMoveThree() {
        var hand = Hand()
        for _ in 0..<3 {
            hand.move(6, over: 0.30)
            hand.rest(for: 1.25)
        }
        XCTAssertEqual(hand.fired.count, 3)
    }

    func testTheDefaultPauseIsLongEnoughToRepositionAndShortEnoughToUse() {
        let settle = AirGestureDetector.Thresholds.default.settleAfterSwipe
        XCTAssertGreaterThan(settle, 0.8, "a return stroke and a breath take about this long")
        XCTAssertLessThanOrEqual(settle, 1.5, "beyond this the launcher feels stuck")
    }

    // MARK: - Silence

    func testASmallNudgeIsNotAFlick() {
        var hand = Hand()
        hand.move(1.5, over: 0.25)
        XCTAssertTrue(hand.fired.isEmpty)
    }

    func testMovingSlowlyIsNotAFlick() {
        var hand = Hand()
        // Far enough, but taken at a stroll — someone reaching past the iPad.
        hand.move(4, over: 1.4)
        XCTAssertTrue(hand.fired.isEmpty)
    }

    func testAStillHandNeverFires() {
        var hand = Hand()
        hand.rest(for: 4.0)
        XCTAssertTrue(hand.fired.isEmpty)
    }

    /// Landmark noise used to be enough on its own: dividing position by a
    /// per-frame span estimate turned an eight per cent wobble in the scale into
    /// half a span of movement on a hand that was not moving.
    func testAStillHandNeverFiresEvenWhenTheReadingsAreBad() {
        var hand = Hand(spanNoise: 0.12, positionNoise: 0.6)
        hand.rest(for: 4.0)
        XCTAssertTrue(hand.fired.isEmpty, "noise is not motion")
    }

    func testWavingIsNotFlicking() {
        // This is the case that sets how loose the travel threshold can be: it
        // is the first thing to start registering as the bar comes down, which
        // is why the bar sits where it does.
        var hand = Hand()
        for _ in 0..<2 {
            hand.move(2, over: 0.15)
            hand.move(-2, over: 0.15)
        }
        XCTAssertTrue(hand.fired.isEmpty)
    }

    func testAHandLeavingTheFrameAbandonsThePath() {
        var hand = Hand()
        hand.move(2, over: 0.12)
        hand.detector.handLost()
        XCTAssertFalse(hand.detector.isMidStroke)
    }

    func testFramesArrivingOutOfOrderAreIgnored() {
        var detector = AirGestureDetector()
        _ = detector.handSeen(HandReading(x: 0.30, span: 0.24), time: 100)
        _ = detector.handSeen(HandReading(x: 0.34, span: 0.24), time: 100.06)
        XCTAssertNil(
            detector.handSeen(HandReading(x: 0.90, span: 0.24), time: 99.9),
            "a stale frame is not new information"
        )
    }

    // MARK: - Pinch to drag

    func testPinchedFingersDragTheWallAlong() {
        // Six inches of hand is about three apps, so a foot is six — and the
        // count is what makes this feel like carrying the wall rather than
        // nudging it.
        var hand = Hand()
        hand.pinch()
        hand.sweep(12, over: 1.5)
        XCTAssertEqual(hand.fired, Array(repeating: .drag(.right), count: 6))
    }

    func testDraggingTheOtherWayGoesTheOtherWay() {
        var hand = Hand()
        hand.pinch()
        hand.sweep(-12, over: 1.5)
        XCTAssertEqual(hand.fired, Array(repeating: .drag(.left), count: 6))
    }

    func testADragCanChangeItsMindWithoutLettingGo() {
        var hand = Hand()
        hand.pinch()
        hand.sweep(6, over: 0.8)
        hand.sweep(-6, over: 0.8)
        XCTAssertEqual(hand.fired.filter { $0 == .drag(.right) }.count, 3)
        XCTAssertGreaterThanOrEqual(hand.fired.filter { $0 == .drag(.left) }.count, 2)
    }

    func testADragIsNotSubjectToTheSettlingPause() {
        // The pause exists so a flick can be repeated deliberately. A drag is
        // one continuous movement, and pausing it would make it useless.
        var hand = Hand()
        hand.pinch()
        hand.sweep(12, over: 1.5)
        XCTAssertGreaterThan(hand.fired.count, 1)
    }

    func testAPinchedHandHeldStillMovesNothing() {
        var hand = Hand()
        hand.pinch()
        hand.rest(for: 3.0, spread: Self.pinched)
        XCTAssertTrue(hand.fired.isEmpty, "holding on is not moving")
    }

    func testLettingGoEndsTheDrag() {
        var hand = Hand()
        hand.pinch()
        hand.sweep(6, over: 0.8)
        let duringDrag = hand.fired.count
        hand.release()
        hand.move(6, over: 0.8, spread: 0.66)
        XCTAssertEqual(
            hand.fired.filter { if case .drag = $0 { return true } else { return false } }.count,
            duringDrag,
            "an open hand moving is not still dragging"
        )
    }

    func testAnOpenHandNeverStartsADrag() {
        var hand = Hand()
        hand.rest(for: 0.5)
        hand.move(12, over: 1.5)
        XCTAssertFalse(hand.detector.isDragging)
    }

    func testAPinchCannotTakeOverPartWayThroughAFlick() {
        // Fingers already together while flicking used to hand out the flick's
        // own remaining travel as a drag notch — one flick, two apps.
        var hand = Hand()
        hand.move(6, over: 0.30, spread: Self.pinched)
        hand.rest(for: 0.6, spread: Self.pinched)
        XCTAssertEqual(hand.fired, [.swipe(.right)])
    }

    func testAHandLeavingTheFrameLetsGo() {
        var hand = Hand()
        hand.pinch()
        hand.sweep(3, over: 0.4)
        hand.detector.handLost()
        XCTAssertFalse(hand.detector.isDragging)
    }

    func testAPinchSurvivesFingertipsThatCannotBeSeen() {
        // A pinched hand in motion is blurred and its fingertips are the first
        // landmarks to go. Losing them must not be read as letting go.
        var hand = Hand()
        hand.pinch()
        hand.sweep(3, over: 0.4)
        hand.move(6, over: 0.7, spread: nil)
        XCTAssertTrue(hand.detector.isDragging)
        XCTAssertGreaterThanOrEqual(hand.fired.count, 3)
    }

    // MARK: - Wiring

    @MainActor
    func testTheStubReportsWhatTheLauncherAskedItToDo() {
        let source = InertAirGestureSource()
        var seen: [AirGesture] = []
        source.onGesture = { seen.append($0) }

        source.start()
        source.emit(.swipe(.left))
        source.emit(.drag(.right))
        source.stop()

        XCTAssertEqual(seen, [.swipe(.left), .drag(.right)])
        XCTAssertEqual(source.startCount, 1)
        XCTAssertEqual(source.stopCount, 1)
        XCTAssertFalse(source.isWatching)
    }
}

/// The smoothing is the reason a noisy hand does not read as a moving one, so
/// its two defining behaviours are checked directly.
final class OneEuroFilterTests: XCTestCase {
    func testItHoldsSteadyThroughJitter() {
        var filter = OneEuroFilter()
        var input: [Double] = []
        var output: [Double] = []
        var state: UInt64 = 42
        for step in 0..<60 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let jitter = (Double(state >> 11) / Double(1 << 53) * 2 - 1) * 0.04
            input.append(jitter)
            output.append(filter.apply(jitter, at: 100 + Double(step) / 18))
        }
        let before = (input.max() ?? 0) - (input.min() ?? 0)
        let after = (output.max() ?? 0) - (output.min() ?? 0)

        // Measured against what went in, rather than a number picked out of the
        // air — the claim is that it takes the jitter out, not that it lands
        // under some particular figure.
        XCTAssertLessThan(after, before * 0.8, "a still signal should come out steadier")
    }

    func testItKeepsUpWithRealMovement() {
        var filter = OneEuroFilter()
        var smoothed: [Double] = []
        let steps = 6
        for step in 0...steps {
            let value = Double(step) / Double(steps)
            smoothed.append(filter.apply(value, at: 100 + 0.30 * Double(step) / Double(steps)))
        }
        let kept = (smoothed.last ?? 0) - (smoothed.first ?? 0)
        // Lag here is displacement the gesture never gets credit for, so the
        // filter has to give most of it back.
        XCTAssertGreaterThan(kept, 0.8, "smoothing must not swallow the movement")
    }

    func testResettingForgetsEverything() {
        var filter = OneEuroFilter()
        _ = filter.apply(5, at: 100)
        filter.reset()
        // The first sample after a reset is passed straight through, so a hand
        // reappearing elsewhere does not read as having travelled there.
        XCTAssertEqual(filter.apply(0, at: 101), 0)
    }
}

final class AirGesturePreferencesTests: XCTestCase {
    private let defaults = UserDefaults.standard
    private var saved: Any?

    override func setUp() {
        super.setUp()
        saved = defaults.object(forKey: AirGesturePreferences.enabledKey)
        defaults.removeObject(forKey: AirGesturePreferences.enabledKey)
    }

    override func tearDown() {
        if let saved {
            defaults.set(saved, forKey: AirGesturePreferences.enabledKey)
        } else {
            defaults.removeObject(forKey: AirGesturePreferences.enabledKey)
        }
        super.tearDown()
    }

    func testItIsOffUntilItIsAskedFor() {
        // It runs the camera, so a fresh install must not be watching.
        XCTAssertFalse(AirGesturePreferences.isEnabled)
    }

    func testTurningItOnIsRemembered() {
        defaults.set(true, forKey: AirGesturePreferences.enabledKey)
        XCTAssertTrue(AirGesturePreferences.isEnabled)
    }
}
