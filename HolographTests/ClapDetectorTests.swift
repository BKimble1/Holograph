import XCTest
@testable import Holograph

/// The clap detector is a value type over loudness numbers, so a room can be
/// played through it without a microphone — or a room.
///
/// Every scenario here is a synthetic level trace with realistic jitter on every
/// reading, and each is run over many independent noise realisations. A single
/// clean run proves nothing about a detector whose entire job is telling one
/// loud thing from another.
final class ClapDetectorTests: XCTestCase {
    /// 256 frames at 48 kHz — the resolution the microphone source works at.
    private static let chunk = 256.0 / 48_000.0
    private static let seeds: ClosedRange<UInt64> = 1...24

    /// A room, its noise floor, and whatever happens in it.
    private struct Room {
        var detector = ClapDetector()
        var fired: [TimeInterval] = []
        var now: TimeInterval = 1_000

        private var noise: SeededNoise
        private let bed: Double

        init(seed: UInt64, bed: Double = -55) {
            noise = SeededNoise(seed: seed)
            self.bed = bed
        }

        /// One reading, in decibels relative to full scale, with the
        /// chunk-to-chunk wobble a real level meter shows.
        mutating func feed(_ decibels: Double) {
            let level = pow(10, (decibels + noise.next(spread: 3)) / 20)
            if detector.heard(level: level, at: now) { fired.append(now) }
            now += ClapDetectorTests.chunk
        }

        mutating func quiet(for duration: TimeInterval, at level: Double? = nil) {
            for _ in 0..<Int(duration / ClapDetectorTests.chunk) { feed(level ?? bed) }
        }

        /// A struck sound: full volume at once, then gone. `decay` is how live
        /// the room is — a dry clap is over in forty milliseconds, a reverberant
        /// one rings on for a tenth of a second.
        mutating func clap(
            peak: Double = -8,
            decay: TimeInterval = 0.025,
            over floorLevel: Double? = nil,
            lasting duration: TimeInterval = 0.30
        ) {
            let base = floorLevel ?? bed
            for step in 0..<Int(duration / ClapDetectorTests.chunk) {
                let elapsed = Double(step) * ClapDetectorTests.chunk
                feed(max(peak - 8.686 * elapsed / decay, base))
            }
        }

        /// Speech: as loud as a clap at its peaks, but it takes tens of
        /// milliseconds to get there and never really stops.
        mutating func speech(for duration: TimeInterval, at level: Double = -26) {
            for step in 0..<Int(duration / ClapDetectorTests.chunk) {
                let elapsed = Double(step) * ClapDetectorTests.chunk
                feed(level
                     + 9 * sin(2 * .pi * 4.5 * elapsed)
                     + 3 * sin(2 * .pi * 11 * elapsed))
            }
        }

        /// Music: a bed with a beat on it — acoustically the nearest thing there
        /// is to somebody clapping over and over.
        mutating func music(
            for duration: TimeInterval,
            bed musicBed: Double = -24,
            beat: Double = -4,
            period: TimeInterval = 0.4
        ) {
            for step in 0..<Int(duration / ClapDetectorTests.chunk) {
                let phase = (Double(step) * ClapDetectorTests.chunk).truncatingRemainder(dividingBy: period)
                let level = phase < 0.15 ? beat - 8.686 * phase / 0.04 : musicBed
                feed(max(level, musicBed))
            }
        }

        /// Two claps with a gap between them, in a quiet room. The gap is the
        /// time between the two strikes, so a quick pair really is quick — the
        /// second clap lands while the first is still ringing.
        mutating func doubleClap(
            gap: TimeInterval,
            peak: Double = -8,
            decay: TimeInterval = 0.025
        ) {
            quiet(for: 2.0)
            doubleClapBody(gap: gap, peak: peak, decay: decay)
            quiet(for: 1.5)
        }

        /// The two strikes alone, for measuring how long the answer takes.
        mutating func doubleClapBody(
            gap: TimeInterval,
            peak: Double = -8,
            decay: TimeInterval = 0.025
        ) {
            clap(peak: peak, decay: decay, lasting: gap)
            clap(peak: peak, decay: decay)
        }
    }

    private struct SeededNoise {
        private var state: UInt64
        init(seed: UInt64) { state = seed }

        mutating func next(spread: Double) -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return (Double(state >> 11) / Double(1 << 53) * 2 - 1) * spread
        }
    }

    /// Runs a scenario over every seed and returns how many times it fired.
    private func counts(bed: Double = -55, _ scenario: (inout Room) -> Void) -> [Int] {
        Self.seeds.map { seed in
            var room = Room(seed: seed, bed: bed)
            scenario(&room)
            return room.fired.count
        }
    }

    // MARK: - What should open an app

    func testTwoClapsOpenSomething() {
        // Down to an eighth of a second apart, which is what clapping twice in
        // earnest actually looks like. This used to need a third of a second:
        // a clap was not counted until it had fallen all the way back to the
        // room, and a quicker second one landed inside that wait and was lost.
        for gap in [0.11, 0.15, 0.20, 0.25, 0.35, 0.50, 0.70] {
            let fired = counts { $0.doubleClap(gap: gap) }
            XCTAssertEqual(
                Set(fired), [1],
                "two claps \(gap)s apart should be heard exactly once, not \(Set(fired))"
            )
        }
    }

    func testAQuickPairWorksInADryRoomToo() {
        // A room with no reverberation gives each clap a much shorter tail, so
        // the pair looks quite different arriving.
        for gap in [0.11, 0.15, 0.25] {
            XCTAssertEqual(Set(counts { $0.doubleClap(gap: gap, decay: 0.008) }), [1])
        }
    }

    func testClapsFromAcrossTheRoomStillCount() {
        // Quieter, because the hands are further away — but the shape is the
        // same, and the bar is set against the room rather than at some figure.
        XCTAssertEqual(Set(counts { $0.doubleClap(gap: 0.20, peak: -24) }), [1])
    }

    func testClappingInALoudRoomWorks() {
        XCTAssertEqual(Set(counts(bed: -33) { $0.doubleClap(gap: 0.20) }), [1])
    }

    func testTwoDeliberateDoubleClapsAreTwoLaunches() {
        let fired = counts { room in
            room.doubleClap(gap: 0.20)
            room.doubleClap(gap: 0.20)
        }
        XCTAssertEqual(Set(fired), [2])
    }

    // MARK: - What should not

    func testOneClapDoesNothing() {
        let fired = counts { room in
            room.quiet(for: 2.0)
            room.clap()
            room.quiet(for: 2.0)
        }
        XCTAssertEqual(Set(fired), [0])
    }

    func testTwoClapsTooFarApartAreTwoSeparateClaps() {
        XCTAssertEqual(Set(counts { $0.doubleClap(gap: 1.0) }), [0])
    }

    func testAClapAndSomethingElseIsNotAPair() {
        // Two claps come from one pair of hands and are about as loud as each
        // other. A clap and a door, or a clap and a knock on the table, are two
        // different sounds that happen to be near each other — which is most of
        // what was opening apps when nobody had clapped.
        for (first, second) in [(-8.0, -32.0), (-32.0, -8.0)] {
            let fired = counts { room in
                room.quiet(for: 2.0)
                room.clap(peak: first, lasting: 0.20)
                room.clap(peak: second)
                room.quiet(for: 1.5)
            }
            XCTAssertEqual(Set(fired), [0], "\(first)dB and \(second)dB are not a pair of hands")
        }
    }

    func testTalkingDoesNotOpenApps() {
        // The single most important negative case, and the one the attack test
        // exists for: speech reaches clap volume, but never in five
        // milliseconds.
        let fired = counts { room in
            room.quiet(for: 1.0)
            room.speech(for: 10.0)
            room.quiet(for: 0.5)
        }
        XCTAssertEqual(Set(fired), [0])
    }

    func testTalkingInALoudRoomDoesNotOpenApps() {
        let fired = counts(bed: -33) { room in
            room.quiet(for: 1.0)
            room.speech(for: 10.0, at: -18)
            room.quiet(for: 0.5)
        }
        XCTAssertEqual(Set(fired), [0])
    }

    func testSilenceDoesNothingAtAll() {
        XCTAssertEqual(Set(counts { $0.quiet(for: 20.0) }), [0])
    }

    func testARhythmDoesNotKeepOpeningApps() {
        // A beat is the hardest case there is: struck, loud, and repeatedly two
        // of them half a second apart. A level meter has no timbre to tell it
        // from a pair of hands, so what separates them is that a rhythm never
        // stops — every pair is cancelled by the beat that follows, and the
        // wait for that beat is a multiple of the pair's own spacing rather
        // than a fixed time. A fixed wait has a blind spot at every period just
        // longer than itself, and the 0.55s track below sat squarely in it.
        for (bed, beat, period) in [
            (-24.0, -4.0, 0.30), (-24.0, -4.0, 0.40), (-20.0, -7.0, 0.50),
            (-26.0, -2.0, 0.60), (-18.0, -3.0, 0.45), (-22.0, -5.0, 0.55),
        ] {
            let fired = counts { room in
                room.quiet(for: 1.0)
                room.music(for: 20.0, bed: bed, beat: beat, period: period)
                room.quiet(for: 0.5)
            }
            XCTAssertLessThanOrEqual(
                fired.max() ?? 0, 2,
                "twenty seconds of a \(period)s beat should not open apps repeatedly"
            )
        }
    }

    func testNothingCanOpenAppsInQuickSuccession() {
        // The hard guarantee behind the bound above: a pair has to begin a clear
        // second after the last one was reported, so no sound of any kind can
        // make the launcher fire twice in a hurry.
        var closest = TimeInterval.greatestFiniteMagnitude
        for seed in Self.seeds {
            var room = Room(seed: seed)
            room.quiet(for: 1.0)
            room.music(for: 30.0, bed: -22, beat: -5, period: 0.55)
            for (earlier, later) in zip(room.fired, room.fired.dropFirst()) {
                closest = min(closest, later - earlier)
            }
        }
        guard closest < .greatestFiniteMagnitude else { return }
        XCTAssertGreaterThan(closest, ClapDetector.Thresholds.default.rearm)
    }

    func testAClapOverMusicIsNotEnoughOnItsOwn() {
        // Two beats immediately either side of the pair would make it a run of
        // four, and a run is never a pair.
        let fired = counts { room in
            room.quiet(for: 1.0)
            room.music(for: 2.0)
            room.clap(peak: -2, over: -24, lasting: 0.20)
            room.clap(peak: -2, over: -24)
            room.music(for: 2.0)
        }
        XCTAssertLessThanOrEqual(fired.max() ?? 0, 1)
    }

    // MARK: - The launcher's own noise

    func testTheLauncherDoesNotOpenAppsWithItsOwnTicks() {
        // Two carousel ticks in half a second are, to a level meter, an
        // excellent double clap — which is exactly why the sound service tells
        // the listener when it is about to make one.
        let fired = counts { room in
            room.quiet(for: 1.5)
            room.detector.mute(for: 0.25, from: room.now)
            room.clap(peak: -12)
            room.quiet(for: 0.2)
            room.detector.mute(for: 0.25, from: room.now)
            room.clap(peak: -12)
            room.quiet(for: 1.5)
        }
        XCTAssertEqual(Set(fired), [0])
    }

    func testMutingForgetsWhatItHadAlreadyHeard() {
        // Half a pair, then the launcher speaks. The clap it heard before must
        // not pair up with whatever it hears afterwards.
        let fired = counts { room in
            room.quiet(for: 2.0)
            room.clap(lasting: 0.20)
            room.detector.mute(for: 0.1, from: room.now)
            room.quiet(for: 0.15)
            room.clap()
            room.quiet(for: 1.5)
        }
        XCTAssertEqual(Set(fired), [0])
    }

    func testResettingForgetsEverything() {
        var room = Room(seed: 1)
        room.quiet(for: 2.0)
        room.clap(lasting: 0.20)
        room.detector.reset()
        room.clap()
        room.quiet(for: 1.0)
        XCTAssertTrue(room.fired.isEmpty, "a listener that was restarted has heard nothing yet")
    }

    // MARK: - Delay

    func testAQuickClapIsAnsweredQuickly() {
        var room = Room(seed: 1)
        room.quiet(for: 2.0)
        let started = room.now
        room.doubleClapBody(gap: 0.15)
        room.quiet(for: 1.5)

        guard let heard = room.fired.first else { return XCTFail("nothing was heard") }
        // Waiting for silence after the pair is what rules out a drum track, and
        // it is the whole of the delay — but it is a multiple of the pair's own
        // spacing, so clapping quickly is answered quickly.
        XCTAssertLessThan(heard - started, 0.6)
    }
}

// MARK: - Levels

final class ClapLevelTests: XCTestCase {
    private func peaks(_ samples: [Float], chunk: Int = ClapLevels.chunkFrames) -> [Float] {
        samples.withUnsafeBufferPointer { ClapLevels.peaks(of: $0, chunk: chunk) }
    }

    func testEachChunkReportsItsLoudestMoment() {
        let samples: [Float] = [0.1, -0.9, 0.2, 0.05, 0.3, -0.4]
        XCTAssertEqual(peaks(samples, chunk: 3), [0.9, 0.4])
    }

    func testATrailingPartialChunkIsStillMeasured() {
        // A clap that begins in the last few frames of a buffer is still a clap.
        XCTAssertEqual(peaks([0.1, 0.2, 0.3, 0.8], chunk: 3), [0.3, 0.8])
    }

    func testNothingInMeansNothingOut() {
        XCTAssertTrue(peaks([]).isEmpty)
        XCTAssertTrue(peaks([0.5, 0.5], chunk: 0).isEmpty)
    }

    func testTheChunkIsShortEnoughToSeeAClapArrive() {
        // A clap's leading edge is a few milliseconds long. Measured any coarser
        // and the attack — the one thing that separates it from a voice — is
        // averaged away before the detector ever sees it.
        XCTAssertLessThanOrEqual(Double(ClapLevels.chunkFrames) / 44_100, 0.006)
    }
}

// MARK: - Preferences

final class ClapPreferencesTests: XCTestCase {
    private let defaults = UserDefaults.standard
    private var saved: Any?

    override func setUp() {
        super.setUp()
        saved = defaults.object(forKey: ClapPreferences.enabledKey)
        defaults.removeObject(forKey: ClapPreferences.enabledKey)
    }

    override func tearDown() {
        if let saved {
            defaults.set(saved, forKey: ClapPreferences.enabledKey)
        } else {
            defaults.removeObject(forKey: ClapPreferences.enabledKey)
        }
        super.tearDown()
    }

    func testItIsOffUntilItIsAskedFor() {
        // It runs the microphone, so a fresh install must not be listening.
        XCTAssertFalse(ClapPreferences.isEnabled)
    }

    func testTurningItOnIsRemembered() {
        defaults.set(true, forKey: ClapPreferences.enabledKey)
        XCTAssertTrue(ClapPreferences.isEnabled)
    }

    func testTheKeyIsItsOwn() {
        XCTAssertNotEqual(ClapPreferences.enabledKey, AirGesturePreferences.enabledKey)
    }
}

@MainActor
final class InertClapListenerTests: XCTestCase {
    func testItRecordsWhatTheLauncherAskedItToDo() {
        let listener = InertClapListener()
        var heard = 0
        listener.onDoubleClap = { heard += 1 }

        listener.start()
        listener.emit()
        listener.mute(for: 0.25)
        listener.stop()

        XCTAssertEqual(heard, 1)
        XCTAssertEqual(listener.startCount, 1)
        XCTAssertEqual(listener.stopCount, 1)
        XCTAssertEqual(listener.mutedFor, [0.25])
        XCTAssertFalse(listener.isListening)
    }
}
