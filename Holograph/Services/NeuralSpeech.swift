import Foundation

/// A rendered phrase: mono PCM, and how long it lasts.
///
/// Deliberately not an audio-engine type. Whatever generated it — a neural
/// model, a test double — hands back numbers, and the sound service decides how
/// to play them.
struct SpokenPhrase: Equatable, Sendable {
    /// Mono samples in -1…1.
    let samples: [Float]
    let sampleRate: Double

    var duration: TimeInterval {
        guard sampleRate > 0 else { return 0 }
        return Double(samples.count) / sampleRate
    }

    init(samples: [Float], sampleRate: Double) {
        self.samples = samples
        self.sampleRate = sampleRate
    }
}

/// Something that speaks a short phrase, on this device.
///
/// Behind a protocol for the usual reason and one more: the real engine loads a
/// neural model weighing rather more than the rest of the app put together, and
/// no unit test should ever wait for that.
@MainActor
protocol NeuralSpeaking: AnyObject {
    /// Whether a phrase asked for right now would come back with audio.
    var isReady: Bool { get }
    /// Why it is not ready, for Settings to explain rather than leaving the
    /// user with unexplained silence.
    var unavailableReason: String? { get }
    /// Loads whatever needs loading. Safe to call more than once, and never on
    /// the path to opening an app.
    func prepare() async
    /// Renders a phrase, or `nil` if it cannot. Never throws: a launcher that
    /// fails to open an app because a decoration failed would be absurd.
    func render(_ phrase: String) async -> SpokenPhrase?
}

// MARK: - What gets said

/// The words. Pure, and separate from anything that says them, so what the
/// launcher announces is a fact about the library rather than about the engine.
enum LaunchAnnouncement {
    /// `nil` for anything that should not be announced.
    ///
    /// A folder is deliberately silent. Opening one does not leave Holograph
    /// and takes a fraction of a second, and narrating it would make a movement
    /// *inside* the launcher sound like a departure from it. The carousel's own
    /// tick already marks it.
    static func phrase(for item: LauncherItem) -> String? {
        switch item.kind {
        case .folder:
            return nil
        case .app, .website:
            let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            return "Opening \(name)"
        }
    }

    /// What a cached rendering is filed under.
    ///
    /// The name is part of the key on purpose: renaming a tile has to change
    /// what is said about it, and a key that was only the id would keep
    /// announcing the old name until the app was reinstalled.
    static func cacheKey(for item: LauncherItem) -> String {
        "\(item.id.uuidString)|\(item.name)"
    }
}

/// A small, bounded store of rendered phrases.
///
/// Bounded because these are audio buffers, and a library of a hundred tiles
/// that has been renamed a few times would otherwise sit in memory forever.
/// Least-recently-used, which for a launcher means "the tiles you actually
/// open" stay warm.
struct AnnouncementCache {
    private(set) var limit: Int
    private var entries: [String: SpokenPhrase] = [:]
    private var order: [String] = []

    init(limit: Int = 24) {
        self.limit = max(1, limit)
    }

    var count: Int { entries.count }

    mutating func phrase(forKey key: String) -> SpokenPhrase? {
        guard let phrase = entries[key] else { return nil }
        touch(key)
        return phrase
    }

    func contains(_ key: String) -> Bool { entries[key] != nil }

    mutating func store(_ phrase: SpokenPhrase, forKey key: String) {
        entries[key] = phrase
        touch(key)
        while order.count > limit, let oldest = order.first {
            order.removeFirst()
            entries[oldest] = nil
        }
    }

    /// Drops everything that is no longer reachable from the library — which
    /// after a rename is the old name's rendering.
    mutating func keepOnly(_ keys: Set<String>) {
        for key in entries.keys where !keys.contains(key) {
            entries[key] = nil
        }
        order.removeAll { !keys.contains($0) }
    }

    mutating func removeAll() {
        entries.removeAll()
        order.removeAll()
    }

    private mutating func touch(_ key: String) {
        order.removeAll { $0 == key }
        order.append(key)
    }
}

// MARK: - Test double

/// Used by previews, unit tests and the UI suite. Loads nothing, and renders a
/// silent buffer of a believable length so timing-dependent behaviour — how
/// long the microphone is asked to look away, for one — is still exercised.
@MainActor
final class StubNeuralSpeech: NeuralSpeaking {
    private(set) var isReady: Bool
    private(set) var unavailableReason: String?
    private(set) var prepareCount = 0
    private(set) var rendered: [String] = []

    /// Roughly the pace of the real voice, so a stubbed duration is a fair
    /// stand-in for a real one.
    static let secondsPerCharacter = 0.062
    static let sampleRate: Double = 24_000

    init(isReady: Bool = true, unavailableReason: String? = nil) {
        self.isReady = isReady
        self.unavailableReason = unavailableReason
    }

    func prepare() async {
        prepareCount += 1
    }

    func render(_ phrase: String) async -> SpokenPhrase? {
        rendered.append(phrase)
        guard isReady else { return nil }
        let seconds = 0.35 + Double(phrase.count) * Self.secondsPerCharacter
        return SpokenPhrase(
            samples: [Float](repeating: 0, count: Int(seconds * Self.sampleRate)),
            sampleRate: Self.sampleRate
        )
    }
}
