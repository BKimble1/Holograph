import Foundation

/// Where the viewer's head is, as the camera sees it.
///
/// Normalised and deliberately coarse: the launcher needs a viewing angle, not
/// a face. Nothing here identifies anybody, and nothing here can be turned back
/// into a picture.
struct HeadReading: Equatable, Sendable {
    /// Across the frame, -1 (viewer to the left) … 1 (to the right), 0 centred.
    var x: Double
    /// Up the frame, -1 (low) … 1 (high), 0 centred.
    var y: Double
    /// How much of the frame the head fills, which stands in for distance.
    /// About 0.2 at arm's length on an iPad.
    var scale: Double

    init(x: Double, y: Double, scale: Double) {
        self.x = x
        self.y = y
        self.scale = scale
    }
}

/// A viewing position, as the scene wants it.
///
/// Already smoothed, dead-zoned and clamped, and expressed in the only units
/// the views care about: how far to shift, and how much to turn.
struct HeadPerspective: Equatable, Sendable {
    /// -1 … 1 across.
    var x: Double
    /// -1 … 1 up and down.
    var y: Double
    /// How much of the effect to apply at all, 0 … 1. Falls to zero when
    /// nobody is there, so the scene settles rather than snapping flat.
    var strength: Double

    static let neutral = HeadPerspective(x: 0, y: 0, strength: 0)

    /// How far a layer at this depth should slide, in points.
    ///
    /// Depth is 0 for the furthest layer and 1 for the nearest, so the
    /// background drifts and the selected tile leads — which is what makes a
    /// flat screen read as a window rather than a picture of one.
    func offset(depth: Double, travel: Double) -> CGSize {
        CGSize(
            width: x * strength * travel * depth,
            height: y * strength * travel * depth * 0.6
        )
    }

    /// How far to turn a tile towards the viewer, in degrees.
    func rotation(maximum: Double) -> Double {
        x * strength * maximum
    }
}

/// Turns a stream of head readings into a viewing position.
///
/// The hard part is not finding a head; it is that a face bounding box jitters
/// by a couple of per cent every frame, and a window that trembles is worse
/// than one that does not move at all. So this is built the same way the hand
/// gestures are: a 1€ filter, which smooths hard while the viewer is still and
/// barely at all while they are moving, a dead zone so small movements are
/// nothing, and a hard clamp so the scene can never run away.
///
/// Pure, over plain numbers, so every one of those behaviours is testable
/// without a camera or a face.
struct HeadTracker {
    struct Thresholds: Equatable {
        /// Movement inside this fraction of the range is treated as stillness.
        /// A viewer sitting still should get a still scene.
        var deadZone: Double = 0.05
        /// How far the head has to travel across the frame for the full
        /// effect. Smaller than the whole frame, because nobody moves their
        /// head from edge to edge to look at a launcher — and smaller again
        /// after the first device test, where the effect was reported as too
        /// small to read as depth. A shorter range means an ordinary shift of
        /// the head reaches the full parallax instead of a fraction of it.
        var range: Double = 0.17
        /// The head is measured against where it was first seen, so the effect
        /// is about *moving*, not about sitting off-centre.
        var recentresAfter: TimeInterval = 4.0
        /// How quickly the effect fades in when a face appears and out when it
        /// leaves, in units of strength per second. Slow enough that a face
        /// lost for a frame is not a lurch.
        var fadeInRate: Double = 2.0
        var fadeOutRate: Double = 1.2
        /// Cutoff of the position filter while the head is still, in hertz.
        /// Lower is steadier and laggier. A face box wobbles far more than a
        /// hand does, and this is the number that decides whether the scene
        /// reads as glass or as jelly.
        var stillCutoff: Double = 0.45
        /// How much the cutoff opens up with speed, so a real movement is not
        /// smoothed into treacle.
        var speedCutoff: Double = 2.4
        /// A gap longer than this means the stream stopped, not that the head
        /// teleported.
        var maximumGap: TimeInterval = 0.5
    }

    let thresholds: Thresholds

    private var horizontal = OneEuroFilter()
    private var vertical = OneEuroFilter()
    private var origin: (x: Double, y: Double)?
    private var originSetAt: TimeInterval?
    private var strength: Double = 0
    private var lastUpdate: TimeInterval?
    private(set) var current: HeadPerspective = .neutral

    init(thresholds: Thresholds = Thresholds()) {
        self.thresholds = thresholds
        // The 1€ filter's defaults are tuned for a hand crossing the frame in a
        // third of a second. A head is slower and its jitter matters more, so
        // it is smoothed much harder while still — and then allowed to open up
        // sharply with speed, which is the whole point of this filter and what
        // keeps a deliberate lean from feeling delayed.
        horizontal.minimumCutoff = thresholds.stillCutoff
        horizontal.speedCoefficient = thresholds.speedCutoff
        vertical.minimumCutoff = thresholds.stillCutoff
        vertical.speedCoefficient = thresholds.speedCutoff
    }

    /// Feeds one observation and returns the viewing position to draw with.
    @discardableResult
    mutating func headSeen(_ reading: HeadReading, at time: TimeInterval) -> HeadPerspective {
        if let lastUpdate, time - lastUpdate > thresholds.maximumGap { forget() }
        let elapsed = lastUpdate.map { max(0, time - $0) } ?? 0
        lastUpdate = time

        let x = horizontal.apply(reading.x, at: time)
        let y = vertical.apply(reading.y, at: time)

        // Where the viewer was when they arrived is "straight on", whether or
        // not that happens to be the middle of the camera's frame. Somebody
        // sitting to one side of their iPad should still get a level scene.
        if origin == nil {
            origin = (x, y)
            originSetAt = time
        } else if let originSetAt, time - originSetAt > thresholds.recentresAfter {
            // And it drifts back towards them, so a viewer who has settled into
            // a new position is not permanently tilted.
            origin = (
                origin!.x + (x - origin!.x) * min(1, elapsed / 6),
                origin!.y + (y - origin!.y) * min(1, elapsed / 6)
            )
        }

        strength = min(1, strength + thresholds.fadeInRate * elapsed)
        current = HeadPerspective(
            x: Self.shaped(x - (origin?.x ?? 0), thresholds: thresholds),
            y: Self.shaped(y - (origin?.y ?? 0), thresholds: thresholds),
            strength: strength
        )
        return current
    }

    /// Nobody is there. The scene returns to straight-on rather than freezing
    /// wherever the last reading left it.
    @discardableResult
    mutating func headLost(at time: TimeInterval) -> HeadPerspective {
        let elapsed = lastUpdate.map { max(0, time - $0) } ?? 0
        lastUpdate = time
        strength = max(0, strength - thresholds.fadeOutRate * elapsed)
        if strength == 0 { forget() }
        current = HeadPerspective(x: current.x, y: current.y, strength: strength)
        return current
    }

    /// Everything about where the viewer was.
    mutating func reset() {
        forget()
        strength = 0
        lastUpdate = nil
        current = .neutral
    }

    private mutating func forget() {
        horizontal.reset()
        vertical.reset()
        origin = nil
        originSetAt = nil
    }

    /// Dead zone, then a clamp. Movement inside the dead zone is nothing at
    /// all; beyond it the response starts from zero rather than jumping to the
    /// dead zone's width, so there is no step at the edge of it.
    static func shaped(_ value: Double, thresholds: Thresholds) -> Double {
        let magnitude = abs(value) / max(thresholds.range, 1e-6)
        guard magnitude > thresholds.deadZone else { return 0 }
        let scaled = (magnitude - thresholds.deadZone) / (1 - thresholds.deadZone)
        return (value < 0 ? -1 : 1) * min(1, scaled)
    }
}

// MARK: - Preferences

enum HeadTrackingPreferences {
    static let enabledKey = "com.idlery.holograph.headTracking3DEnabled"

    /// Off until asked for: it runs the camera.
    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }
}

// MARK: - The source

/// Something that reports where the viewer's head is.
@MainActor
protocol HeadTracking: AnyObject {
    /// Called on the main actor with each new viewing position.
    var onPerspective: ((HeadPerspective) -> Void)? { get set }
    var isWatching: Bool { get }
    func start()
    func stop()
}

/// Used by previews, unit tests and the UI suite. Never opens a camera.
@MainActor
final class InertHeadTrackingSource: HeadTracking {
    var onPerspective: ((HeadPerspective) -> Void)?
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

    /// Simulates a viewing position, so the scene can be driven without a face.
    func emit(_ perspective: HeadPerspective) {
        onPerspective?(perspective)
    }
}
