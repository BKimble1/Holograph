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
    static let sampleRate: Double = 44_100
    static let duration: Double = 0.06

    static var frameCount: Int { Int(sampleRate * duration) }

    /// A descending two-partial chirp under a sharp exponential decay, with a
    /// brief bright transient on the leading edge, ramped in over 0.8 ms and
    /// faded out at the tail.
    ///
    /// The downward sweep is what makes it read as synthetic rather than
    /// mechanical; the transient is what makes it read as a *click* rather than
    /// a beep.
    static func waveform() -> [Float] {
        let frames = frameCount
        guard frames > 0 else { return [] }

        let startFrequency = 1_720.0
        let endFrequency = 780.0
        let decay = 18.0          // amplitude e-folding time in milliseconds
        let transientDecay = 5.0
        // Short enough to still read as a click, long enough that the buffer
        // does not open on a step.
        let attack = 0.8

        var samples = [Float](repeating: 0, count: frames)
        // Phase is integrated rather than computed per sample: a sweep needs the
        // running total, and sin(2π·f(t)·t) would chirp at the wrong rate.
        var phase = 0.0
        var octavePhase = 0.0

        for frame in 0..<frames {
            let seconds = Double(frame) / sampleRate
            let milliseconds = seconds * 1_000
            let progress = Double(frame) / Double(frames)

            let frequency = startFrequency + (endFrequency - startFrequency) * progress
            phase += 2 * .pi * frequency / sampleRate
            octavePhase += 2 * .pi * (frequency * 2) / sampleRate

            let envelope = exp(-milliseconds / decay)
            let transient = exp(-milliseconds / transientDecay)

            var value = sin(phase) * 0.62 * envelope
            value += sin(octavePhase) * 0.18 * envelope
            value += sin(phase * 3.1) * 0.20 * transient

            // Ramp in and fade out, so the buffer neither opens nor closes on a
            // step. A hard edge at either end is heard as an extra click of its
            // own — and at the leading edge it thumps.
            let rampIn = min(1, milliseconds / attack)
            let fadeOut = progress > 0.85 ? (1 - (progress - 0.85) / 0.15) : 1
            samples[frame] = Float(max(-1, min(1, value * 0.42 * rampIn * fadeOut)))
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
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.02
        utterance.pitchMultiplier = 1.06
        utterance.postUtteranceDelay = 0
        utterance.volume = 0.9
        synthesizer.speak(utterance)
    }

    func cancelSpeech() {
        guard synthesizer.isSpeaking else { return }
        synthesizer.stopSpeaking(at: .immediate)
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
