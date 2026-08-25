import XCTest
@testable import Holograph

/// The tick is synthesised, so its shape can be checked directly — no audio
/// engine, no device, no listening.
final class HoloClickTests: XCTestCase {
    func testTheBufferIsAsLongAsTheStatedDuration() {
        let samples = HoloClick.waveform()
        XCTAssertEqual(samples.count, Int(HoloClick.sampleRate * HoloClick.duration))
        XCTAssertEqual(samples.count, HoloClick.frameCount)
    }

    func testEverySampleIsFiniteAndWithinRange() {
        for sample in HoloClick.waveform() {
            XCTAssertTrue(sample.isFinite, "a non-finite sample would be heard as a pop")
            XCTAssertLessThanOrEqual(abs(sample), 1, "samples outside ±1 clip")
        }
    }

    func testItIsAShortClickRatherThanASustainedTone() {
        let samples = HoloClick.waveform()
        let window = samples.count / 10
        let opening = peak(of: Array(samples.prefix(window)))
        let tail = peak(of: Array(samples.suffix(window)))

        XCTAssertGreaterThan(opening, 0.05, "the click should actually be audible")
        XCTAssertLessThan(tail, opening / 4, "it should have decayed away by the end")
    }

    func testItStartsAndEndsNearSilence() {
        let samples = HoloClick.waveform()
        // A buffer that begins or ends on a step is heard as an extra click.
        XCTAssertLessThan(abs(samples[0]), 0.05)
        XCTAssertLessThan(abs(samples[samples.count - 1]), 0.05)
    }

    func testThePitchSweepsDownwards() {
        let samples = HoloClick.waveform()
        let third = samples.count / 3
        let opening = zeroCrossings(in: Array(samples.prefix(third)))
        let closing = zeroCrossings(in: Array(samples[(2 * third)...]))

        // Falling pitch is what makes it read as synthetic rather than mechanical.
        XCTAssertGreaterThan(
            opening, closing,
            "the opening should carry more crossings than the tail if pitch falls"
        )
    }

    func testTheWaveformIsDeterministic() {
        // Two calls must agree, or the sound would drift between taps.
        XCTAssertEqual(HoloClick.waveform(), HoloClick.waveform())
    }

    // MARK: - Helpers

    private func peak(of samples: [Float]) -> Float {
        samples.map(abs).max() ?? 0
    }

    private func zeroCrossings(in samples: [Float]) -> Int {
        guard samples.count > 1 else { return 0 }
        var count = 0
        for index in 1..<samples.count where (samples[index - 1] < 0) != (samples[index] < 0) {
            count += 1
        }
        return count
    }
}

final class SoundPreferencesTests: XCTestCase {
    private static let keys = [SoundPreferences.effectsKey, SoundPreferences.spokenLaunchKey]

    private let defaults = UserDefaults.standard
    private var saved: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        for key in Self.keys {
            if let value = defaults.object(forKey: key) { saved[key] = value }
            defaults.removeObject(forKey: key)
        }
    }

    override func tearDown() {
        // The test host shares standard defaults, so put back whatever was there.
        for key in Self.keys {
            if let value = saved[key] {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        saved = [:]
        super.tearDown()
    }

    func testBothSoundsAreOnUntilSomethingTurnsThemOff() {
        // A fresh install has nothing stored, and should still make noise.
        XCTAssertTrue(SoundPreferences.effectsEnabled)
        XCTAssertTrue(SoundPreferences.spokenLaunchEnabled)
    }

    func testTurningEitherOffIsRespectedIndependently() {
        defaults.set(false, forKey: SoundPreferences.effectsKey)
        XCTAssertFalse(SoundPreferences.effectsEnabled)
        XCTAssertTrue(SoundPreferences.spokenLaunchEnabled, "the voice is a separate switch")

        defaults.set(true, forKey: SoundPreferences.effectsKey)
        defaults.set(false, forKey: SoundPreferences.spokenLaunchKey)
        XCTAssertTrue(SoundPreferences.effectsEnabled)
        XCTAssertFalse(SoundPreferences.spokenLaunchEnabled)
    }

    func testTheKeysAreDistinctSoOneToggleCannotMoveTheOther() {
        XCTAssertNotEqual(SoundPreferences.effectsKey, SoundPreferences.spokenLaunchKey)
    }
}

@MainActor
final class SilentSoundTests: XCTestCase {
    func testItRecordsWhatItWasAskedToPlay() {
        let sound = SilentSound()
        sound.selectionTick()
        sound.selectionTick()
        sound.announceLaunch(of: "Truebearing")
        sound.cancelSpeech()

        XCTAssertEqual(sound.tickCount, 2)
        XCTAssertEqual(sound.announcements, ["Truebearing"])
        XCTAssertEqual(sound.cancelCount, 1)
    }
}
