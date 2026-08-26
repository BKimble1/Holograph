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

    /// Called whenever this makes a noise, with roughly how long it will last.
    ///
    /// The microphone hears the iPad's own speaker as clearly as it hears the
    /// room, and two carousel ticks in quick succession are a textbook double
    /// clap. Whoever is listening gets told to look away.
    var onOwnSound: ((TimeInterval) -> Void)? { get set }
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

// MARK: - The session

/// One place decides what the audio session is for.
///
/// Two features want it and want different things: the tick and the voice need
/// playback, and clap-to-open needs the microphone. Whichever configured itself
/// last used to win, which is a coin toss dressed up as a bug. Here the answer
/// is simply "recording if anything is listening, playback otherwise", and both
/// callers go through it.
@MainActor
enum HoloAudioSession {
    private static var listenerCount = 0
    private static var applied: Bool?

    /// Something needs the microphone.
    static func requireInput() {
        listenerCount += 1
        apply()
    }

    /// And has finished with it.
    static func releaseInput() {
        listenerCount = max(0, listenerCount - 1)
        apply()
    }

    /// Something is about to play a sound.
    static func activate() {
        apply()
    }

    private static var wantsInput: Bool { listenerCount > 0 }

    private static func apply() {
        #if os(iOS)
        guard applied != wantsInput else { return }
        applied = wantsInput
        let logger = Logger(subsystem: "com.idlery.holograph", category: "sound")
        let session = AVAudioSession.sharedInstance()
        do {
            // `.playback` rather than `.ambient`: ambient audio is silenced by
            // the Ring/Silent switch — on an iPad, the toggle in Control Centre
            // — which mutes the tick and the announcement alike and looks
            // exactly like the feature not working. These sounds are asked for
            // rather than incidental, and Settings carries a switch for each, so
            // they play on their own terms. `.mixWithOthers` keeps them from
            // interrupting anything already playing, and `.defaultToSpeaker`
            // keeps them out of the earpiece once recording is in the mix.
            if wantsInput {
                try session.setCategory(
                    .playAndRecord, mode: .default,
                    options: [.mixWithOthers, .defaultToSpeaker, .allowBluetooth]
                )
            } else {
                try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            }
            try session.setActive(true, options: [])
        } catch {
            logger.error("audio session unavailable: \(error.localizedDescription, privacy: .public)")
        }
        #endif
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

/// Picks the voice the launcher speaks in: a British man, measured and dry —
/// the register of an assistant who has already done the thinking.
///
/// The choice is made over plain descriptions rather than `AVSpeechSynthesisVoice`
/// so the ranking can be tested. Which voices exist depends on the device and on
/// what the owner has downloaded, so this has to degrade rather than assume.
enum HoloVoice {
    enum ReportedGender: Equatable {
        case female
        case male
        case unspecified
    }

    struct Candidate: Equatable {
        let identifier: String
        let name: String
        /// BCP-47, e.g. "en-GB".
        let language: String
        let reportedGender: ReportedGender
        /// AVSpeechSynthesisVoiceQuality's raw value: default 1, enhanced 2,
        /// premium 3. Higher sounds markedly less synthetic, which matters more
        /// here than anywhere else — the whole effect is the delivery.
        let quality: Int
    }

    /// Apple's English voices, by name.
    ///
    /// The API's own gender is not enough: plenty of installed voices report
    /// `.unspecified`, so a ranking that trusts it alone ends up choosing on
    /// quality and accent and taking whoever happens to be there. Naming them is
    /// what makes the choice deliberate.
    static let maleNames: Set<String> = [
        "Daniel", "Oliver", "Arthur", "Malcolm", "Graham",
        "Alex", "Fred", "Tom", "Aaron", "Rishi", "Gordon", "Lee",
    ]

    static let femaleNames: Set<String> = [
        "Serena", "Stephanie", "Kate", "Martha", "Fiona", "Emily",
        "Samantha", "Ava", "Allison", "Susan", "Zoe", "Nicky",
        "Karen", "Catherine", "Moira", "Tessa",
    ]

    /// British men, best first. Daniel is Apple's long-standing Received
    /// Pronunciation voice and by far the closest thing on the device to the
    /// unhurried English butler the brief asks for.
    static let preferredNames = ["Daniel", "Oliver", "Arthur", "Graham", "Malcolm"]

    static func isMale(_ candidate: Candidate) -> Bool {
        if femaleNames.contains(candidate.name) { return false }
        if maleNames.contains(candidate.name) { return true }
        return candidate.reportedGender == .male
    }

    /// Picks the best available voice, or `nil` to let the system choose.
    static func best(from candidates: [Candidate]) -> Candidate? {
        let english = candidates.filter { $0.language.hasPrefix("en") }
        guard !english.isEmpty else { return nil }
        return english.max { first, second in
            rank(first).lexicographicallyPrecedes(rank(second))
        }
    }

    /// Higher sorts better.
    ///
    /// Being a man outranks the accent: an English-speaking man is a nearer miss
    /// than a British woman, and a device with no British voice installed should
    /// still sound like the same character.
    private static func rank(_ candidate: Candidate) -> [Int] {
        let namePreference = preferredNames.firstIndex(of: candidate.name)
            .map { preferredNames.count - $0 } ?? 0
        return [
            isMale(candidate) ? 1 : 0,
            candidate.language.hasPrefix("en-GB") ? 1 : 0,
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
    var onOwnSound: ((TimeInterval) -> Void)?

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
        // The tick itself is over in twenty milliseconds; the quarter second
        // covers the speaker settling and the room's answer to it.
        onOwnSound?(0.25)
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
        // Slower and a shade lower than default. The character is composure:
        // nothing it says is news to it.
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.90
        utterance.pitchMultiplier = 0.92
        utterance.postUtteranceDelay = 0
        utterance.volume = 0.95
        synthesizer.speak(utterance)
        onOwnSound?(Self.spokenDuration(of: utterance.speechString))
    }

    /// Roughly how long a phrase takes at the rate above. Only ever used to
    /// decide how long to stop listening for, so approximate is enough — and
    /// erring long is the safe direction.
    static func spokenDuration(of phrase: String) -> TimeInterval {
        min(6, 1.2 + Double(phrase.count) * 0.075)
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
            let gender: HoloVoice.ReportedGender
            switch voice.gender {
            case .female: gender = .female
            case .male: gender = .male
            default: gender = .unspecified
            }
            return HoloVoice.Candidate(
                identifier: voice.identifier,
                name: voice.name,
                language: voice.language,
                reportedGender: gender,
                quality: voice.quality.rawValue
            )
        }
        guard let choice = HoloVoice.best(from: candidates) else { return nil }
        logger.info("speaking with \(choice.name, privacy: .public) (\(choice.language, privacy: .public))")
        cachedVoice = AVSpeechSynthesisVoice(identifier: choice.identifier)
        return cachedVoice
    }

    // MARK: - Setup

    /// The category itself is decided by `HoloAudioSession`, which is the only
    /// thing that knows whether anything else on this device wants the
    /// microphone at the same time.
    private func configureSessionIfNeeded() {
        guard !hasConfiguredSession else { return }
        hasConfiguredSession = true
        HoloAudioSession.activate()
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
    var onOwnSound: ((TimeInterval) -> Void)?

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
    var onOwnSound: ((TimeInterval) -> Void)?

    private(set) var tickCount = 0
    private(set) var announcements: [String] = []
    private(set) var cancelCount = 0

    func selectionTick() { tickCount += 1 }
    func announceLaunch(of name: String) { announcements.append(name) }
    func cancelSpeech() { cancelCount += 1 }
}
