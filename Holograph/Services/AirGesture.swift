import Foundation

/// A hand flicked across the front of the screen.
enum AirSwipe: Equatable, Sendable {
    case left
    case right
}

/// Something the hand did in front of the screen.
enum AirGesture: Equatable, Sendable {
    case swipe(AirSwipe)
    /// Fingers gathered together and then thrown open — opens the centred app.
    case burst
}

/// Something that watches for air gestures. Behind a protocol so the launcher
/// can be driven by a stub in previews and tests, where there is no camera.
@MainActor
protocol AirGestureObserving: AnyObject {
    /// Called on the main actor for each recognised gesture.
    var onGesture: ((AirGesture) -> Void)? { get set }
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

// MARK: - What the camera saw

/// One frame's worth of hand, in units of its own size.
///
/// Measuring against the hand rather than the frame is what makes the gesture
/// work at any distance. The same six-inch flick covers half the frame at a
/// foot and a quarter of it at two, but it is always about 1.8 knuckle-spans —
/// so every threshold here is expressed in spans, and none of them care how far
/// away the person is standing.
struct HandReading: Equatable {
    /// Where the hand sits across the frame, in spans from the left edge.
    var x: Double
    /// How far the fingertips sit from their own centre, in spans. Fingers
    /// pinched together read low; a splayed hand reads high.
    var spread: Double

    init(x: Double, spread: Double) {
        self.x = x
        self.spread = spread
    }
}

// MARK: - The detector

/// Turns a stream of hand readings into gestures.
///
/// The whole of the gesture logic, kept as a value type over plain numbers so it
/// can be exercised without a camera, a hand, or a running app — the camera's
/// only job is to supply readings and say when the hand is gone.
struct AirGestureDetector {
    struct Thresholds: Equatable {
        /// How far the hand must travel, in its own spans. A hand is about 3.3
        /// inches across the knuckles, so this is roughly a six-inch flick — at
        /// any distance.
        var travelSpans: Double = 1.8
        /// And how briskly, in spans per second: about fifteen inches a second.
        /// Slower than this is someone reaching past the iPad.
        var speedSpans: Double = 3.5
        /// How straight the path has to be: |net displacement| ÷ |path length|.
        var straightness: Double = 0.75
        /// Motion older than this is not part of the current flick.
        var window: TimeInterval = 0.5
        /// The shortest gesture worth believing; faster is jitter.
        var minimumDuration: TimeInterval = 0.08

        /// Quiet time before the *same* flick counts again. Short, because
        /// repeating a deliberate gesture should feel immediate.
        var repeatCooldown: TimeInterval = 0.45
        /// Quiet time before the *opposite* flick counts. Long, because after
        /// flicking one way the hand has to come back, and that return journey
        /// is not a gesture — it is the cost of having made one.
        var reverseCooldown: TimeInterval = 1.5

        /// Fingers must gather at least this close before a burst can start.
        var gatheredSpread: Double = 0.62
        /// And open at least this wide to finish one.
        var burstSpread: Double = 1.0
        /// Opening by less than this is a hand relaxing, not a burst.
        var burstGrowth: Double = 0.42
        /// A burst is a single quick action, not a slow unfurling.
        var burstWindow: TimeInterval = 0.55
        var burstCooldown: TimeInterval = 1.2

        /// Below this many samples there is not enough of a path to judge.
        var minimumSamples: Int = 3

        static let `default` = Thresholds()
    }

    private struct Sample {
        let reading: HandReading
        let time: TimeInterval
    }

    private var samples: [Sample] = []
    private var lastGesture: (kind: AirGesture, time: TimeInterval)?
    let thresholds: Thresholds

    init(thresholds: Thresholds = .default) {
        self.thresholds = thresholds
    }

    /// Feeds one observation. Returns a gesture on the frame that completes it.
    mutating func handSeen(_ reading: HandReading, time: TimeInterval) -> AirGesture? {
        // Out-of-order frames would corrupt the path; the camera can deliver
        // them after a stall.
        if let last = samples.last, time <= last.time { return nil }

        samples.append(Sample(reading: reading, time: time))
        samples.removeAll { time - $0.time > max(thresholds.window, thresholds.burstWindow) }

        // A burst happens in place, so it is checked first: a hand that has
        // barely moved cannot be mid-flick anyway.
        if let burst = burst(at: time) { return fire(burst, at: time) }
        if let swipe = swipe(at: time) { return fire(swipe, at: time) }
        return nil
    }

    /// The hand left the frame. Whatever path was building is not a gesture.
    mutating func handLost() {
        samples.removeAll()
    }

    /// Exposed for tests; the camera never needs it.
    var sampleCount: Int { samples.count }

    // MARK: - Recognition

    private func swipe(at time: TimeInterval) -> AirGesture? {
        let recent = samples.filter { time - $0.time <= thresholds.window }
        guard recent.count >= thresholds.minimumSamples,
              let first = recent.first, let last = recent.last else { return nil }

        let displacement = last.reading.x - first.reading.x
        let duration = time - first.time
        guard duration >= thresholds.minimumDuration else { return nil }

        let distance = abs(displacement)
        guard distance >= thresholds.travelSpans,
              distance / duration >= thresholds.speedSpans else { return nil }

        // Total variation: how far the hand actually travelled, doubling back
        // included. A flick's displacement is nearly all of it.
        var pathLength = 0.0
        for index in 1..<recent.count {
            pathLength += abs(recent[index].reading.x - recent[index - 1].reading.x)
        }
        guard pathLength > 0, distance / pathLength >= thresholds.straightness else { return nil }

        let direction: AirSwipe = displacement > 0 ? .right : .left
        guard isAllowed(.swipe(direction), at: time) else { return nil }
        return .swipe(direction)
    }

    private func burst(at time: TimeInterval) -> AirGesture? {
        let recent = samples.filter { time - $0.time <= thresholds.burstWindow }
        guard recent.count >= thresholds.minimumSamples, let last = recent.last else { return nil }
        guard last.reading.spread >= thresholds.burstSpread else { return nil }

        // The tightest the fingers got before opening. Anything after the
        // gathering is the burst itself.
        guard let gathered = recent.dropLast().min(by: { $0.reading.spread < $1.reading.spread }),
              gathered.reading.spread <= thresholds.gatheredSpread,
              gathered.time < last.time else { return nil }

        let growth = last.reading.spread - gathered.reading.spread
        guard growth >= thresholds.burstGrowth else { return nil }
        guard isAllowed(.burst, at: time) else { return nil }
        return .burst
    }

    /// Whether a gesture is clear of whatever fired last.
    ///
    /// The asymmetry is the point. Repeating the same flick is deliberate and
    /// should feel immediate; reversing is what a hand does on its way back to
    /// where it started, and almost never what was meant.
    private func isAllowed(_ gesture: AirGesture, at time: TimeInterval) -> Bool {
        guard let lastGesture else { return true }
        let elapsed = time - lastGesture.time

        switch (lastGesture.kind, gesture) {
        case (.burst, _), (_, .burst):
            return elapsed >= thresholds.burstCooldown
        case let (.swipe(previous), .swipe(next)):
            return elapsed >= (previous == next ? thresholds.repeatCooldown : thresholds.reverseCooldown)
        }
    }

    private mutating func fire(_ gesture: AirGesture, at time: TimeInterval) -> AirGesture {
        lastGesture = (gesture, time)
        samples.removeAll()
        return gesture
    }
}

// MARK: - Test double

/// Used by previews, unit tests and the UI suite. Never touches the camera, and
/// lets a test drive the launcher by hand.
@MainActor
final class InertAirGestureSource: AirGestureObserving {
    var onGesture: ((AirGesture) -> Void)?
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

    /// Simulates a gesture, so the wiring can be tested without a camera.
    func emit(_ gesture: AirGesture) {
        onGesture?(gesture)
    }
}
