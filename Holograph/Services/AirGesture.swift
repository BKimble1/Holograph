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
/// work at any distance. The same flick covers twice as much of the frame at a
/// foot as it does at two, but it is always the same number of knuckle-spans —
/// so every threshold here is expressed in spans, and none of them care how far
/// away the person is standing.
struct HandReading: Equatable {
    /// Where the hand sits across the frame, in spans from the left edge.
    var x: Double
    /// How far the fingertips sit from their own centre, in spans — low when
    /// they are gathered, high when the hand is open.
    ///
    /// Optional, and that matters: a hand moving quickly is motion-blurred, and
    /// fingertips are the first landmarks to lose confidence. Requiring them
    /// would throw away the whole reading exactly when a swipe is happening. A
    /// swipe needs only the knuckles; the fingertips are the burst's business.
    var spread: Double?

    init(x: Double, spread: Double? = nil) {
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
        /// How far the hand must travel, in its own spans. A hand is about three
        /// inches across the knuckles, so this is roughly a four-inch flick — at
        /// any distance from the screen.
        var travelSpans: Double = 1.2
        /// And how briskly, in spans per second: about seven inches a second.
        var speedSpans: Double = 2.2
        /// How straight the path has to be: |net displacement| ÷ |path length|.
        var straightness: Double = 0.65
        /// Motion older than this is not part of the current flick.
        var window: TimeInterval = 0.6
        /// The shortest gesture worth believing; faster is jitter.
        var minimumDuration: TimeInterval = 0.06

        /// Quiet time before the *same* flick counts again.
        var repeatCooldown: TimeInterval = 0.4
        /// Quiet time before the *opposite* flick counts — a backstop behind the
        /// settle rule below, not the main defence.
        var reverseCooldown: TimeInterval = 0.5
        /// Below this, in spans per second, the hand is treated as at rest.
        var settleSpeed: Double = 1.2
        /// How many consecutive slow readings count as having come to rest.
        var settleSamples: Int = 2

        /// Fingers must gather at least this close before a burst can start.
        /// Pinched fingertips sit about 0.13 spans from their centre.
        var gatheredSpread: Double = 0.38
        /// And open at least this wide to finish one. A fully splayed hand
        /// reaches about 0.69, so this is comfortably inside what a hand does.
        var burstSpread: Double = 0.50
        /// Opening by less than this is a hand relaxing, not a burst.
        var burstGrowth: Double = 0.28
        /// A burst is a single quick action, not a slow unfurling. Half a second
        /// is comfortably longer than throwing a hand open takes, and short
        /// enough that a hand opening over a second never accumulates the growth
        /// above inside one window.
        var burstWindow: TimeInterval = 0.5
        var burstCooldown: TimeInterval = 1.0

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
    /// Whether the hand has come to rest since the last gesture. Reversing waits
    /// on this rather than on the clock — see `isAllowed`.
    private var hasSettled = true
    private var slowReadings = 0
    let thresholds: Thresholds

    init(thresholds: Thresholds = .default) {
        self.thresholds = thresholds
    }

    /// Feeds one observation. Returns a gesture on the frame that completes it.
    mutating func handSeen(_ reading: HandReading, time: TimeInterval) -> AirGesture? {
        // Out-of-order frames would corrupt the path; the camera can deliver
        // them after a stall.
        if let last = samples.last, time <= last.time { return nil }

        trackSettling(towards: reading, at: time)
        samples.append(Sample(reading: reading, time: time))
        samples.removeAll { time - $0.time > max(thresholds.window, thresholds.burstWindow) }

        // A burst happens in place, so it is checked first: a hand that has
        // barely moved cannot be mid-flick anyway.
        if let burst = burst(at: time) { return fire(burst, at: time) }
        if let swipe = swipe(at: time) { return fire(swipe, at: time) }
        return nil
    }

    /// The hand left the frame. Whatever path was building is not a gesture —
    /// and a hand that has gone away has certainly stopped moving.
    mutating func handLost() {
        samples.removeAll()
        hasSettled = true
        slowReadings = 0
    }

    /// Notices the hand coming to rest.
    ///
    /// This is what separates a flick from the journey back. After a gesture the
    /// hand has to return to where it started, and that return is one continuous
    /// movement — it never pauses. Requiring a pause before the opposite
    /// direction counts lets the flick itself stay easy without the way back
    /// undoing it.
    private mutating func trackSettling(towards reading: HandReading, at time: TimeInterval) {
        guard let previous = samples.last else { return }
        let elapsed = time - previous.time
        guard elapsed > 0 else { return }

        let speed = abs(reading.x - previous.reading.x) / elapsed
        slowReadings = speed <= thresholds.settleSpeed ? slowReadings + 1 : 0
        if slowReadings >= thresholds.settleSamples { hasSettled = true }
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
        // Readings whose fingertips could not be resolved say nothing about
        // whether the hand is open, so they are skipped rather than treated as
        // closed.
        let recent = samples.filter { time - $0.time <= thresholds.burstWindow && $0.reading.spread != nil }
        guard recent.count >= thresholds.minimumSamples,
              let last = recent.last, let openSpread = last.reading.spread,
              openSpread >= thresholds.burstSpread else { return nil }

        // The tightest the fingers got before opening. Anything after the
        // gathering is the burst itself.
        guard let gathered = recent.dropLast().min(by: { ($0.reading.spread ?? 1) < ($1.reading.spread ?? 1) }),
              let gatheredSpread = gathered.reading.spread,
              gatheredSpread <= thresholds.gatheredSpread,
              gathered.time < last.time else { return nil }

        let growth = openSpread - gatheredSpread
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
        case let (.swipe(previous), .swipe(next)) where previous == next:
            return elapsed >= thresholds.repeatCooldown
        case (.swipe, .swipe):
            // The opposite way needs the hand to have actually stopped first.
            // A cooldown alone either blocks a deliberate reverse or lets the
            // return stroke through, depending on how fast the person moves.
            return hasSettled && elapsed >= thresholds.reverseCooldown
        }
    }

    private mutating func fire(_ gesture: AirGesture, at time: TimeInterval) -> AirGesture {
        lastGesture = (gesture, time)
        samples.removeAll()
        hasSettled = false
        slowReadings = 0
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
