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

// MARK: - Smoothing

/// The 1€ filter: a low-pass filter whose cutoff rises with speed.
///
/// Landmark positions from a camera jitter by a good fraction of an inch even
/// when a hand is perfectly still, and plain smoothing trades that jitter for
/// lag — which on a gesture this short eats the very displacement being
/// measured. This filter smooths hard while the hand is still, where jitter is
/// the whole problem, and barely at all while it is moving, where lag is.
///
/// Casiez, Roussel and Vogel, *1€ Filter: A Simple Speed-based Low-pass Filter
/// for Noisy Input in Interactive Systems*, CHI 2012.
struct OneEuroFilter {
    /// Cutoff in hertz when the signal is still. Lower means steadier.
    var minimumCutoff: Double = 1.5
    /// How sharply the cutoff opens up with speed. Higher means less lag.
    var speedCoefficient: Double = 2.5
    /// Cutoff for the speed estimate itself.
    var derivativeCutoff: Double = 1.0

    private var value: Double?
    private var derivative = 0.0
    private var time: TimeInterval?

    /// The exponential smoothing factor for a given cutoff over a given step.
    private static func alpha(cutoff: Double, elapsed: TimeInterval) -> Double {
        let tau = 1 / (2 * .pi * cutoff)
        return 1 / (1 + tau / elapsed)
    }

    mutating func apply(_ sample: Double, at sampleTime: TimeInterval) -> Double {
        guard let previous = value, let last = time, sampleTime > last else {
            value = sample
            time = sampleTime
            derivative = 0
            return sample
        }

        let elapsed = sampleTime - last
        let rawDerivative = (sample - previous) / elapsed
        let derivativeAlpha = Self.alpha(cutoff: derivativeCutoff, elapsed: elapsed)
        derivative = derivativeAlpha * rawDerivative + (1 - derivativeAlpha) * derivative

        // The whole idea: a faster signal gets a higher cutoff, so it is barely
        // smoothed and barely delayed.
        let cutoff = minimumCutoff + speedCoefficient * abs(derivative)
        let smoothing = Self.alpha(cutoff: cutoff, elapsed: elapsed)
        let smoothed = smoothing * sample + (1 - smoothing) * previous

        value = smoothed
        time = sampleTime
        return smoothed
    }

    mutating func reset() {
        value = nil
        time = nil
        derivative = 0
    }
}

// MARK: - What the camera saw

/// One frame's worth of hand.
///
/// `x` and `span` are both in frame units and deliberately kept apart. Dividing
/// one by the other per frame — which an earlier version did — folds the noise
/// in the *scale* estimate into the *position*: a span wobbling by eight per
/// cent moves a still hand by half a span, which is most of a flick. The
/// detector smooths each on its own terms and only then works in spans.
struct HandReading: Equatable {
    /// Where the hand sits across the frame, in frame units.
    var x: Double
    /// The hand's width across the knuckles, in the same units. The ruler.
    var span: Double
    /// How far the fingertips sit from their own centre, already in spans, or
    /// `nil` when too few could be seen to tell an open hand from a shut one.
    ///
    /// Optional, and that matters: a hand mid-flick is motion-blurred and its
    /// fingertips are the first landmarks to lose confidence. Requiring them
    /// would discard the whole reading exactly when a swipe is happening.
    var spread: Double?

    init(x: Double, span: Double, spread: Double? = nil) {
        self.x = x
        self.span = span
        self.spread = spread
    }
}

// MARK: - The detector

/// Turns a stream of hand readings into gestures.
///
/// Built as a small state machine over a smoothed position, which is what stops
/// one flick counting twice. A threshold test on its own fires the moment it is
/// crossed and then re-arms on a timer, so a single long sweep can trip it more
/// than once and the hand's journey back can trip it again. Here a movement is
/// a *stroke*: it opens when the hand starts moving, yields at most one gesture,
/// and does not re-arm until the hand has come to rest. Starting and stopping
/// use different speeds — hysteresis — so a hand hovering near the threshold
/// cannot chatter between the two.
///
/// The whole of the gesture logic, kept as a value type over plain numbers so it
/// can be exercised without a camera, a hand, or a running app.
struct AirGestureDetector {
    struct Thresholds: Equatable {
        /// Speed, in spans per second, that opens a stroke. A hand is about
        /// three inches across the knuckles, so this is roughly six inches a
        /// second.
        var startSpeed: Double = 2.6
        /// And the lower speed that counts as stopped. It sits above the speed a
        /// *still* hand appears to move at through landmark noise — measured at
        /// about 1.1 spans per second — because a rest that is never detected
        /// leaves the detector stuck refusing to fire again.
        var stopSpeed: Double = 1.3
        /// How far the hand must travel within a stroke, in spans — around two
        /// inches, at any distance from the screen. Chosen by measurement: over
        /// two hundred noise realisations this is the loosest setting at which
        /// waving still never registers as a flick.
        var travelSpans: Double = 0.68
        /// How straight the path has to be: |net displacement| ÷ |path length|.
        var straightness: Double = 0.55
        /// Consecutive quiet readings that end a stroke that has not yet earned
        /// a gesture. Re-arming after one that has takes a single reading: the
        /// next stroke still has to earn its own gesture, so being eager there
        /// costs nothing and losing a deliberate second flick costs a lot.
        var stillReadings: Int = 2
        /// How many recent speeds the stillness test takes the median of. One
        /// noisy frame must not read as the hand setting off again.
        var speedMedianWindow: Int = 3
        /// A stroke that goes on longer than this is not a flick.
        var maximumStrokeDuration: TimeInterval = 1.2
        /// How far back a stroke may reach to find where the movement began.
        var strokeLookback: TimeInterval = 0.35
        /// A gap longer than this means the hand was lost and found again, not
        /// that it moved instantly.
        var maximumGap: TimeInterval = 0.4

        /// Fingers must have been at least this close for a burst to count.
        /// Pinched fingertips sit about 0.13 spans from their centre.
        var gatheredSpread: Double = 0.45
        /// And must open at least this wide. A fully splayed hand reaches about
        /// 0.69, so this sits comfortably inside what a hand can do.
        var burstSpread: Double = 0.48
        /// Opening by less than this is a hand relaxing, not a burst.
        var burstGrowth: Double = 0.25
        /// A burst is one quick action, not a slow unfurling.
        var burstWindow: TimeInterval = 0.5
        /// The fingers must come back below this before another burst counts,
        /// so holding an open hand up does not launch things repeatedly.
        var burstRearmSpread: Double = 0.42

        /// Below this many readings there is not enough of a shape to judge.
        var minimumSamples: Int = 3

        static let `default` = Thresholds()
    }

    /// Where a stroke is in its life.
    private enum Stroke: Equatable {
        /// Nothing is happening; a fast enough reading opens a stroke.
        case idle
        /// The hand is moving and has not yet earned a gesture.
        case tracking(origin: Double, since: TimeInterval)
        /// A gesture has been given for this movement. Nothing more can fire
        /// until the hand comes to rest — which is what makes the journey back
        /// silent without having to guess how long it takes.
        case spent
    }

    let thresholds: Thresholds

    private var positionFilter = OneEuroFilter()
    private var smoothedSpan: Double?
    private var previous: (position: Double, time: TimeInterval)?
    /// Recent readings, so a stroke can be measured from where the movement
    /// began rather than from where the speed gate happened to open.
    private var history: [(position: Double, time: TimeInterval, speed: Double)] = []
    private var recentSpeeds: [Double] = []
    private var stroke: Stroke = .idle
    private var stillCount = 0
    private var pathLength = 0.0

    private var spreads: [(value: Double, time: TimeInterval)] = []
    private var burstArmed = true

    init(thresholds: Thresholds = .default) {
        self.thresholds = thresholds
    }

    /// Feeds one observation. Returns a gesture on the reading that completes it.
    mutating func handSeen(_ reading: HandReading, time: TimeInterval) -> AirGesture? {
        if let previous, time <= previous.time { return nil }
        // A long gap is a hand that went away and came back. Carrying the old
        // position across it would invent a very fast, very long swipe.
        if let previous, time - previous.time > thresholds.maximumGap { handLost() }
        guard reading.span > 0 else { return nil }

        // The span is smoothed hard: a hand does not change width, so anything
        // that moves here is measurement noise.
        let span = smoothedSpan.map { $0 * 0.75 + reading.span * 0.25 } ?? reading.span
        smoothedSpan = span

        let position = positionFilter.apply(reading.x, at: time) / span
        let speed = previous.map { abs(position - $0.position) / max(time - $0.time, 1e-6) } ?? 0
        if let previous { pathLength += abs(position - previous.position) }

        // The burst is checked first: it happens with the hand still, so a hand
        // that could be mid-burst is not mid-flick.
        let gesture = burst(reading.spread, at: time) ?? swipe(position: position, speed: speed, at: time)
        previous = (position, time)
        return gesture
    }

    /// The hand left the frame. Whatever was building is not a gesture, and a
    /// hand that has gone has certainly stopped moving.
    mutating func handLost() {
        positionFilter.reset()
        smoothedSpan = nil
        previous = nil
        history.removeAll()
        recentSpeeds.removeAll()
        stroke = .idle
        stillCount = 0
        pathLength = 0
        spreads.removeAll()
    }

    /// Exposed for tests; the camera never needs it.
    var isMidStroke: Bool {
        if case .tracking = stroke { return true }
        return false
    }

    // MARK: - Swipes

    private mutating func swipe(position: Double, speed: Double, at time: TimeInterval) -> AirGesture? {
        history.append((position, time, speed))
        if history.count > 12 { history.removeFirst(history.count - 12) }

        // The median of the last few speeds, not the latest one: a single noisy
        // frame must not read as the hand setting off again.
        recentSpeeds.append(speed)
        if recentSpeeds.count > thresholds.speedMedianWindow {
            recentSpeeds.removeFirst(recentSpeeds.count - thresholds.speedMedianWindow)
        }
        let steadySpeed = recentSpeeds.sorted()[recentSpeeds.count / 2]
        stillCount = steadySpeed <= thresholds.stopSpeed ? stillCount + 1 : 0

        switch stroke {
        case .idle:
            guard speed >= thresholds.startSpeed else { return nil }
            // Walk back to just before the hand started accelerating. Measuring
            // from where the speed gate opened loses the first third of a flick,
            // which is why short ones went unnoticed.
            var index = history.count - 1
            while index > 0,
                  history[index - 1].speed < thresholds.startSpeed,
                  time - history[index - 1].time <= thresholds.strokeLookback {
                index -= 1
            }
            stroke = .tracking(origin: history[index].position, since: history[index].time)
            pathLength = 0
            return nil

        case let .tracking(origin, since):
            let displacement = position - origin
            let distance = abs(displacement)
            if distance >= thresholds.travelSpans,
               pathLength > 0, distance / pathLength >= thresholds.straightness {
                stroke = .spent
                stillCount = 0
                return .swipe(displacement > 0 ? .right : .left)
            }
            // Ran out of movement, or went on too long to be a flick.
            if stillCount >= thresholds.stillReadings || time - since > thresholds.maximumStrokeDuration {
                stroke = .idle
                stillCount = 0
            }
            return nil

        case .spent:
            // One quiet reading is enough to re-arm. The next stroke still has
            // to earn its own gesture, and the hand's journey back never has a
            // quiet reading in it — so this costs no safety and stops a
            // deliberate second flick being swallowed.
            if stillCount >= 1 {
                stroke = .idle
                stillCount = 0
            }
            return nil
        }
    }

    // MARK: - Bursts

    private mutating func burst(_ spread: Double?, at time: TimeInterval) -> AirGesture? {
        // Readings whose fingertips could not be resolved say nothing about
        // whether the hand is open, so they are skipped rather than counted shut.
        if let spread { spreads.append((spread, time)) }
        spreads.removeAll { time - $0.time > thresholds.burstWindow }

        guard let current = spreads.last?.value else { return nil }

        guard burstArmed else {
            // Re-arms only once the fingers close again, so an open hand held up
            // does not keep launching things.
            if current <= thresholds.burstRearmSpread { burstArmed = true }
            return nil
        }

        // Key paths cannot index tuple elements, hence the explicit closure.
        let earlier = spreads.dropLast().map { $0.value }
        guard spreads.count >= thresholds.minimumSamples,
              current >= thresholds.burstSpread,
              let gathered = earlier.min(),
              gathered <= thresholds.gatheredSpread,
              current - gathered >= thresholds.burstGrowth else { return nil }

        burstArmed = false
        return .burst
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
