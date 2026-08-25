import Foundation
import OSLog
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(UIKit)
import UIKit
#endif

/// The launcher's voice: a short synthetic tick as the carousel moves between
/// apps, and a spoken word as one opens.
///
/// Both are accents rather than part of the interaction — every call site treats
/// silence as an acceptable outcome, so a device that cannot start an audio
/// engine simply behaves as it did before.
@MainActor
protocol SoundPlaying: AnyObject {
    /// The carousel settled on a different app.
    func selectionTick()
    /// An app is opening. Announced aloud, e.g. "Opening Truebearing".
    func announceLaunch(of name: String)
    /// Cuts any announcement still in flight, so leaving mid-sentence is quiet.
    func cancelSpeech()
}

// MARK: - Preferences

/// Read at the point of use rather than cached, so a toggle in Settings takes
/// effect on the very next tick without anything having to observe it.
enum SoundPreferences {
    static let effectsKey = "com.idlery.holograph.soundEffectsEnabled"
    static let spokenLaunchKey = "com.idlery.holograph.spokenLaunchEnabled"

    /// Both default to on: the sounds are what was asked for, and Settings can
    /// turn them off.
    static var effectsEnabled: Bool {
        UserDefaults.standard.object(forKey: effectsKey) as? Bool ?? true
    }

    static var spokenLaunchEnabled: Bool {
        UserDefaults.standard.object(forKey: spokenLaunchKey) as? Bool ?? true
    }
}

// MARK: - The click

/// The tick is synthesised rather than shipped as an audio file: it keeps the
/// bundle free of binary assets, and the shape of the sound stays readable and
/// adjustable in one place.
///
/// Pure, and free of any audio machinery, so the waveform can be reasoned about
/// — and tested — without an engine anywhere near it.
enum HoloClick {
    /// A small deterministic generator, so "noise" is the same noise every run.
    /// `arc4random` and friends would make the click untestable for the sake of
    /// randomness nobody can hear.
    struct SplitMix64 {
        private var state: UInt64

        init(seed: UInt64) { state = seed }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }

        /// Uniform in -1…1.
        mutating func nextUnit() -> Double {
            Double(next() >> 11) / Double(1 << 53) * 2 - 1
        }
    }

    static let sampleRate: Double = 44_100
    /// Clicks are brief. Much longer than this and it becomes a tone.
    static let duration: Double = 0.022

    static var frameCount: Int { Int(sampleRate * duration) }

    /// A real click, not a laser.
    ///
    /// A click is a short burst of broadband energy with a resonance in it —
    /// the sound of two small hard things meeting — and it is over in a few
    /// milliseconds. Three parts, all decaying at once:
    ///
    /// - filtered noise, which is what gives it a *tick* rather than a pitch,
    /// - a resonance near 2.4 kHz, the "body" of the thing being struck,
    /// - a low knock for weight, so it lands rather than hisses.
    ///
    /// The earlier version swept 1.7 kHz down to 780 Hz over 60 ms. A falling
    /// sweep is the recipe for a laser, and it read as one.
    static func waveform() -> [Float] {
        let frames = frameCount
        guard frames > 0 else { return [] }

        let resonance = 2_400.0
        let knock = 190.0
        let noiseDecay = 2.6      // amplitude e-folding times, in milliseconds
        let resonanceDecay = 3.4
        let knockDecay = 5.0
        let attack = 0.35

        var samples = [Float](repeating: 0, count: frames)
        var resonancePhase = 0.0
        var knockPhase = 0.0
        // A fixed generator, so the click is the same every time it is heard and
        // the tests have something stable to check.
        var noise = SplitMix64(seed: 0x484F_4C4F_4752_4150)
        // One-pole low pass, to take the fizz off white noise and leave
        // something that sounds struck rather than hissed.
        var filtered = 0.0
        let smoothing = 0.55

        for frame in 0..<frames {
            let milliseconds = Double(frame) / sampleRate * 1_000
            let progress = Double(frame) / Double(frames)

            resonancePhase += 2 * .pi * resonance / sampleRate
            knockPhase += 2 * .pi * knock / sampleRate

            filtered += smoothing * (noise.nextUnit() - filtered)

            var value = filtered * 0.85 * exp(-milliseconds / noiseDecay)
            value += sin(resonancePhase) * 0.42 * exp(-milliseconds / resonanceDecay)
            value += sin(knockPhase) * 0.22 * exp(-milliseconds / knockDecay)

            // Ramp in and fade out, so the buffer neither opens nor closes on a
            // step. A hard edge at either end is heard as an extra click of its
            // own — and at the leading edge it thumps.
            let rampIn = min(1, milliseconds / attack)
            let fadeOut = progress > 0.7 ? (1 - (progress - 0.7) / 0.3) : 1
            samples[frame] = Float(max(-1, min(1, value * 0.55 * rampIn * fadeOut)))
        }
        return samples
    }

    /// The same waveform as a self-contained 16-bit PCM WAV.
    ///
    /// Handing finished bytes to `AVAudioPlayer` is far less to go wrong than
    /// wiring an engine graph for a 60 ms sound, and the file never touches
    /// disk. Pure, so the container can be checked byte for byte in tests.
    static func wavData() -> Data {
        let samples = waveform()
        let channels = 1
        let bitsPerSample = 16
        let bytesPerSample = bitsPerSample / 8
        let byteRate = Int(sampleRate) * channels * bytesPerSample
        let blockAlign = channels * bytesPerSample
        let dataSize = samples.count * bytesPerSample

        var data = Data(capacity: headerByteCount + dataSize)
        func appendASCII(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
        func append32(_ value: Int) {
            withUnsafeBytes(of: UInt32(truncatingIfNeeded: value).littleEndian) {
                data.append(contentsOf: $0)
            }
        }
        func append16(_ value: Int) {
            withUnsafeBytes(of: UInt16(truncatingIfNeeded: value).littleEndian) {
                data.append(contentsOf: $0)
            }
        }

        appendASCII("RIFF")
        append32(36 + dataSize)          // everything after this field
        appendASCII("WAVE")
        appendASCII("fmt ")
        append32(16)                     // PCM fmt chunk size
        append16(1)                      // format: uncompressed PCM
        append16(channels)
        append32(Int(sampleRate))
        append32(byteRate)
        append16(blockAlign)
        append16(bitsPerSample)
        appendASCII("data")
        append32(dataSize)

        for sample in samples {
            let clamped = max(-1, min(1, sample))
            append16(Int(Int16((clamped * 32_767).rounded())))
        }
        return data
    }

    /// RIFF + fmt + data headers, before any samples.
    static let headerByteCount = 44
}

// MARK: - The voice

/// Picks the voice the launcher speaks in: a British woman, calm and composed —
/// the register of an assistant reading something back to you.
///
/// The choice is made over plain descriptions rather than `AVSpeechSynthesisVoice`
/// so the ranking can be tested. Which voices exist depends on the device and on
/// what the owner has downloaded, so this has to degrade rather than assume.
enum HoloVoice {
    struct Candidate: Equatable {
        let identifier: String
        let name: String
        /// BCP-47, e.g. "en-GB".
        let language: String
        let isFemale: Bool
        /// AVSpeechSynthesisVoiceQuality's raw value: default 1, enhanced 2,
        /// premium 3. Higher sounds markedly less synthetic.
        let quality: Int
    }

    /// British female voices Apple ships, best first. Named explicitly because
    /// the API cannot say which of two en-GB voices sounds more like a composed
    /// assistant and which sounds like a station announcement.
    static let preferredNames = ["Serena", "Stephanie", "Kate", "Martha"]

    /// Picks the best available voice, or `nil` to let the system choose.
    ///
    /// British English first; failing that any English, so a device with no
    /// en-GB voice still speaks rather than falling silent.
    static func best(from candidates: [Candidate]) -> Candidate? {
        let british = candidates.filter { $0.language.hasPrefix("en-GB") }
        let pool = british.isEmpty ? candidates.filter { $0.language.hasPrefix("en") } : british
        guard !pool.isEmpty else { return nil }

        // Arrays are not Comparable; the ranking is lexicographic by intent, so
        // say so rather than collapsing it into one number and losing the order.
        return pool.max { first, second in
            rank(first).lexicographicallyPrecedes(rank(second))
        }
    }

    /// Higher sorts better. Ordered by what actually matters to the ear: the
    /// right accent, then the right voice, then how good the recording is.
    private static func rank(_ candidate: Candidate) -> [Int] {
        let namePreference = preferredNames.firstIndex(of: candidate.name)
            .map { preferredNames.count - $0 } ?? 0
        return [
            candidate.language.hasPrefix("en-GB") ? 1 : 0,
            candidate.isFemale ? 1 : 0,
            namePreference,
            candidate.quality,
        ]
    }
}

// MARK: - The real thing

#if canImport(AVFoundation)

/// Plays the tick from an in-memory WAV and speaks through `AVSpeechSynthesizer`.
///
/// Everything here is best-effort: nothing is built during launch, and any
/// failure leaves the launcher silent rather than broken.
@MainActor
final class SystemSound: SoundPlaying {
    private let synthesizer = AVSpeechSynthesizer()
    private let logger = Logger(subsystem: "com.idlery.holograph", category: "sound")

    /// A small pool, so a quick flick through the carousel still sounds like one
    /// tick per app instead of each one cutting off the last.
    private var players: [AVAudioPlayer] = []
    private var rotation = 0
    private var buildAttempts = 0
    private var hasConfiguredSession = false
    private var cachedVoice: AVSpeechSynthesisVoice?

    private static let poolSize = 3
    private static let maximumBuildAttempts = 3

    func selectionTick() {
        guard SoundPreferences.effectsEnabled, let player = availablePlayer() else { return }
        player.currentTime = 0
        player.play()
    }

    func announceLaunch(of name: String) {
        guard SoundPreferences.spokenLaunchEnabled else { return }
        #if canImport(UIKit)
        // VoiceOver is already describing what the user just did; talking over
        // it would be worse than saying nothing.
        guard !UIAccessibility.isVoiceOverRunning else { return }
        #endif
        configureSessionIfNeeded()

        let utterance = AVSpeechUtterance(string: "Opening \(name)")
        utterance.voice = preferredVoice()
        // Unhurried and level. The default rate clips along, and a raised pitch
        // reads as eager; neither is the register wanted here.
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.94
        utterance.pitchMultiplier = 0.98
        utterance.postUtteranceDelay = 0
        utterance.volume = 0.95
        synthesizer.speak(utterance)
    }

    func cancelSpeech() {
        guard synthesizer.isSpeaking else { return }
        synthesizer.stopSpeaking(at: .immediate)
    }

    /// Resolved once — enumerating every installed voice on each launch would be
    /// wasted work — and `nil` if nothing suitable exists, which leaves the
    /// system to pick rather than saying nothing.
    private func preferredVoice() -> AVSpeechSynthesisVoice? {
        if let cachedVoice { return cachedVoice }
        let candidates = AVSpeechSynthesisVoice.speechVoices().map { voice in
            HoloVoice.Candidate(
                identifier: voice.identifier,
                name: voice.name,
                language: voice.language,
                isFemale: voice.gender == .female,
                quality: voice.quality.rawValue
            )
        }
        guard let choice = HoloVoice.best(from: candidates) else { return nil }
        logger.info("speaking with \(choice.name, privacy: .public) (\(choice.language, privacy: .public))")
        cachedVoice = AVSpeechSynthesisVoice(identifier: choice.identifier)
        return cachedVoice
    }

    // MARK: - Setup

    /// `.playback` rather than `.ambient`.
    ///
    /// Ambient audio is silenced by the Ring/Silent switch — on an iPad, the
    /// toggle in Control Centre — which mutes the tick and the announcement
    /// alike and looks exactly like the feature not working. These sounds are
    /// asked for rather than incidental, and Settings carries a switch for each,
    /// so they play on their own terms. `.mixWithOthers` keeps them from
    /// interrupting anything already playing.
    private func configureSessionIfNeeded() {
        guard !hasConfiguredSession else { return }
        hasConfiguredSession = true
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true, options: [])
        } catch {
            logger.error("audio session unavailable: \(error.localizedDescription, privacy: .public)")
        }
        #endif
    }

    private func availablePlayer() -> AVAudioPlayer? {
        if players.isEmpty { buildPlayers() }
        guard !players.isEmpty else { return nil }
        // An idle player keeps overlapping ticks intact; otherwise take the next
        // in rotation, which is the one that started longest ago.
        if let idle = players.first(where: { !$0.isPlaying }) { return idle }
        defer { rotation = (rotation + 1) % players.count }
        return players[rotation]
    }

    private func buildPlayers() {
        guard buildAttempts < Self.maximumBuildAttempts else { return }
        buildAttempts += 1
        configureSessionIfNeeded()

        let data = HoloClick.wavData()
        players = (0..<Self.poolSize).compactMap { _ in
            do {
                let player = try AVAudioPlayer(data: data, fileTypeHint: AVFileType.wav.rawValue)
                player.volume = 0.9
                player.prepareToPlay()
                return player
            } catch {
                logger.error("click unavailable: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
    }
}

#else

/// Non-Apple platforms get silence rather than a build error.
@MainActor
final class SystemSound: SoundPlaying {
    func selectionTick() {}
    func announceLaunch(of name: String) {}
    func cancelSpeech() {}
}

#endif

// MARK: - Test double

/// Used by previews, unit tests and the UI suite, which must stay silent and
/// deterministic.
@MainActor
final class SilentSound: SoundPlaying {
    private(set) var tickCount = 0
    private(set) var announcements: [String] = []
    private(set) var cancelCount = 0

    func selectionTick() { tickCount += 1 }
    func announceLaunch(of name: String) { announcements.append(name) }
    func cancelSpeech() { cancelCount += 1 }
}
