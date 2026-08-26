import Foundation
import OSLog

#if canImport(AVFoundation)
import AVFoundation
#endif

/// Everything about a system voice that choosing between them depends on.
///
/// A plain struct rather than `AVSpeechSynthesisVoice` so the choice itself can
/// be tested without a device: which voice an iPad ends up with is a fact about
/// that iPad, but *how* the best one is picked is a fact about this app, and
/// only the second one is ours to get right.
struct SystemVoiceDescriptor: Equatable, Sendable {
    let identifier: String
    let name: String
    /// BCP-47, e.g. `en-GB`.
    let language: String
    /// `AVSpeechSynthesisVoiceQuality.rawValue` — default, enhanced, premium,
    /// ascending. Only the ordering is relied on, never the numbers.
    let quality: Int
    let isMale: Bool
}

/// Picks the voice closest to the one the launcher is meant to have: a composed
/// British man.
///
/// Preference runs in this order, and stops at the first thing that exists:
///
/// 1. A British male voice, best quality first. Daniel ships with every iPad,
///    so on a stock device this is what speaks.
/// 2. Any British voice — the accent carries more of the character than the
///    gender does, so an English woman beats an American man.
/// 3. Any English voice at all.
/// 4. Whatever the system says is the default.
///
/// The point of the ladder is that it cannot come up empty. There is no rung
/// that says "install something first".
enum SystemVoiceCatalogue {
    /// Voices Apple ships whose names are known to be male, for the devices
    /// whose voice list does not carry a gender.
    ///
    /// `AVSpeechSynthesisVoice.gender` only exists from iOS 17 and is
    /// `.unspecified` for a good number of the older bundles, so a name check
    /// is the fallback rather than the primary.
    static let knownMaleNames: Set<String> = [
        "Daniel", "Arthur", "Oliver", "Gordon", "Aaron", "Fred", "Alex",
        "Rishi", "Lee", "Tom", "Reed", "Rocko", "Grandpa", "Eddy",
    ]

    static func isProbablyMale(name: String) -> Bool {
        knownMaleNames.contains(name.split(separator: " ").first.map(String.init) ?? name)
    }

    /// The chosen voice, or `nil` only when the list itself is empty.
    static func best(from voices: [SystemVoiceDescriptor]) -> SystemVoiceDescriptor? {
        guard !voices.isEmpty else { return nil }

        // Highest quality wins within a rung; a stable tie-break on identifier
        // keeps the choice the same across launches, which matters because a
        // voice that changes between launches sounds like a bug.
        func best(_ candidates: [SystemVoiceDescriptor]) -> SystemVoiceDescriptor? {
            candidates.max {
                ($0.quality, $1.identifier) < ($1.quality, $0.identifier)
            }
        }

        let british = voices.filter { $0.language.lowercased().hasPrefix("en-gb") }
        if let man = best(british.filter(\.isMale)) { return man }
        if let anyBritish = best(british) { return anyBritish }
        if let english = best(voices.filter { $0.language.lowercased().hasPrefix("en") }) {
            return english
        }
        return best(voices)
    }
}

#if canImport(AVFoundation) && !os(Linux)

/// The voice that is always there.
///
/// It renders through `AVSpeechSynthesizer`'s offline buffer callback rather
/// than by speaking directly, which matters for two reasons. The samples go
/// through the same path as every other sound the launcher makes, so ducking,
/// the silent switch and the microphone hold-off all behave identically
/// whichever engine spoke. And a phrase is rendered once and cached, so the
/// second time you open Mail nothing is synthesised at all.
///
/// This is the floor, not the ceiling: when a neural model is installed
/// `LayeredSpeech` puts it in front. But the floor is never missing, which is
/// the whole point — a fresh install speaks the first time it is asked to,
/// with nothing downloaded and nothing turned on.
@MainActor
final class SystemVoiceSpeechEngine: NeuralSpeaking {
    private(set) var isReady = false
    /// Never set. A device with no voices at all is not a state iOS has, and
    /// pretending otherwise would put a warning in Settings that can never be
    /// acted on.
    private(set) var unavailableReason: String?

    private let logger = Logger(subsystem: "com.idlery.holograph", category: "speech")
    private let synthesizer = AVSpeechSynthesizer()
    private var chosen: SystemVoiceDescriptor?
    private var hasPrepared = false

    /// Unhurried and level, matching the register the neural voice is asked
    /// for. `AVSpeechUtterance.defaultSpeechRate` is 0.5; a shade under it
    /// reads as composed rather than slow.
    static let rate: Float = 0.48
    /// Slightly below centre. The default sits a little bright for a voice
    /// that is meant to sound like it already knew.
    static let pitch: Float = 0.96

    /// What Settings shows, e.g. "Daniel (British English)".
    var voiceDescription: String? {
        guard let chosen else { return nil }
        let language = Locale.current.localizedString(forIdentifier: chosen.language) ?? chosen.language
        return "\(chosen.name) (\(language))"
    }

    func prepare() async {
        guard !hasPrepared else { return }
        hasPrepared = true

        chosen = SystemVoiceCatalogue.best(from: Self.installedVoices())
        isReady = true
        if let chosen {
            logger.info("system voice ready: \(chosen.name, privacy: .public) [\(chosen.language, privacy: .public)]")
        } else {
            logger.info("system voice ready: platform default")
        }
    }

    func render(_ phrase: String) async -> SpokenPhrase? {
        let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !hasPrepared { await prepare() }

        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.rate = Self.rate
        utterance.pitchMultiplier = Self.pitch
        utterance.volume = 1
        if let identifier = chosen?.identifier {
            utterance.voice = AVSpeechSynthesisVoice(identifier: identifier)
        }
        if utterance.voice == nil {
            utterance.voice = AVSpeechSynthesisVoice(language: "en-GB")
        }

        let rendered: SpokenPhrase? = await withCheckedContinuation { continuation in
            let collector = BufferCollector { continuation.resume(returning: $0) }

            // `write` calls back on an arbitrary queue, and calls back a final
            // time with an empty buffer to mark the end. Resuming a
            // continuation twice traps, so which call finishes is decided
            // inside the collector's lock rather than by a captured flag.
            synthesizer.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                guard pcm.frameLength > 0 else { return collector.finish() }
                collector.append(Self.mono(from: pcm), sampleRate: pcm.format.sampleRate)
            }

            // And a net under it. A continuation that is never resumed hangs
            // its task forever, which for the pre-render loop would mean no
            // tile after this one ever gets a phrase. The timeout is far longer
            // than any announcement takes to render, so reaching it means
            // something went wrong rather than something was slow.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.renderTimeout) {
                collector.finish()
            }
        }
        noteIfSilent(rendered, for: trimmed)
        return rendered
    }

    /// Leaves a line in the log when a voice that should have spoken did not.
    ///
    /// Offline rendering is supported by every voice `speechVoices()` returns,
    /// so an empty result is worth knowing about rather than shrugging at —
    /// and the phrase's length rather than its text, because what a user named
    /// their tiles is not something to write to a log.
    private func noteIfSilent(_ rendered: SpokenPhrase?, for phrase: String) {
        guard rendered == nil else { return }
        logger.error("system voice rendered nothing for a phrase of \(phrase.count) characters")
    }

    /// How long a phrase gets to render before the attempt is abandoned.
    static let renderTimeout: TimeInterval = 10

    /// Gathers samples handed over from whichever queue the synthesiser used,
    /// and resumes exactly once.
    ///
    /// `@unchecked Sendable` because every access is inside the lock, which is
    /// the whole of what it does.
    private final class BufferCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var samples: [Float] = []
        private var sampleRate: Double = 0
        private var deliver: ((SpokenPhrase?) -> Void)?

        init(deliver: @escaping (SpokenPhrase?) -> Void) {
            self.deliver = deliver
        }

        func append(_ new: [Float], sampleRate rate: Double) {
            lock.lock()
            defer { lock.unlock() }
            guard deliver != nil else { return }
            sampleRate = rate
            samples.append(contentsOf: new)
        }

        /// Delivers what was gathered, once. Every call after the first does
        /// nothing at all, which is what makes the watchdog safe to fire even
        /// when the synthesiser already finished.
        func finish() {
            lock.lock()
            let callback = deliver
            deliver = nil
            let phrase = samples.isEmpty || sampleRate <= 0
                ? nil
                : SpokenPhrase(samples: samples, sampleRate: sampleRate)
            lock.unlock()
            // Outside the lock: the caller resumes a continuation here, and
            // holding a lock across that is how deadlocks are made.
            callback?(phrase)
        }
    }

    /// Mono float samples, whatever the synthesiser handed back.
    ///
    /// The buffer is normally 16-bit mono, but the format is the system's
    /// choice rather than ours, so every case it can legally be is handled:
    /// float channels are averaged, integer channels are scaled.
    ///
    /// `nonisolated` because it is called from the synthesiser's own queue.
    /// It touches nothing but its argument.
    nonisolated static func mono(from buffer: AVAudioPCMBuffer) -> [Float] {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return [] }
        let channels = Int(buffer.format.channelCount)

        if let data = buffer.floatChannelData {
            return (0..<frames).map { frame in
                var sum: Float = 0
                for channel in 0..<channels { sum += data[channel][frame] }
                return sum / Float(max(1, channels))
            }
        }
        if let data = buffer.int16ChannelData {
            let scale = Float(Int16.max)
            return (0..<frames).map { frame in
                var sum: Float = 0
                for channel in 0..<channels { sum += Float(data[channel][frame]) / scale }
                return sum / Float(max(1, channels))
            }
        }
        if let data = buffer.int32ChannelData {
            let scale = Float(Int32.max)
            return (0..<frames).map { frame in
                var sum: Float = 0
                for channel in 0..<channels { sum += Float(data[channel][frame]) / scale }
                return sum / Float(max(1, channels))
            }
        }
        return []
    }

    private static func installedVoices() -> [SystemVoiceDescriptor] {
        AVSpeechSynthesisVoice.speechVoices().map { voice in
            // `gender` is `.unspecified` for a good number of the older
            // bundles, so the name check is the fallback rather than the
            // primary.
            let male: Bool
            switch voice.gender {
            case .male: male = true
            case .female: male = false
            default: male = SystemVoiceCatalogue.isProbablyMale(name: voice.name)
            }
            return SystemVoiceDescriptor(
                identifier: voice.identifier,
                name: voice.name,
                language: voice.language,
                quality: voice.quality.rawValue,
                isMale: male
            )
        }
    }
}

#else

/// Non-Apple platforms get an engine that is honest about having no voices.
@MainActor
final class SystemVoiceSpeechEngine: NeuralSpeaking {
    private(set) var isReady = false
    private(set) var unavailableReason: String? = "This platform has no speech."
    var voiceDescription: String? { nil }
    func prepare() async {}
    func render(_ phrase: String) async -> SpokenPhrase? { nil }
}

#endif

/// A preferred engine with something underneath it.
///
/// Both are prepared, the preferred one is asked first, and the moment it
/// cannot answer — not installed, failed to load, returned nothing for this
/// particular phrase — the fallback speaks instead. The caller never learns
/// which one it got, and never has to.
///
/// This is what makes "the voice works when you download the app" true without
/// giving up on the better voice: shipping a neural model turns it on, and not
/// shipping one costs nothing but a little quality.
@MainActor
final class LayeredSpeech: NeuralSpeaking {
    private let preferred: NeuralSpeaking
    private let fallback: NeuralSpeaking

    init(preferred: NeuralSpeaking, fallback: NeuralSpeaking) {
        self.preferred = preferred
        self.fallback = fallback
    }

    /// Ready when *anything* can speak.
    var isReady: Bool { preferred.isReady || fallback.isReady }

    /// Only when nothing at all can speak is there something to report. A
    /// missing neural model is not a problem the user has while a voice is
    /// still speaking, and telling them about it would be describing our
    /// packaging rather than their device.
    var unavailableReason: String? {
        isReady ? nil : (fallback.unavailableReason ?? preferred.unavailableReason)
    }

    /// Which engine is actually speaking, for Settings to say plainly.
    var usingPreferred: Bool { preferred.isReady }

    func prepare() async {
        await preferred.prepare()
        // The fallback is cheap to prepare and is needed the moment the
        // preferred engine returns nothing for one awkward phrase, so it is
        // always readied rather than readied on demand.
        await fallback.prepare()
    }

    func render(_ phrase: String) async -> SpokenPhrase? {
        if preferred.isReady, let rendered = await preferred.render(phrase) {
            return rendered
        }
        guard fallback.isReady else { return nil }
        return await fallback.render(phrase)
    }
}
