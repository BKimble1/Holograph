import XCTest
@testable import Holograph

/// The gesture logic is a value type over plain numbers, so a hand can be played
/// through it frame by frame — no camera, no hand, no running app.
///
/// Distances are written in inches and converted, because inches are what the
/// gesture was asked for in. A hand is about 3.3 inches across the knuckles, and
/// every threshold is in those spans, so the same flick works at any distance
/// from the screen.
final class AirGestureDetectorTests: XCTestCase {
    private let thresholds = AirGestureDetector.Thresholds.default

    /// Knuckle span of an adult hand, the ruler everything is measured against.
    private static let spanInInches = 3.3
    private func spans(_ inches: Double) -> Double { inches / Self.spanInInches }

    /// Plays a hand travelling `inches` at the rate the camera samples.
    @discardableResult
    private func flick(
        _ inches: Double,
        over duration: TimeInterval,
        startingAt origin: TimeInterval = 100,
        from start: Double = 0,
        spread: Double = 0.8,
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

    func testASixInchFlickIsASwipe() {
        var detector = AirGestureDetector()
        XCTAssertEqual(flick(6, over: 0.30, into: &detector), [.swipe(.right)])
    }

    func testATenInchFlickIsASwipe() {
        var detector = AirGestureDetector()
        XCTAssertEqual(flick(-10, over: 0.35, from: spans(10), into: &detector), [.swipe(.left)])
    }

    func testTheSameFlickRepeatedKeepsWorking() {
        var detector = AirGestureDetector()
        XCTAssertEqual(flick(7, over: 0.28, into: &detector), [.swipe(.right)])
        detector.handLost()
        // Repeating a deliberate gesture should feel immediate.
        XCTAssertEqual(
            flick(7, over: 0.28, startingAt: 100.8, into: &detector),
            [.swipe(.right)]
        )
    }

    // MARK: - Swipes that should not

    func testAThreeInchNudgeIsNotASwipe() {
        var detector = AirGestureDetector()
        XCTAssertTrue(flick(3, over: 0.25, into: &detector).isEmpty)
    }

    func testASixInchMoveMadeSlowlyIsNotASwipe() {
        var detector = AirGestureDetector()
        // Far enough, but taken at a stroll — someone reaching past the iPad.
        XCTAssertTrue(flick(6, over: 1.0, into: &detector).isEmpty)
    }

    /// The one that mattered: the hand has to come back after a flick, and that
    /// return journey was being read as a swipe the other way.
    func testTheHandComingBackDoesNotUndoTheSwipe() {
        var detector = AirGestureDetector()
        XCTAssertEqual(flick(8, over: 0.30, into: &detector), [.swipe(.right)])

        let returning = flick(
            -8, over: 0.30, startingAt: 100.45, from: spans(8), into: &detector
        )
        XCTAssertTrue(returning.isEmpty, "bringing the hand back is not a gesture")
    }

    func testADeliberateReverseIsStillHeard() {
        var detector = AirGestureDetector()
        XCTAssertEqual(flick(8, over: 0.30, into: &detector), [.swipe(.right)])
        detector.handLost()

        // Long enough afterwards to be meant rather than incidental.
        let back = flick(-8, over: 0.30, startingAt: 101.9, from: spans(8), into: &detector)
        XCTAssertEqual(back, [.swipe(.left)])
    }

    func testAWanderingPathIsNotASwipeEvenWhenItEndsFarAway() {
        var detector = AirGestureDetector()
        let path: [(x: Double, time: TimeInterval)] = [
            (spans(0), 100.00),
            (spans(7), 100.06),
            (spans(1), 100.12),
            (spans(8), 100.18),
        ]
        let fired = path.compactMap {
            detector.handSeen(HandReading(x: $0.x, spread: 0.8), time: $0.time)
        }
        XCTAssertTrue(fired.isEmpty, "a swipe is a straight line, not a search")
    }

    func testAHandLeavingTheFrameAbandonsThePath() {
        var detector = AirGestureDetector()
        XCTAssertTrue(flick(3, over: 0.12, into: &detector).isEmpty)

        detector.handLost()
        XCTAssertEqual(detector.sampleCount, 0)

        // Reappearing far away must not join up into one long sweep.
        let fired = flick(1, over: 0.10, startingAt: 100.15, from: spans(9), into: &detector)
        XCTAssertTrue(fired.isEmpty)
    }

    func testFramesArrivingOutOfOrderAreIgnored() {
        var detector = AirGestureDetector()
        _ = detector.handSeen(HandReading(x: 0.3, spread: 0.8), time: 100)
        _ = detector.handSeen(HandReading(x: 0.6, spread: 0.8), time: 100.06)
        let before = detector.sampleCount

        XCTAssertNil(
            detector.handSeen(HandReading(x: 4, spread: 0.8), time: 99.9),
            "a stale frame is not new information"
        )
        XCTAssertEqual(detector.sampleCount, before)
    }

    // MARK: - The burst

    /// Fingers gathered in the middle and thrown open.
    private func burst(
        _ spreads: [Double],
        startingAt origin: TimeInterval = 100,
        into detector: inout AirGestureDetector
    ) -> [AirGesture] {
        spreads.enumerated().compactMap { index, spread in
            detector.handSeen(
                HandReading(x: 0, spread: spread),
                time: origin + Double(index) * 0.06
            )
        }
    }

    func testFingersThrownOpenIsABurst() {
        var detector = AirGestureDetector()
        let fired = burst([0.45, 0.50, 0.75, 1.05, 1.20], into: &detector)
        XCTAssertEqual(fired, [.burst])
    }

    func testAHandThatIsAlreadyOpenIsNotABurst() {
        var detector = AirGestureDetector()
        // Holding an open hand up should not keep launching things.
        let fired = burst(Array(repeating: 1.15, count: 6), into: &detector)
        XCTAssertTrue(fired.isEmpty)
    }

    func testASlowUnfurlIsNotABurst() {
        var detector = AirGestureDetector()
        let spreads = (0..<24).map { 0.45 + (1.25 - 0.45) * Double($0) / 23 }
        var fired: [AirGesture] = []
        for (index, spread) in spreads.enumerated() {
            if let gesture = detector.handSeen(
                HandReading(x: 0, spread: spread),
                time: 100 + Double(index) * 0.065
            ) {
                fired.append(gesture)
            }
        }
        XCTAssertTrue(fired.isEmpty, "a burst is thrown open, not unfolded")
    }

    func testABurstDoesNotAlsoCountAsASwipe() {
        var detector = AirGestureDetector()
        // The hand stays put while the fingers open, so nothing has travelled.
        XCTAssertEqual(burst([0.45, 0.50, 0.75, 1.05, 1.20], into: &detector), [.burst])
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
