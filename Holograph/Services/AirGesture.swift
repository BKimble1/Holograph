import Foundation

/// A hand moved across the front of the screen. Always the *physical* direction
/// the hand went; what the carousel does about it is decided in one place, by
/// `selectionStep`.
enum AirSwipe: Equatable, Sendable {
    case left
    case right

    /// How the selection moves when the hand goes this way.
    ///
    /// The wall follows the hand: sweep left and the apps travel left, so the
    /// next one arrives from the right — the same way a swipe on glass behaves.
    /// The mapping lives here, in one place, so flicks and drags can never drift
    /// apart, and reversing it is this one table.
    var selectionStep: Int {
        switch self {
        case .left: return 1
        case .right: return -1
        }
    }
}

/// Something the hand did in front of the screen.
enum AirGesture: Equatable, Sendable {
    /// A flick: one app, then a pause before the next one counts.
    case swipe(AirSwipe)
    /// One notch of a pinched-hand drag. Free-running — pinch, sweep, and the
    /// apps come with you.
    case drag(AirSwipe)

    /// Which way the carousel goes, whichever kind of movement this was.
    var selectionStep: Int {
        switch self {
        case .swipe(let direction), .drag(let direction): return direction.selectionStep
        }
    }
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
/// There are two ways to move the wall, and they suit different journeys.
///
/// A **flick** is a discrete step: one app, then a pause. It is built as a small
/// state machine over a smoothed position, which is what stops one flick
/// counting twice. A threshold test on its own fires the moment it is crossed
/// and then re-arms on a timer, so a single long sweep can trip it more than
/// once and the hand's journey back can trip it again. Here a movement is a
/// *stroke*: it opens when the hand starts moving, yields at most one gesture,
/// and does not re-arm until the hand has come to rest *and* a settling pause
/// has passed — long enough to bring the hand back and set it up again without
/// the return counting for anything.
///
/// A **pinch drag** is continuous: put the fingertips together and the wall is
/// yours, a notch of travel to an app, until the hand opens again. It is the
/// answer to a long journey, which flicking one app at a time is not.
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
        /// a gesture.
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
        /// Quiet after a flick before another one counts, so the hand can come
        /// back and be set up again without any of that registering.
        ///
        /// A return stroke and a settle take about eight tenths of a second, so
        /// this sits comfortably beyond it while still allowing roughly an app
        /// every second — and a long journey is what the pinch drag is for.
        var settleAfterSwipe: TimeInterval = 1.2

        /// Fingertips this close to their own centre, in spans, are pinched.
        /// A real pinch reads about 0.13; a loosely closed hand about 0.35 and a
        /// splayed one about 0.69, so this asks for the deliberate thing.
        var pinchSpread: Double = 0.22
        /// And this far apart is a hand that has let go. The gap between the two
        /// is hysteresis: a spread wavering around one number must not make the
        /// drag flicker on and off.
        var releaseSpread: Double = 0.34
        /// How long the fingers must stay together before the drag takes hold.
        var pinchHold: TimeInterval = 0.15
        /// How far a pinched hand travels for one app, in spans. Six inches of
        /// hand is about three apps, so a comfortable arm's sweep crosses ten.
        var dragNotchSpans: Double = 0.6

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
        /// until the hand comes to rest and the settling pause has run out —
        /// which is what makes the journey back silent without having to guess
        /// how long it takes.
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
    private var settledAt: TimeInterval = -.greatestFiniteMagnitude

    /// When the fingers first came together, or `nil` if they are apart.
    private var pinchedSince: TimeInterval?
    /// Where the last drag notch was handed out.
    private var lastNotch: Double?

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

        trackPinch(reading.spread, at: time)

        let gesture: AirGesture?
        if lastNotch != nil {
            gesture = dragStep(to: position, spread: reading.spread)
        } else if shouldBeginDrag(at: time) {
            // Taking hold is not itself a movement; the wall waits for the hand.
            lastNotch = position
            gesture = nil
        } else {
            gesture = swipe(position: position, speed: speed, at: time)
        }

        previous = (position, time)
        return gesture
    }

    /// The hand left the frame. Whatever was building is not a gesture, and a
    /// hand that has gone has certainly stopped moving — and has let go.
    mutating func handLost() {
        positionFilter.reset()
        smoothedSpan = nil
        previous = nil
        history.removeAll()
        recentSpeeds.removeAll()
        stroke = .idle
        stillCount = 0
        pathLength = 0
        pinchedSince = nil
        lastNotch = nil
    }

    /// Exposed for tests; the camera never needs it.
    var isMidStroke: Bool {
        if case .tracking = stroke { return true }
        return false
    }

    /// Exposed for tests: whether a pinch currently has hold of the wall.
    var isDragging: Bool { lastNotch != nil }

    // MARK: - Flicks

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
                settledAt = time + thresholds.settleAfterSwipe
                return .swipe(displacement > 0 ? .right : .left)
            }
            // Ran out of movement, or went on too long to be a flick.
            if stillCount >= thresholds.stillReadings || time - since > thresholds.maximumStrokeDuration {
                stroke = .idle
                stillCount = 0
            }
            return nil

        case .spent:
            // Two conditions, and both matter. The hand has to have stopped, so
            // the journey back is never the next gesture; and the settling pause
            // has to have run out, so there is time to bring it back and set up
            // again without hurrying.
            if stillCount >= 1, time >= settledAt {
                stroke = .idle
                stillCount = 0
            }
            return nil
        }
    }

    // MARK: - Pinch drag

    /// Follows the fingers. A reading whose fingertips could not be resolved
    /// says nothing either way, so it neither starts nor breaks a pinch — a
    /// pinched hand in motion is blurred, and its fingertips are the first
    /// landmarks to go.
    private mutating func trackPinch(_ spread: Double?, at time: TimeInterval) {
        guard let spread else { return }
        if spread <= thresholds.pinchSpread {
            if pinchedSince == nil { pinchedSince = time }
        } else if spread >= thresholds.releaseSpread {
            pinchedSince = nil
        }
    }

    private func shouldBeginDrag(at time: TimeInterval) -> Bool {
        // Only from a standing start. Taking hold in the middle of a flick — or
        // in its tail, while the hand is still slowing down — would let one
        // movement change its mind about what kind of movement it is, and pay
        // out an extra app on the way through.
        guard case .idle = stroke, let pinchedSince else { return false }
        return time - pinchedSince >= thresholds.pinchHold
    }

    private mutating func dragStep(to position: Double, spread: Double?) -> AirGesture? {
        if let spread, spread >= thresholds.releaseSpread {
            endDrag()
            return nil
        }
        guard let anchor = lastNotch else { return nil }

        let offset = position - anchor
        guard abs(offset) >= thresholds.dragNotchSpans else { return nil }

        // One notch per reading, and the anchor moves by exactly one notch
        // rather than to where the hand is: a sweep faster than the frame rate
        // keeps its remaining travel and pays it out over the readings that
        // follow, instead of losing it or firing a burst all at once.
        let direction: AirSwipe = offset > 0 ? .right : .left
        lastNotch = anchor + (offset > 0 ? thresholds.dragNotchSpans : -thresholds.dragNotchSpans)
        return .drag(direction)
    }

    private mutating func endDrag() {
        lastNotch = nil
        pinchedSince = nil
        // The flick machinery has been idle throughout; what it remembers of the
        // drag is not a stroke, so none of it should count towards one.
        history.removeAll()
        recentSpeeds.removeAll()
        stroke = .idle
        stillCount = 0
        pathLength = 0
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
