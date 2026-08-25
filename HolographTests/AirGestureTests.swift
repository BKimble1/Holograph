import XCTest
@testable import Holograph

/// The gesture logic is a value type over plain numbers, so a swipe can be
/// played through it frame by frame — no camera, no hand, no running app.
final class AirSwipeDetectorTests: XCTestCase {
    private let thresholds = AirSwipeDetector.Thresholds.default

    /// Plays a hand travelling from `from` to `to` over `duration`, at the rate
    /// the camera actually samples. Returns every swipe that fired.
    private func play(
        from start: Double,
        to end: Double,
        over duration: TimeInterval,
        startingAt origin: TimeInterval = 100,
        frameRate: Double = 18,
        into detector: inout AirSwipeDetector
    ) -> [AirSwipe] {
        let steps = max(1, Int((duration * frameRate).rounded()))
        var fired: [AirSwipe] = []
        for step in 0...steps {
            let progress = Double(step) / Double(steps)
            let x = start + (end - start) * progress
            let time = origin + duration * progress
            if let swipe = detector.handSeen(atX: x, time: time) { fired.append(swipe) }
        }
        return fired
    }

    // MARK: - What should fire

    func testAFlickToTheRightIsASwipeRight() {
        var detector = AirSwipeDetector()
        let fired = play(from: 0.3, to: 0.75, over: 0.25, into: &detector)
        XCTAssertEqual(fired, [.right])
    }

    func testAFlickToTheLeftIsASwipeLeft() {
        var detector = AirSwipeDetector()
        let fired = play(from: 0.75, to: 0.25, over: 0.25, into: &detector)
        XCTAssertEqual(fired, [.left])
    }

    func testOneFlickFiresOnlyOnce() {
        var detector = AirSwipeDetector()
        let fired = play(from: 0.2, to: 0.85, over: 0.3, into: &detector)
        XCTAssertEqual(fired.count, 1, "a single gesture must not repeat as it continues")
    }

    // MARK: - What should not

    func testAHandDriftingAcrossIsNotAFlick() {
        var detector = AirSwipeDetector()
        // Same distance, four times as long: someone reaching past the iPad.
        let fired = play(from: 0.2, to: 0.8, over: 2.0, into: &detector)
        XCTAssertTrue(fired.isEmpty, "slow travel is not a gesture")
    }

    func testASmallMovementIsNotAFlick() {
        var detector = AirSwipeDetector()
        let fired = play(from: 0.48, to: 0.56, over: 0.2, into: &detector)
        XCTAssertTrue(fired.isEmpty, "a hand shifting slightly should be ignored")
    }

    func testASmallWaveIsNotAFlick() {
        var detector = AirSwipeDetector()
        // Hello-style waving: quick, but never crossing much of the frame.
        var fired = play(from: 0.50, to: 0.62, over: 0.12, into: &detector)
        fired += play(from: 0.62, to: 0.50, over: 0.12, startingAt: 100.12, into: &detector)
        fired += play(from: 0.50, to: 0.62, over: 0.12, startingAt: 100.24, into: &detector)
        XCTAssertTrue(fired.isEmpty, "waving is not flicking")
    }

    func testAWanderingPathIsNotASwipeEvenWhenItEndsFarAway() {
        var detector = AirSwipeDetector()
        // Ends 0.30 to the right of where it began — far enough on distance
        // alone — but doubles back twice getting there. A flick does not.
        let path: [(x: Double, time: TimeInterval)] = [
            (0.30, 100.00),
            (0.55, 100.06),
            (0.35, 100.12),
            (0.60, 100.18),
        ]
        let fired = path.compactMap { detector.handSeen(atX: $0.x, time: $0.time) }
        XCTAssertTrue(fired.isEmpty, "a swipe is a straight line, not a search")
    }

    func testAHandLeavingTheFrameAbandonsThePath() {
        var detector = AirSwipeDetector()
        // Short of a flick on its own, so nothing has fired yet.
        XCTAssertTrue(play(from: 0.20, to: 0.38, over: 0.12, into: &detector).isEmpty)

        detector.handLost()
        XCTAssertEqual(detector.sampleCount, 0)

        // The hand reappears at the far side. Joined to what came before, that
        // is a wide fast sweep; it must not be read as one.
        let fired = play(from: 0.75, to: 0.80, over: 0.10, startingAt: 100.15, into: &detector)
        XCTAssertTrue(fired.isEmpty)
    }

    func testTooFewSamplesIsNotEnoughToJudge() {
        var detector = AirSwipeDetector()
        // Two frames could be a tracking glitch jumping across the frame.
        XCTAssertNil(detector.handSeen(atX: 0.2, time: 100))
        XCTAssertNil(detector.handSeen(atX: 0.9, time: 100.08))
    }

    func testFramesArrivingOutOfOrderAreIgnored() {
        var detector = AirSwipeDetector()
        _ = detector.handSeen(atX: 0.3, time: 100)
        _ = detector.handSeen(atX: 0.4, time: 100.06)
        let before = detector.sampleCount
        XCTAssertNil(detector.handSeen(atX: 0.9, time: 99.9), "a stale frame is not new information")
        XCTAssertEqual(detector.sampleCount, before)
    }

    // MARK: - Repeating

    func testTheReturnStrokeDoesNotFireTheOppositeSwipe() {
        var detector = AirSwipeDetector()
        let out = play(from: 0.2, to: 0.8, over: 0.25, into: &detector)
        XCTAssertEqual(out, [.right])

        // Bringing the hand straight back, immediately — the classic false
        // positive, and the reason there is a cooldown at all.
        let back = play(from: 0.8, to: 0.2, over: 0.25, startingAt: 100.26, into: &detector)
        XCTAssertTrue(back.isEmpty, "the hand coming back is not a swipe the other way")
    }

    func testASecondFlickAfterTheCooldownIsHeard() {
        var detector = AirSwipeDetector()
        XCTAssertEqual(play(from: 0.2, to: 0.8, over: 0.25, into: &detector), [.right])

        let later = 100 + 0.25 + thresholds.cooldown + 0.1
        detector.handLost()
        let again = play(from: 0.2, to: 0.8, over: 0.25, startingAt: later, into: &detector)
        XCTAssertEqual(again, [.right], "deliberate repeats have to keep working")
    }

    // MARK: - Wiring

    @MainActor
    func testTheStubReportsWhatTheLauncherAskedItToDo() {
        let source = InertAirGestureSource()
        var seen: [AirSwipe] = []
        source.onSwipe = { seen.append($0) }

        source.start()
        source.emit(.left)
        source.emit(.right)
        source.stop()

        XCTAssertEqual(seen, [.left, .right])
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
