import XCTest
@testable import Holograph

/// The gesture logic is a value type over plain numbers, so a hand can be played
/// through it frame by frame — no camera, no hand, no running app.
///
/// Distances are written in inches and converted, because inches are what the
/// gesture was asked for in. A hand is about three inches across the knuckles, and
/// every threshold is in those spans, so the same flick works at any distance
/// from the screen.
final class AirGestureDetectorTests: XCTestCase {
    private let thresholds = AirGestureDetector.Thresholds.default

    /// Knuckle span of an adult hand, the ruler everything is measured against.
    private static let spanInInches = 3.0
    private func spans(_ inches: Double) -> Double { inches / Self.spanInInches }

    /// Plays a hand travelling `inches` at the rate the camera samples.
    @discardableResult
    private func flick(
        _ inches: Double,
        over duration: TimeInterval,
        startingAt origin: TimeInterval = 100,
        from start: Double = 0,
        spread: Double? = 0.2,
        into detector: inout AirGestureDetector
    ) -> [AirGesture] {
        let steps = max(1, Int((duration * 18).rounded()))
        var fired: [AirGesture] = []
        for step in 0...steps {
            let progress = Double(step) / Double(steps)
            let reading = HandReading(x: start + spans(inches) * progress, spread: spread)
            if let gesture = detector.handSeen(reading, time: origin + duration * progress) {
                fired.append(gesture)
            }
        }
        return fired
    }

    // MARK: - Swipes that should register

    func testAFourInchFlickIsASwipe() {
        var detector = AirGestureDetector()
        XCTAssertEqual(flick(4, over: 0.30, into: &detector), [.swipe(.right)])
    }

    func testASixInchFlickIsASwipe() {
        var detector = AirGestureDetector()
        XCTAssertEqual(flick(-6, over: 0.35, from: spans(6), into: &detector), [.swipe(.left)])
    }

    /// A hand mid-flick is motion-blurred and its fingertips drop below
    /// confidence, so the camera reports no spread at all. Swipes must not
    /// depend on it — this is what stopped them registering.
    func testAFlickWorksWhenTheFingertipsCannotBeSeen() {
        var detector = AirGestureDetector()
        XCTAssertEqual(
            flick(5, over: 0.28, spread: nil, into: &detector),
            [.swipe(.right)]
        )
    }

    func testTheSameFlickRepeatedKeepsWorking() {
        var detector = AirGestureDetector()
        XCTAssertEqual(flick(5, over: 0.28, into: &detector), [.swipe(.right)])
        detector.handLost()
        XCTAssertEqual(
            flick(5, over: 0.28, startingAt: 100.75, into: &detector),
            [.swipe(.right)]
        )
    }

    // MARK: - Swipes that should not

    func testATwoInchNudgeIsNotASwipe() {
        var detector = AirGestureDetector()
        XCTAssertTrue(flick(2, over: 0.25, into: &detector).isEmpty)
    }

    func testAFourInchMoveMadeSlowlyIsNotASwipe() {
        var detector = AirGestureDetector()
        // Far enough, but taken at a stroll — someone reaching past the iPad.
        XCTAssertTrue(flick(4, over: 1.2, into: &detector).isEmpty)
    }

    /// The one that mattered: the hand has to come back after a flick, and that
    /// return was being read as a swipe the other way.
    func testTheHandComingStraightBackDoesNotUndoTheSwipe() {
        var detector = AirGestureDetector()
        XCTAssertEqual(flick(6, over: 0.30, into: &detector), [.swipe(.right)])

        // Straight back without pausing, which is what an arm actually does.
        let returning = flick(
            -6, over: 0.30, startingAt: 100.35, from: spans(6), into: &detector
        )
        XCTAssertTrue(returning.isEmpty, "the journey back is not a gesture")
    }

    func testAReverseAfterTheHandRestsIsHeard() {
        var detector = AirGestureDetector()
        XCTAssertEqual(flick(6, over: 0.30, into: &detector), [.swipe(.right)])

        // Held still for a moment — which is what deliberately changing your
        // mind looks like, and what the return stroke never does.
        for step in 0..<5 {
            _ = detector.handSeen(
                HandReading(x: spans(6), spread: nil),
                time: 100.35 + Double(step) * 0.06
            )
        }
        let back = flick(-6, over: 0.30, startingAt: 100.75, from: spans(6), into: &detector)
        XCTAssertEqual(back, [.swipe(.left)], "a considered reverse still counts")
    }

    func testAWanderingPathIsNotASwipeEvenWhenItEndsFarAway() {
        var detector = AirGestureDetector()
        let path: [(x: Double, time: TimeInterval)] = [
            (spans(0), 100.00),
            (spans(6), 100.06),
            (spans(0), 100.12),
            (spans(7), 100.18),
        ]
        let fired = path.compactMap {
            detector.handSeen(HandReading(x: $0.x, spread: nil), time: $0.time)
        }
        XCTAssertTrue(fired.isEmpty, "a swipe is a straight line, not a search")
    }

    func testAHandLeavingTheFrameAbandonsThePath() {
        var detector = AirGestureDetector()
        XCTAssertTrue(flick(2, over: 0.12, into: &detector).isEmpty)

        detector.handLost()
        XCTAssertEqual(detector.sampleCount, 0)

        let fired = flick(1, over: 0.10, startingAt: 100.15, from: spans(9), into: &detector)
        XCTAssertTrue(fired.isEmpty)
    }

    func testFramesArrivingOutOfOrderAreIgnored() {
        var detector = AirGestureDetector()
        _ = detector.handSeen(HandReading(x: 0.3, spread: nil), time: 100)
        _ = detector.handSeen(HandReading(x: 0.6, spread: nil), time: 100.06)
        let before = detector.sampleCount

        XCTAssertNil(
            detector.handSeen(HandReading(x: 4, spread: nil), time: 99.9),
            "a stale frame is not new information"
        )
        XCTAssertEqual(detector.sampleCount, before)
    }

    // MARK: - The burst
    //
    // Spreads here are what a hand actually reads: fingertips pinched together
    // sit about 0.13 spans from their own centre, and a fully splayed hand
    // about 0.69. The first version asked for 1.0, which no hand reaches — so
    // it never fired once.

    /// Fingers gathered in the middle and thrown open, the hand staying put.
    private func burst(
        _ spreads: [Double],
        startingAt origin: TimeInterval = 100,
        step: TimeInterval = 0.06,
        into detector: inout AirGestureDetector
    ) -> [AirGesture] {
        spreads.enumerated().compactMap { index, spread in
            detector.handSeen(
                HandReading(x: 0, spread: spread),
                time: origin + Double(index) * step
            )
        }
    }

    func testFingersThrownOpenIsABurst() {
        var detector = AirGestureDetector()
        let fired = burst([0.15, 0.18, 0.30, 0.48, 0.62], into: &detector)
        XCTAssertEqual(fired, [.burst])
    }

    func testAHandThatIsAlreadyOpenIsNotABurst() {
        var detector = AirGestureDetector()
        // Holding an open hand up should not keep launching things.
        XCTAssertTrue(burst(Array(repeating: 0.66, count: 8), into: &detector).isEmpty)
    }

    func testAHandOpeningSlowlyIsNotABurst() {
        var detector = AirGestureDetector()
        // The same journey, over a second and a half instead of a quarter.
        let spreads = (0..<25).map { 0.15 + (0.70 - 0.15) * Double($0) / 24 }
        XCTAssertTrue(
            burst(spreads, step: 0.065, into: &detector).isEmpty,
            "a burst is thrown open, not unfolded"
        )
    }

    func testABurstNeedsFingertipsAndSurvivesFramesWithout() {
        var detector = AirGestureDetector()
        // Frames where the fingertips could not be read say nothing about
        // whether the hand is open, so they are skipped rather than counted as
        // closed.
        var fired: [AirGesture] = []
        let script: [(Double?, TimeInterval)] = [
            (0.15, 100.00), (nil, 100.06), (0.18, 100.12),
            (nil, 100.18), (0.48, 100.24), (0.62, 100.30),
        ]
        for (spread, time) in script {
            if let gesture = detector.handSeen(HandReading(x: 0, spread: spread), time: time) {
                fired.append(gesture)
            }
        }
        XCTAssertEqual(fired, [.burst])
    }

    func testABurstDoesNotAlsoCountAsASwipe() {
        var detector = AirGestureDetector()
        // The hand stays put while the fingers open, so nothing has travelled.
        XCTAssertEqual(burst([0.15, 0.18, 0.30, 0.48, 0.62], into: &detector), [.burst])
    }

    // MARK: - Wiring

    @MainActor
    func testTheStubReportsWhatTheLauncherAskedItToDo() {
        let source = InertAirGestureSource()
        var seen: [AirGesture] = []
        source.onGesture = { seen.append($0) }

        source.start()
        source.emit(.swipe(.left))
        source.emit(.burst)
        source.stop()

        XCTAssertEqual(seen, [.swipe(.left), .burst])
        XCTAssertEqual(source.startCount, 1)
        XCTAssertEqual(source.stopCount, 1)
        XCTAssertFalse(source.isWatching)
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
