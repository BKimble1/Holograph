import Foundation

/// What Holograph has measured about the person using it.
///
/// Every field is optional, and `nil` means "use the shipped default". That is
/// deliberate: calibration adjusts the launcher to one person, and a launcher
/// that has never been calibrated must behave exactly as it did before.
///
/// The shipped defaults were tuned against a model of an average hand, an
/// average room and an average face. They work. What they cannot know is that
/// this person flicks from the wrist rather than the elbow, sits eighteen
/// inches from the screen rather than thirty, or claps quietly because it is
/// late. That is what these are for.
struct CalibrationProfile: Codable, Equatable, Sendable {
    /// Spans per second that should count as the start of a flick.
    var flickStartSpeed: Double?
    /// Spans a flick should have to cover.
    var flickTravelSpans: Double?
    /// How far this person's head moves, as a fraction of the frame, when they
    /// are looking around the screen rather than walking about the room.
    var headRange: Double?
    /// The quietest level that should count as a clap, in dBFS.
    var clapLevel: Double?
    /// The longest gap this person leaves between the two claps.
    var clapMaximumGap: TimeInterval?
    var measuredAt: Date?

    static let none = CalibrationProfile()

    var hasHand: Bool { flickStartSpeed != nil && flickTravelSpans != nil }
    var hasHead: Bool { headRange != nil }
    var hasClap: Bool { clapLevel != nil && clapMaximumGap != nil }
    var isEmpty: Bool { !hasHand && !hasHead && !hasClap }
}

enum CalibrationStore {
    static let key = "com.idlery.holograph.calibrationProfile"

    static func load(from defaults: UserDefaults = .standard) -> CalibrationProfile {
        guard let data = defaults.data(forKey: key),
              let profile = try? JSONDecoder().decode(CalibrationProfile.self, from: data)
        else { return .none }
        return profile
    }

    static func save(_ profile: CalibrationProfile, to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(profile) else { return }
        defaults.set(data, forKey: key)
    }

    static func clear(from defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }
}

// MARK: - Applying a profile

extension AirGestureDetector.Thresholds {
    /// Anything the profile does not carry keeps its shipped value, and every
    /// measured value is clamped to a range the detector is known to behave in.
    /// A calibration that came out strange should make the launcher slightly
    /// worse, never broken.
    func applying(_ profile: CalibrationProfile) -> Self {
        var tuned = self
        if let speed = profile.flickStartSpeed {
            tuned.startSpeed = min(max(speed, 1.6), 4.5)
            // Stillness has to stay well under the speed that starts a stroke,
            // or a stroke could never end.
            tuned.stopSpeed = min(tuned.stopSpeed, tuned.startSpeed * 0.55)
        }
        if let travel = profile.flickTravelSpans {
            tuned.travelSpans = min(max(travel, 0.40), 1.40)
        }
        return tuned
    }
}

extension HeadTracker.Thresholds {
    func applying(_ profile: CalibrationProfile) -> Self {
        var tuned = self
        if let range = profile.headRange {
            tuned.range = min(max(range, 0.06), 0.45)
        }
        return tuned
    }
}

extension ClapDetector.Thresholds {
    func applying(_ profile: CalibrationProfile) -> Self {
        var tuned = self
        if let level = profile.clapLevel {
            tuned.absoluteLevel = min(max(level, -42), -12)
        }
        if let gap = profile.clapMaximumGap {
            tuned.maximumGap = min(max(gap, 0.35), 0.95)
        }
        return tuned
    }
}

// MARK: - Hands

/// Watches a few deliberate flicks and works out what *this person's* flick
/// looks like.
///
/// It cannot use the real detector to find them, because the whole point is
/// that the real detector's thresholds may be wrong for this person. So it uses
/// a deliberately permissive one: any run of movement above a low floor is a
/// candidate, and the shape of what it collects is judged afterwards.
struct HandCalibrator {
    /// Movement below this is not a flick attempt by anybody.
    static let floorSpeed = 1.4
    /// A stroke has to last at least this long to be a movement rather than a
    /// noisy frame.
    static let minimumDuration: TimeInterval = 0.08
    /// And no longer than this to be a flick rather than a reach.
    static let maximumDuration: TimeInterval = 1.5
    /// How many flicks make a measurement. Three is enough for a median and
    /// few enough that nobody gives up halfway.
    static let wanted = 3

    /// One flick, as measured.
    struct Flick: Equatable {
        /// Peak smoothed speed, in spans per second.
        var peakSpeed: Double
        /// Net displacement, in spans.
        var travel: Double
    }

    private(set) var flicks: [Flick] = []

    private var filter = OneEuroFilter()
    private var smoothedSpan: Double?
    private var previous: (position: Double, time: TimeInterval)?
    private var stroke: (origin: Double, since: TimeInterval, peak: Double)?

    var isComplete: Bool { flicks.count >= Self.wanted }
    var progress: Double { min(1, Double(flicks.count) / Double(Self.wanted)) }

    mutating func handSeen(_ reading: HandReading, at time: TimeInterval) {
        guard reading.span > 0 else { return }
        if let previous, time <= previous.time { return }

        let span = smoothedSpan.map { $0 * 0.75 + reading.span * 0.25 } ?? reading.span
        smoothedSpan = span
        let position = filter.apply(reading.x, at: time) / span

        guard let last = previous else {
            previous = (position, time)
            return
        }
        let speed = abs(position - last.position) / max(time - last.time, 1e-6)
        previous = (position, time)

        if var current = stroke {
            current.peak = max(current.peak, speed)
            stroke = current
            let moving = speed >= Self.floorSpeed
            let elapsed = time - current.since
            if !moving || elapsed > Self.maximumDuration {
                finish(current, at: position, elapsed: elapsed)
                stroke = nil
            }
        } else if speed >= Self.floorSpeed {
            stroke = (origin: last.position, since: last.time, peak: speed)
        }
    }

    mutating func handLost() {
        filter.reset()
        smoothedSpan = nil
        previous = nil
        stroke = nil
    }

    mutating func reset() {
        handLost()
        flicks.removeAll()
    }

    private mutating func finish(
        _ current: (origin: Double, since: TimeInterval, peak: Double),
        at position: Double,
        elapsed: TimeInterval
    ) {
        guard elapsed >= Self.minimumDuration, elapsed <= Self.maximumDuration else { return }
        let travel = abs(position - current.origin)
        // A twitch is not a flick attempt, however fast it was.
        guard travel >= 0.35 else { return }
        flicks.append(Flick(peakSpeed: current.peak, travel: travel))
    }

    /// What to set, or `nil` when there is not enough to go on.
    ///
    /// The medians rather than the means: three flicks is a small sample, and
    /// one that went wrong should not drag the answer with it.
    func result() -> (startSpeed: Double, travelSpans: Double)? {
        guard flicks.count >= Self.wanted else { return nil }
        let speed = Self.median(flicks.map(\.peakSpeed))
        let travel = Self.median(flicks.map(\.travel))
        // Thresholds sit well below what was actually done, so a slightly lazy
        // flick on the day still counts. Set them at what was measured and
        // every second attempt would fail.
        return (startSpeed: speed * 0.45, travelSpans: travel * 0.55)
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count % 2 == 1 { return sorted[middle] }
        return (sorted[middle - 1] + sorted[middle]) / 2
    }
}

// MARK: - Head

/// Watches somebody look around their own screen, and learns how far their head
/// actually moves while doing it.
///
/// This is the measurement that varies most between people, because it is
/// really a measurement of how far away they sit. A head eighteen inches from
/// an iPad sweeps across a third of the frame; the same movement at three feet
/// barely crosses a tenth.
struct HeadCalibrator {
    /// Readings needed before the answer means anything.
    static let wanted = 45

    private(set) var count = 0
    private var minimumX = Double.greatestFiniteMagnitude
    private var maximumX = -Double.greatestFiniteMagnitude
    private var minimumY = Double.greatestFiniteMagnitude
    private var maximumY = -Double.greatestFiniteMagnitude

    var isComplete: Bool { count >= Self.wanted }
    var progress: Double { min(1, Double(count) / Double(Self.wanted)) }

    mutating func headSeen(_ reading: HeadReading) {
        count += 1
        minimumX = min(minimumX, reading.x)
        maximumX = max(maximumX, reading.x)
        minimumY = min(minimumY, reading.y)
        maximumY = max(maximumY, reading.y)
    }

    mutating func reset() {
        count = 0
        minimumX = .greatestFiniteMagnitude
        maximumX = -.greatestFiniteMagnitude
        minimumY = .greatestFiniteMagnitude
        maximumY = -.greatestFiniteMagnitude
    }

    /// The range to set, or `nil` when the head never really moved — which is
    /// worth refusing rather than guessing at, since it would make the scene
    /// wildly oversensitive.
    func result() -> Double? {
        guard isComplete else { return nil }
        let spanX = maximumX - minimumX
        let spanY = maximumY - minimumY
        guard spanX.isFinite, spanY.isFinite else { return nil }
        // Horizontal counts for more: heads move side to side far more than up
        // and down, and the horizontal is what the parallax is mostly built on.
        let observed = spanX * 0.7 + spanY * 0.3
        guard observed >= 0.04 else { return nil }
        // Half the observed span is the distance from centre to edge, and the
        // full effect should arrive a little before somebody reaches the limit
        // of what they just did — otherwise the corners are the only place the
        // effect is fully felt.
        return (observed / 2) * 0.8
    }
}

// MARK: - Claps

/// Listens to a few deliberate double claps and learns how loud this person
/// claps and how quickly.
struct ClapCalibrator {
    /// Double claps wanted.
    static let wanted = 3
    /// A transient has to be at least this far above the room to be a clap
    /// attempt at all — well below what the detector normally asks for, since
    /// the point is to find out what this person's clap is worth.
    static let riseAboveRoom = 9.0
    static let attackRise = 12.0
    static let attackWindow: TimeInterval = 0.015
    static let refractory: TimeInterval = 0.05
    /// Two strikes further apart than this were not one double clap.
    static let pairWindow: TimeInterval = 1.1

    struct Pair: Equatable {
        /// The quieter of the two, in dBFS — the one that has to be heard.
        var level: Double
        var gap: TimeInterval
    }

    private(set) var pairs: [Pair] = []

    private var background: Double?
    private var time: TimeInterval?
    private var recent: [(time: TimeInterval, level: Double)] = []
    private var pending: (began: TimeInterval, peak: Double)?
    private var lastStrike: (began: TimeInterval, peak: Double)?
    private var nextAllowed: TimeInterval = -.greatestFiniteMagnitude

    var isComplete: Bool { pairs.count >= Self.wanted }
    var progress: Double { min(1, Double(pairs.count) / Double(Self.wanted)) }

    mutating func heard(level: Double, at readingTime: TimeInterval) {
        let decibels = 20 * log10(max(level, 1e-7))
        guard let last = time, readingTime > last, readingTime - last <= 1.0,
              let room = background else {
            background = decibels
            time = readingTime
            recent = [(readingTime, decibels)]
            pending = nil
            return
        }
        let elapsed = readingTime - last
        time = readingTime
        recent.append((readingTime, decibels))
        while recent.count > 2, readingTime - recent[1].time >= Self.attackWindow {
            recent.removeFirst()
        }
        let wasAt = recent[0].level
        background = decibels > room
            ? room + 6 * elapsed
            : room + (decibels - room) * min(1, elapsed / 0.6)

        if var strike = pending {
            strike.peak = max(strike.peak, decibels)
            pending = strike
            if decibels <= room + 6 || decibels <= strike.peak - 12 {
                pending = nil
                record(strike, endedAt: readingTime)
            } else if readingTime - strike.began > 0.25 {
                pending = nil
            }
        } else if readingTime >= nextAllowed,
                  decibels >= room + Self.riseAboveRoom,
                  decibels - wasAt >= Self.attackRise {
            pending = (began: readingTime, peak: decibels)
        }
    }

    mutating func reset() {
        background = nil
        time = nil
        recent.removeAll()
        pending = nil
        lastStrike = nil
        nextAllowed = -.greatestFiniteMagnitude
        pairs.removeAll()
    }

    private mutating func record(_ strike: (began: TimeInterval, peak: Double), endedAt: TimeInterval) {
        nextAllowed = endedAt + Self.refractory
        defer { lastStrike = strike }
        guard let previous = lastStrike else { return }
        let gap = strike.began - previous.began
        guard gap > 0.05, gap <= Self.pairWindow else { return }
        pairs.append(Pair(level: min(previous.peak, strike.peak), gap: gap))
        // A pair is spent; the next clap starts a new one rather than pairing
        // with the second of this one.
        lastStrike = nil
    }

    /// What to set, or `nil` when there is not enough to go on.
    func result() -> (level: Double, maximumGap: TimeInterval)? {
        guard pairs.count >= Self.wanted else { return nil }
        // The *quietest* clap heard, less a margin: the bar has to sit under
        // everything this person actually did, not in the middle of it.
        let quietest = pairs.map(\.level).min() ?? -20
        let widest = pairs.map(\.gap).max() ?? 0.4
        return (level: quietest - 6, maximumGap: widest * 1.35)
    }
}
