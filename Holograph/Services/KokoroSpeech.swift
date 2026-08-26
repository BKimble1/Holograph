import Foundation
import OSLog

#if canImport(CoreML)
import CoreML
#endif

/// Where Kokoro's model and voice live on this iPad.
///
/// Two places are checked, in order: the app bundle, for a build that ships the
/// model inside it, and Application Support, for one that provisioned it after
/// installing. Nothing here reaches the network — provisioning is somebody
/// else's job, and synthesis must never depend on being online.
enum KokoroModelStore {
    /// The compiled Core ML package. `.mlmodelc` because that is what a model
    /// compiled for the device is called; an `.mlpackage` is the source form.
    static let modelName = "Kokoro"
    static let modelExtension = "mlmodelc"
    /// The style vector for one voice. Kokoro keeps its voices apart from the
    /// model, which is why a single model can speak in many of them.
    static let voiceName = "bm_george"
    static let voiceExtension = "bin"

    /// Where a provisioned model is kept.
    static var supportDirectory: URL? {
        try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appending(path: "Kokoro", directoryHint: .isDirectory)
    }

    static func modelURL(bundle: Bundle = .main) -> URL? {
        if let bundled = bundle.url(forResource: modelName, withExtension: modelExtension) {
            return bundled
        }
        guard let provisioned = supportDirectory?
            .appending(path: "\(modelName).\(modelExtension)") else { return nil }
        return FileManager.default.fileExists(atPath: provisioned.path()) ? provisioned : nil
    }

    static func voiceURL(bundle: Bundle = .main) -> URL? {
        if let bundled = bundle.url(forResource: voiceName, withExtension: voiceExtension) {
            return bundled
        }
        guard let provisioned = supportDirectory?
            .appending(path: "\(voiceName).\(voiceExtension)") else { return nil }
        return FileManager.default.fileExists(atPath: provisioned.path()) ? provisioned : nil
    }

    /// What is missing, phrased for somebody reading Settings rather than a log.
    static func missingDescription(bundle: Bundle = .main) -> String? {
        let hasModel = modelURL(bundle: bundle) != nil
        let hasVoice = voiceURL(bundle: bundle) != nil
        switch (hasModel, hasVoice) {
        case (true, true): return nil
        case (false, true): return "The neural voice model isn’t installed on this iPad."
        case (true, false): return "The neural voice’s British male voice file isn’t installed."
        case (false, false): return "The neural voice isn’t installed on this iPad."
        }
    }
}

/// Kokoro-82M, run locally with Core ML.
///
/// Everything about this is on-device by construction: a compiled Core ML model
/// and a style vector are read from disk, the phrase is turned into tokens
/// here, and the model returns samples. There is no endpoint, no key, and no
/// request — the class does not even import the networking frameworks it would
/// need to make one.
///
/// It is also entirely optional. When the model is not present the engine
/// reports why and renders nothing, and the launcher opens apps exactly as
/// fast as it always did. A launch announcement is a decoration; it is never
/// allowed to be a dependency.
@MainActor
final class KokoroSpeechEngine: NeuralSpeaking {
    private(set) var isReady = false
    private(set) var unavailableReason: String?

    private let logger = Logger(subsystem: "com.idlery.holograph", category: "speech")
    private let bundle: Bundle
    private var hasPrepared = false

    /// Unhurried and level. The default rate clips along, and a raised pitch
    /// reads as eager; neither is the register wanted here. The character is
    /// composure: nothing it says is news to it.
    static let speechRate: Float = 0.94

    #if canImport(CoreML)
    private var model: LoadedKokoroModel?
    #endif
    private var voice: [Float] = []

    init(bundle: Bundle = .main) {
        self.bundle = bundle
        unavailableReason = KokoroModelStore.missingDescription(bundle: bundle)
    }

    func prepare() async {
        guard !hasPrepared else { return }
        hasPrepared = true

        guard let modelURL = KokoroModelStore.modelURL(bundle: bundle),
              let voiceURL = KokoroModelStore.voiceURL(bundle: bundle) else {
            unavailableReason = KokoroModelStore.missingDescription(bundle: bundle)
            logger.info("neural voice not installed; launch announcements stay silent")
            return
        }

        #if canImport(CoreML)
        // Loading and compiling happens away from the main actor: this is the
        // single heaviest thing the app does, and the launcher must stay usable
        // throughout it.
        let loaded: LoadedKokoroModel? = await Task.detached(priority: .utility) {
            let configuration = MLModelConfiguration()
            // The Neural Engine where there is one, the GPU where there is not.
            configuration.computeUnits = .all
            guard let model = try? MLModel(contentsOf: modelURL, configuration: configuration) else {
                return nil
            }
            return LoadedKokoroModel(model: model)
        }.value

        guard let loaded else {
            unavailableReason = "The neural voice model couldn’t be loaded on this iPad."
            logger.error("Kokoro model failed to load")
            return
        }
        model = loaded
        #endif

        guard let style = Self.readVoice(at: voiceURL), !style.isEmpty else {
            unavailableReason = "The neural voice’s voice file couldn’t be read."
            logger.error("Kokoro voice failed to load")
            return
        }
        voice = style
        unavailableReason = nil
        isReady = true
        logger.info("neural voice ready (\(KokoroModelStore.voiceName, privacy: .public))")
    }

    func render(_ phrase: String) async -> SpokenPhrase? {
        guard isReady else { return nil }
        #if canImport(CoreML)
        guard let loaded = model else { return nil }
        let voice = self.voice
        let rate = Self.speechRate
        // Inference off the main actor for the same reason as loading.
        return await Task.detached(priority: .userInitiated) {
            KokoroSynthesis.render(phrase, model: loaded.model, voice: voice, rate: rate)
        }.value
        #else
        return nil
        #endif
    }

    /// Carries a loaded model across an actor boundary.
    ///
    /// `@unchecked Sendable` because `MLModel` is documented as safe to call
    /// `prediction` on from any thread, and after loading this is the only
    /// thing done with it. Nothing here mutates the model.
    #if canImport(CoreML)
    struct LoadedKokoroModel: @unchecked Sendable {
        let model: MLModel
    }
    #endif

    /// A voice is a flat little array of 32-bit floats.
    private static func readVoice(at url: URL) -> [Float]? {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              data.count % MemoryLayout<Float>.size == 0,
              !data.isEmpty else { return nil }
        return data.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self))
        }
    }
}

#if canImport(CoreML)

/// The inference itself, kept out of the engine so the engine stays about
/// lifecycle and this stays about arithmetic.
///
/// `nonisolated` and free of any actor: it is called from a detached task and
/// touches nothing but its arguments.
enum KokoroSynthesis {
    /// Runs one phrase through the model.
    ///
    /// Returns `nil` rather than guessing whenever the model's interface is not
    /// what this expects — a model file that is not the one this was written
    /// against should produce silence and a log line, never noise.
    static func render(
        _ phrase: String,
        model: MLModel,
        voice: [Float],
        rate: Float
    ) -> SpokenPhrase? {
        let logger = Logger(subsystem: "com.idlery.holograph", category: "speech")
        let tokens = KokoroTokenizer.tokens(for: phrase)
        guard !tokens.isEmpty else { return nil }

        let description = model.modelDescription.inputDescriptionsByName
        guard description["input_ids"] != nil, description["style"] != nil else {
            logger.error("Kokoro model does not expose the expected inputs")
            return nil
        }

        do {
            let ids = try MLMultiArray(shape: [1, NSNumber(value: tokens.count)], dataType: .int32)
            for (index, token) in tokens.enumerated() {
                ids[index] = NSNumber(value: token)
            }
            let style = try MLMultiArray(shape: [1, NSNumber(value: voice.count)], dataType: .float32)
            for (index, value) in voice.enumerated() {
                style[index] = NSNumber(value: value)
            }
            let speed = try MLMultiArray(shape: [1], dataType: .float32)
            speed[0] = NSNumber(value: rate)

            var features: [String: MLFeatureValue] = [
                "input_ids": MLFeatureValue(multiArray: ids),
                "style": MLFeatureValue(multiArray: style),
            ]
            if description["speed"] != nil {
                features["speed"] = MLFeatureValue(multiArray: speed)
            }

            let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: features))
            guard let name = output.featureNames.first(where: { output.featureValue(for: $0)?.multiArrayValue != nil }),
                  let waveform = output.featureValue(for: name)?.multiArrayValue else {
                logger.error("Kokoro model returned no waveform")
                return nil
            }

            var samples = [Float](repeating: 0, count: waveform.count)
            for index in 0..<waveform.count {
                samples[index] = waveform[index].floatValue
            }
            // Kokoro is a 24 kHz model.
            return SpokenPhrase(samples: samples, sampleRate: 24_000)
        } catch {
            logger.error("Kokoro synthesis failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

#endif

/// Turns a phrase into the token ids Kokoro's text encoder expects.
///
/// Kokoro is a phoneme model, and a full grapheme-to-phoneme pass is a large
/// piece of machinery in its own right. What is here is the character-level
/// vocabulary the model ships with, which is what its own reference
/// implementation falls back to when no phonemiser is available.
///
/// Pure, so the mapping can be checked without a model.
enum KokoroTokenizer {
    /// Kokoro's vocabulary, in its published order. Index 0 is padding, and the
    /// sequence is wrapped in it at both ends.
    static let alphabet = Array(
        "$;:,.!?¡¿—…\"«»“” ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz"
    )

    static let maximumTokens = 510

    private static let lookup: [Character: Int32] = {
        var table: [Character: Int32] = [:]
        for (index, character) in alphabet.enumerated() {
            table[character] = Int32(index + 1)
        }
        return table
    }()

    static func tokens(for phrase: String) -> [Int32] {
        let body = phrase.unicodeScalars
            .compactMap { lookup[Character($0)] }
            .prefix(maximumTokens)
        guard !body.isEmpty else { return [] }
        // Padded at both ends, which is how the model was trained to see a
        // sequence.
        return [0] + Array(body) + [0]
    }
}
