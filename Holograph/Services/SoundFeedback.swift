import Foundation
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
}

// MARK: - The real thing

#if canImport(AVFoundation)

/// Plays the tick through a single long-lived engine and speaks through
/// `AVSpeechSynthesizer`.
///
/// Everything here is best-effort. The engine is built on first use, never
/// during launch, and any failure leaves the launcher silent rather than
/// broken.
@MainActor
final class SystemSound: SoundPlaying {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let synthesizer = AVSpeechSynthesizer()

    private var clickBuffer: AVAudioPCMBuffer?
    private var hasConfiguredSession = false
    private var engineFailed = false

    func selectionTick() {
        guard SoundPreferences.effectsEnabled, !engineFailed else { return }
        guard let buffer = preparedBuffer() else { return }
        player.scheduleBuffer(buffer, at: nil, options: .interrupts)
        if !player.isPlaying { player.play() }
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

    /// Ambient and mixing: these are decorative sounds, so they respect the
    /// silent switch and never interrupt whatever the user is already playing.
    private func configureSessionIfNeeded() {
        guard !hasConfiguredSession else { return }
        hasConfiguredSession = true
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
            try session.setActive(true, options: [])
        } catch {
            // Leaving the session alone still lets the engine run in most cases.
        }
        #endif
    }

    private func preparedBuffer() -> AVAudioPCMBuffer? {
        if let clickBuffer, engine.isRunning { return clickBuffer }
        configureSessionIfNeeded()

        let samples = HoloClick.waveform()
        guard !samples.isEmpty,
              let format = AVAudioFormat(
                  standardFormatWithSampleRate: HoloClick.sampleRate,
                  channels: 1
              ),
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(samples.count)
              ),
              let channel = buffer.floatChannelData?[0]
        else {
            engineFailed = true
            return nil
        }

        for (index, sample) in samples.enumerated() { channel[index] = sample }
        buffer.frameLength = AVAudioFrameCount(samples.count)

        if player.engine == nil {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
        }

        // An interruption can stop the engine underneath us; starting it again
        // on demand is cheaper than watching for every way that can happen.
        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                engineFailed = true
                return nil
            }
        }

        clickBuffer = buffer
        return buffer
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
