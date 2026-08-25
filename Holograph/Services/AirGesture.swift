import Foundation

/// A hand flicked across the front of the screen.
enum AirSwipe: Equatable, Sendable {
    case left
    case right
}

/// Something that watches for air swipes. Behind a protocol so the launcher can
/// be driven by a stub in previews and tests, where there is no camera at all.
@MainActor
protocol AirGestureObserving: AnyObject {
    /// Called on the main actor for each recognised swipe.
    var onSwipe: ((AirSwipe) -> Void)? { get set }
    var isWatching: Bool { get }
    func start()
    func stop()
}

// MARK: - Preferences

enum AirGesturePreferences {
    static let enabledKey = "com.idlery.holograph.airGesturesEnabled"

    /// Off until asked for: it runs the camera, so it is opt-in rather than
    /// something a new install starts doing unannounced.
    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }
}

// MARK: - The detector

/// Turns a stream of hand positions into swipes.
///
/// This is the whole of the gesture logic, kept as a value type over plain
/// numbers so it can be exercised without a camera, a hand, or a running app —
/// the camera's only job is to supply `(x, time)` and say when the hand is gone.
///
/// `x` is the hand's horizontal position in the frame, 0…1, already oriented so
/// that larger means further to the user's right.
struct AirSwipeDetector {
    struct Thresholds: Equatable {
        /// Fraction of the frame the hand must cross. A quarter of the frame is
        /// a deliberate flick at arm's length, not a drift or a reach for the
        /// screen.
        var travel: Double = 0.22
        /// A swipe is a flick. Slower than this is someone moving their hand
        /// across the room, or reaching past the iPad.
        var speed: Double = 0.55
        /// How straight the path has to be: |net displacement| ÷ |path length|.
        /// A there-and-back wave scores near zero and is ignored.
        var straightness: Double = 0.7
        /// Motion older than this is not part of the current flick.
        var window: TimeInterval = 0.45
        /// The shortest gesture worth believing; anything faster is jitter.
        var minimumDuration: TimeInterval = 0.06
        /// Quiet time after firing, long enough for the hand to travel back
        /// without that return stroke reading as the opposite swipe.
        var cooldown: TimeInterval = 0.65
        /// Below this many samples there is not enough of a path to judge.
        var minimumSamples: Int = 3

        static let `default` = Thresholds()
    }

    private struct Sample {
        let x: Double
        let time: TimeInterval
    }

    private var samples: [Sample] = []
    private var lastFired: TimeInterval?
    let thresholds: Thresholds

    init(thresholds: Thresholds = .default) {
        self.thresholds = thresholds
    }

    /// Feeds one observation. Returns a swipe on the frame that completes it.
    mutating func handSeen(atX x: Double, time: TimeInterval) -> AirSwipe? {
        // Out-of-order frames would corrupt the path; the camera can deliver
        // them after a stall.
        if let last = samples.last, time <= last.time { return nil }

        samples.append(Sample(x: x, time: time))
        samples.removeAll { time - $0.time > thresholds.window }

        if let lastFired, time - lastFired < thresholds.cooldown { return nil }
        guard samples.count >= thresholds.minimumSamples,
              let first = samples.first else { return nil }

        let displacement = x - first.x
        let duration = time - first.time
        guard duration >= thresholds.minimumDuration else { return nil }

        let distance = abs(displacement)
        guard distance >= thresholds.travel,
              distance / duration >= thresholds.speed else { return nil }

        // Total variation: how far the hand actually travelled, including any
        // doubling back. A flick's displacement is nearly all of it.
        var pathLength = 0.0
        for index in 1..<samples.count {
            pathLength += abs(samples[index].x - samples[index - 1].x)
        }
        guard pathLength > 0, distance / pathLength >= thresholds.straightness else { return nil }

        lastFired = time
        samples.removeAll()
        return displacement > 0 ? .right : .left
    }

    /// The hand left the frame. Whatever path was building is not a gesture.
    mutating func handLost() {
        samples.removeAll()
    }

    /// Exposed for tests; the camera never needs it.
    var sampleCount: Int { samples.count }
}

// MARK: - Test double

/// Used by previews, unit tests and the UI suite. Never touches the camera, and
/// lets a test drive the launcher by hand.
@MainActor
final class InertAirGestureSource: AirGestureObserving {
    var onSwipe: ((AirSwipe) -> Void)?
    private(set) var isWatching = false
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start() {
        isWatching = true
        startCount += 1
    }

    func stop() {
        isWatching = false
        stopCount += 1
    }

    /// Simulates a swipe, so the wiring can be tested without a camera.
    func emit(_ swipe: AirSwipe) {
        onSwipe?(swipe)
    }
}
