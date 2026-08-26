import XCTest
@testable import Holograph

/// Calibration is measurement, so it is tested the way the detectors are: by
/// playing a person through it and checking what comes out. No camera, no
/// microphone, no hardware of any kind.
final class HandCalibratorTests: XCTestCase {
    private let frameRate = 30.0
    /// A hand is about three inches across the knuckles, so a span is an inch
    /// and a half of travel... in spans.
    private func flick(
        into calibrator: inout HandCalibrator,
        spans: Double,
        over duration: TimeInterval,
        from time: TimeInterval
    ) -> TimeInterval {
        var now = time
        let steps = max(2, Int(duration * frameRate))
        // Positions are handed over as (x, span) with span 1, so x is spans.
        for step in 0...steps {
            let progress = Double(step) / Double(steps)
            calibrator.handSeen(HandReading(x: spans * progress, span: 1), at: now)
            now += duration / Double(steps)
        }
        // And then it stops, which is what closes the stroke.
        for _ in 0..<6 {
            calibrator.handSeen(HandReading(x: spans, span: 1), at: now)
            now += 1 / frameRate
        }
        return now
    }

    func testThreeFlicksAreEnough() {
        var calibrator = HandCalibrator()
        var time: TimeInterval = 100
        XCTAssertFalse(calibrator.isComplete)
        for _ in 0..<3 {
            time = flick(into: &calibrator, spans: 2.0, over: 0.30, from: time)
        }
        XCTAssertTrue(calibrator.isComplete)
        XCTAssertEqual(calibrator.flicks.count, 3)
        XCTAssertNotNil(calibrator.result())
    }

    func testItRefusesToGuessFromTooLittle() {
        var calibrator = HandCalibrator()
        var time: TimeInterval = 100
        time = flick(into: &calibrator, spans: 2.0, over: 0.30, from: time)
        XCTAssertNil(calibrator.result(), "one flick is not a measurement")
    }

    func testTheThresholdSitsWellBelowWhatWasActuallyDone() {
        // The point of calibrating: a threshold set *at* what somebody managed
        // three times in a row would fail on the fourth.
        var calibrator = HandCalibrator()
        var time: TimeInterval = 100
        for _ in 0..<3 {
            time = flick(into: &calibrator, spans: 2.0, over: 0.30, from: time)
        }
        guard let result = calibrator.result() else { return XCTFail("no result") }
        let peak = HandCalibrator.median(calibrator.flicks.map(\.peakSpeed))
        let travel = HandCalibrator.median(calibrator.flicks.map(\.travel))

        XCTAssertLessThan(result.startSpeed, peak * 0.6)
        XCTAssertLessThan(result.travelSpans, travel * 0.7)
        XCTAssertGreaterThan(result.startSpeed, 0)
    }

    func testABigFlickerGetsAHigherBarThanASmallOne() {
        // Two different people, two different answers — which is the whole
        // reason this exists.
        var big = HandCalibrator()
        var small = HandCalibrator()
        var t1: TimeInterval = 100
        var t2: TimeInterval = 100
        for _ in 0..<3 {
            t1 = flick(into: &big, spans: 4.0, over: 0.30, from: t1)
            t2 = flick(into: &small, spans: 1.2, over: 0.30, from: t2)
        }
        guard let bigResult = big.result(), let smallResult = small.result() else {
            return XCTFail("both should measure")
        }
        XCTAssertGreaterThan(bigResult.travelSpans, smallResult.travelSpans)
        XCTAssertGreaterThan(bigResult.startSpeed, smallResult.startSpeed)
    }

    func testATwitchIsNotAFlick() {
        var calibrator = HandCalibrator()
        var time: TimeInterval = 100
        for _ in 0..<5 {
            time = flick(into: &calibrator, spans: 0.15, over: 0.10, from: time)
        }
        XCTAssertTrue(calibrator.flicks.isEmpty, "a twitch is not somebody trying to flick")
    }

    func testAHandLeavingAbandonsWhateverWasBuilding() {
        var calibrator = HandCalibrator()
        var time: TimeInterval = 100
        for step in 0..<5 {
            calibrator.handSeen(HandReading(x: Double(step) * 0.4, span: 1), at: time)
            time += 1 / frameRate
        }
        calibrator.handLost()
        XCTAssertTrue(calibrator.flicks.isEmpty)
    }

    func testTheMedianIgnoresOneBadAttempt() {
        // Three flicks, one of them wild. The answer should look like the two
        // ordinary ones.
        var calibrator = HandCalibrator()
        var time: TimeInterval = 100
        time = flick(into: &calibrator, spans: 2.0, over: 0.30, from: time)
        time = flick(into: &calibrator, spans: 9.0, over: 0.30, from: time)
        time = flick(into: &calibrator, spans: 2.1, over: 0.30, from: time)

        guard let result = calibrator.result() else { return XCTFail("no result") }
        XCTAssertLessThan(result.travelSpans, 2.0, "the wild one should not drag the answer")
    }
}

final class HeadCalibratorTests: XCTestCase {
    private func look(_ calibrator: inout HeadCalibrator, around extent: Double, samples: Int = 60) {
        for step in 0..<samples {
            let phase = Double(step) / Double(samples) * 2 * .pi
            calibrator.headSeen(
                HeadReading(x: sin(phase) * extent, y: cos(phase) * extent * 0.6, scale: 0.2)
            )
        }
    }

    func testItNeedsEnoughToGoOn() {
        var calibrator = HeadCalibrator()
        look(&calibrator, around: 0.2, samples: 10)
        XCTAssertNil(calibrator.result())
        XCTAssertFalse(calibrator.isComplete)
    }

    func testSomebodyWhoSitsCloseGetsAWiderRange() {
        // Sitting close means the same head movement crosses more of the frame.
        var near = HeadCalibrator()
        var far = HeadCalibrator()
        look(&near, around: 0.30)
        look(&far, around: 0.10)

        guard let nearRange = near.result(), let farRange = far.result() else {
            return XCTFail("both should measure")
        }
        XCTAssertGreaterThan(nearRange, farRange)
    }

    func testTheFullEffectArrivesBeforeTheLimitOfWhatWasDone() {
        // Otherwise the corners are the only place the depth is fully felt.
        var calibrator = HeadCalibrator()
        look(&calibrator, around: 0.30)
        guard let range = calibrator.result() else { return XCTFail("no result") }
        XCTAssertLessThan(range, 0.30, "reaching full effect should not need the extreme")
    }

    func testAHeadThatNeverMovedIsRefusedRatherThanGuessedAt() {
        // Setting a range from somebody who sat perfectly still would make the
        // scene wildly oversensitive.
        var calibrator = HeadCalibrator()
        for _ in 0..<HeadCalibrator.wanted {
            calibrator.headSeen(HeadReading(x: 0.01, y: 0, scale: 0.2))
        }
        XCTAssertTrue(calibrator.isComplete)
        XCTAssertNil(calibrator.result())
    }
}

final class ClapCalibratorTests: XCTestCase {
    private let chunk = 256.0 / 48_000.0

    private func room(_ calibrator: inout ClapCalibrator, seconds: TimeInterval, from time: TimeInterval, level: Double = -55) -> TimeInterval {
        var now = time
        for _ in 0..<Int(seconds / chunk) {
            calibrator.heard(level: pow(10, level / 20), at: now)
            now += chunk
        }
        return now
    }

    private func clap(_ calibrator: inout ClapCalibrator, peak: Double, from time: TimeInterval, lasting: TimeInterval = 0.25) -> TimeInterval {
        var now = time
        for step in 0..<Int(lasting / chunk) {
            let level = max(peak - 8.686 * (Double(step) * chunk) / 0.02, -55)
            calibrator.heard(level: pow(10, level / 20), at: now)
            now += chunk
        }
        return now
    }

    private func doubleClap(_ calibrator: inout ClapCalibrator, peak: Double, gap: TimeInterval, from time: TimeInterval) -> TimeInterval {
        var now = clap(&calibrator, peak: peak, from: time, lasting: gap)
        now = clap(&calibrator, peak: peak, from: now)
        return room(&calibrator, seconds: 1.0, from: now)
    }

    func testThreeDoubleClapsAreEnough() {
        var calibrator = ClapCalibrator()
        var time = room(&calibrator, seconds: 1.0, from: 1_000)
        for _ in 0..<3 {
            time = doubleClap(&calibrator, peak: -10, gap: 0.20, from: time)
        }
        XCTAssertTrue(calibrator.isComplete)
        XCTAssertNotNil(calibrator.result())
    }

    func testItRefusesToGuessFromTooLittle() {
        var calibrator = ClapCalibrator()
        var time = room(&calibrator, seconds: 1.0, from: 1_000)
        time = doubleClap(&calibrator, peak: -10, gap: 0.20, from: time)
        XCTAssertNil(calibrator.result())
    }

    func testAQuietClapperGetsALowerBar() {
        var loud = ClapCalibrator()
        var quiet = ClapCalibrator()
        var t1 = room(&loud, seconds: 1.0, from: 1_000)
        var t2 = room(&quiet, seconds: 1.0, from: 1_000)
        for _ in 0..<3 {
            t1 = doubleClap(&loud, peak: -6, gap: 0.20, from: t1)
            t2 = doubleClap(&quiet, peak: -22, gap: 0.20, from: t2)
        }
        guard let loudResult = loud.result(), let quietResult = quiet.result() else {
            return XCTFail("both should measure")
        }
        XCTAssertLessThan(quietResult.level, loudResult.level)
    }

    func testTheBarSitsUnderTheQuietestClapHeard() {
        // Not in the middle of them: a bar set at the average would miss every
        // clap softer than average, which is half of them.
        var calibrator = ClapCalibrator()
        var time = room(&calibrator, seconds: 1.0, from: 1_000)
        time = doubleClap(&calibrator, peak: -8, gap: 0.20, from: time)
        time = doubleClap(&calibrator, peak: -18, gap: 0.20, from: time)
        time = doubleClap(&calibrator, peak: -10, gap: 0.20, from: time)

        guard let result = calibrator.result() else { return XCTFail("no result") }
        let quietest = calibrator.pairs.map(\.level).min() ?? 0
        XCTAssertLessThan(result.level, quietest)
    }

    func testSomebodyWhoClapsSlowlyGetsAWiderWindow() {
        var quick = ClapCalibrator()
        var slow = ClapCalibrator()
        var t1 = room(&quick, seconds: 1.0, from: 1_000)
        var t2 = room(&slow, seconds: 1.0, from: 1_000)
        for _ in 0..<3 {
            t1 = doubleClap(&quick, peak: -10, gap: 0.15, from: t1)
            t2 = doubleClap(&slow, peak: -10, gap: 0.50, from: t2)
        }
        guard let quickResult = quick.result(), let slowResult = slow.result() else {
            return XCTFail("both should measure")
        }
        XCTAssertGreaterThan(slowResult.maximumGap, quickResult.maximumGap)
        XCTAssertGreaterThan(slowResult.maximumGap, 0.50, "and it should cover what they did")
    }

    func testAQuietRoomAloneMeasuresNothing() {
        var calibrator = ClapCalibrator()
        _ = room(&calibrator, seconds: 6.0, from: 1_000)
        XCTAssertTrue(calibrator.pairs.isEmpty)
        XCTAssertNil(calibrator.result())
    }
}

/// A profile only ever nudges the shipped thresholds, and never outside a range
/// the detectors are known to behave in.
final class CalibrationProfileTests: XCTestCase {
    func testAnEmptyProfileChangesNothing() {
        let gesture = AirGestureDetector.Thresholds.default
        XCTAssertEqual(gesture.applying(.none), gesture)

        let head = HeadTracker.Thresholds()
        XCTAssertEqual(head.applying(.none), head)

        let clap = ClapDetector.Thresholds.default
        XCTAssertEqual(clap.applying(.none), clap)
    }

    func testMeasuredValuesAreUsed() {
        var profile = CalibrationProfile()
        profile.flickStartSpeed = 2.0
        profile.flickTravelSpans = 0.55
        profile.headRange = 0.22
        profile.clapLevel = -30
        profile.clapMaximumGap = 0.55

        XCTAssertEqual(AirGestureDetector.Thresholds.default.applying(profile).startSpeed, 2.0)
        XCTAssertEqual(AirGestureDetector.Thresholds.default.applying(profile).travelSpans, 0.55)
        XCTAssertEqual(HeadTracker.Thresholds().applying(profile).range, 0.22)
        XCTAssertEqual(ClapDetector.Thresholds.default.applying(profile).absoluteLevel, -30)
        XCTAssertEqual(ClapDetector.Thresholds.default.applying(profile).maximumGap, 0.55)
    }

    func testAStrangeMeasurementIsClampedRatherThanObeyed() {
        // A calibration that came out wrong should make the launcher slightly
        // worse, never broken.
        var wild = CalibrationProfile()
        wild.flickStartSpeed = 0.01
        wild.flickTravelSpans = 99
        wild.headRange = 0.0001
        wild.clapLevel = 40
        wild.clapMaximumGap = 12

        let gesture = AirGestureDetector.Thresholds.default.applying(wild)
        XCTAssertGreaterThanOrEqual(gesture.startSpeed, 1.6)
        XCTAssertLessThanOrEqual(gesture.travelSpans, 1.40)
        XCTAssertGreaterThanOrEqual(HeadTracker.Thresholds().applying(wild).range, 0.06)
        XCTAssertLessThanOrEqual(ClapDetector.Thresholds.default.applying(wild).absoluteLevel, -12)
        XCTAssertLessThanOrEqual(ClapDetector.Thresholds.default.applying(wild).maximumGap, 0.95)
    }

    func testStillnessStaysBelowTheSpeedThatStartsAStroke() {
        // Otherwise a stroke could open and never close, and the detector would
        // sit spent forever — which is a bug this project has already had once.
        var slow = CalibrationProfile()
        slow.flickStartSpeed = 1.6
        let tuned = AirGestureDetector.Thresholds.default.applying(slow)
        XCTAssertLessThan(tuned.stopSpeed, tuned.startSpeed)
    }

    func testAProfileSurvivesBeingStored() throws {
        let defaults = UserDefaults(suiteName: "calibration.tests")!
        defer { defaults.removePersistentDomain(forName: "calibration.tests") }

        var profile = CalibrationProfile()
        profile.flickStartSpeed = 2.2
        profile.clapMaximumGap = 0.4
        CalibrationStore.save(profile, to: defaults)

        let loaded = CalibrationStore.load(from: defaults)
        XCTAssertEqual(loaded.flickStartSpeed, 2.2)
        XCTAssertEqual(loaded.clapMaximumGap, 0.4)
        XCTAssertTrue(loaded.hasClap == false, "half a clap measurement is not a clap measurement")

        CalibrationStore.clear(from: defaults)
        XCTAssertTrue(CalibrationStore.load(from: defaults).isEmpty)
    }

    func testNothingMeasuredMeansNothingChanged() {
        XCTAssertTrue(CalibrationProfile.none.isEmpty)
        XCTAssertFalse(CalibrationProfile.none.hasHand)
        XCTAssertFalse(CalibrationProfile.none.hasHead)
        XCTAssertFalse(CalibrationProfile.none.hasClap)
    }
}
