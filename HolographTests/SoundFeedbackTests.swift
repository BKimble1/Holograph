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

/// The click is handed to AVAudioPlayer as finished bytes, so the container it
/// is wrapped in has to be right — a malformed header is silence with no error.
final class HoloClickWAVTests: XCTestCase {
    private lazy var data = HoloClick.wavData()

    private func ascii(at offset: Int, length: Int = 4) -> String {
        String(decoding: data[offset..<(offset + length)], as: UTF8.self)
    }

    private func uint32(at offset: Int) -> UInt32 {
        data[offset..<(offset + 4)].reversed().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    private func uint16(at offset: Int) -> UInt16 {
        data[offset..<(offset + 2)].reversed().reduce(UInt16(0)) { ($0 << 8) | UInt16($1) }
    }

    func testItIsARIFFWaveFile() {
        XCTAssertEqual(ascii(at: 0), "RIFF")
        XCTAssertEqual(ascii(at: 8), "WAVE")
        XCTAssertEqual(ascii(at: 12), "fmt ")
        XCTAssertEqual(ascii(at: 36), "data")
    }

    func testTheFormatChunkDescribesMono16BitPCM() {
        XCTAssertEqual(uint32(at: 16), 16, "PCM fmt chunks are 16 bytes")
        XCTAssertEqual(uint16(at: 20), 1, "1 means uncompressed PCM")
        XCTAssertEqual(uint16(at: 22), 1, "mono")
        XCTAssertEqual(uint32(at: 24), UInt32(HoloClick.sampleRate))
        XCTAssertEqual(uint16(at: 34), 16, "16 bits per sample")
    }

    func testTheDerivedRatesAgreeWithTheFormat() {
        let blockAlign = uint16(at: 32)
        XCTAssertEqual(blockAlign, 2, "mono 16-bit is two bytes per frame")
        XCTAssertEqual(uint32(at: 28), UInt32(HoloClick.sampleRate) * UInt32(blockAlign))
    }

    func testTheDeclaredSizesMatchTheActualBytes() {
        let dataSize = uint32(at: 40)
        XCTAssertEqual(Int(dataSize), HoloClick.frameCount * 2)
        XCTAssertEqual(data.count, HoloClick.headerByteCount + Int(dataSize))
        // The RIFF size counts everything after its own field.
        XCTAssertEqual(uint32(at: 4), UInt32(data.count - 8))
    }

    func testTheSamplesSurviveTheRoundTripToPCM() {
        let source = HoloClick.waveform()
        for (index, expected) in source.enumerated() {
            let offset = HoloClick.headerByteCount + index * 2
            let stored = Int16(bitPattern: uint16(at: offset))
            XCTAssertEqual(
                Float(stored) / 32_767, expected, accuracy: 0.001,
                "sample \(index) should survive quantisation"
            )
        }
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
