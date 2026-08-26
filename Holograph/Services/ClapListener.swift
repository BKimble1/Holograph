import Foundation

/// Something that listens for two claps in front of the iPad.
///
/// Behind a protocol for the same reason the camera is: previews, unit tests and
/// the UI suite must never open a microphone.
@MainActor
protocol ClapListening: AnyObject {
    /// Called on the main actor when two claps are heard.
    var onDoubleClap: (() -> Void)? { get set }
    var isListening: Bool { get }
    func start()
    func stop()
    /// The launcher is about to make a noise lasting roughly this long. The
    /// microphone hears the iPad's own speaker perfectly well, and two carousel
    /// ticks in a second are, to a level meter, an excellent double clap.
    func mute(for duration: TimeInterval)
}

// MARK: - Preferences

enum ClapPreferences {
    static let enabledKey = "com.idlery.holograph.clapToOpenEnabled"

    /// Off until asked for: it runs the microphone.
    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }
}

// MARK: - Levels

/// Turns a block of audio into the loudness readings the detector works on.
///
/// Split into short chunks rather than measured once per buffer: iOS hands out
/// tap buffers of whatever size it likes, often a tenth of a second, and a clap
/// is over inside that. Chunking makes the detector's resolution a property of
/// this code instead of a property of the hardware.
enum ClapLevels {
    /// 256 frames is about five milliseconds at any sample rate an iPad uses —
    /// short enough to see the leading edge of a clap.
    static let chunkFrames = 256

    /// The peak magnitude of each chunk, in order. A peak rather than an
    /// average, because what identifies a clap is its instant, not its energy.
    static func peaks(of samples: UnsafeBufferPointer<Float>, chunk: Int = chunkFrames) -> [Float] {
        guard chunk > 0, !samples.isEmpty else { return [] }
        var result: [Float] = []
        result.reserveCapacity(samples.count / chunk + 1)

        var start = samples.startIndex
        while start < samples.endIndex {
            let end = min(start + chunk, samples.endIndex)
            var peak: Float = 0
            for index in start..<end {
                let magnitude = abs(samples[index])
                if magnitude > peak { peak = magnitude }
            }
            result.append(peak)
            start = end
        }
        return result
    }
}

// MARK: - The detector

/// Finds two claps in a stream of loudness readings.
///
/// A level meter cannot tell a clap from a snare drum by timbre, so it has to go
/// by *shape*, and four properties do the work together. A clap is **loud
/// against the room it happens in** — the bar is set relative to a running
/// background rather than at some absolute figure, so it works in a quiet study
/// and a busy kitchen. It has a **near-vertical attack**: it reaches full
/// loudness inside a few milliseconds, which speech, however animated, never
/// does — this is the single test that keeps a conversation from opening apps.
/// It **collapses immediately**, so anything still loud a quarter of a second
/// later was sustained, not struck. And a double clap is **two of them alone**:
/// quiet before, quiet after. That last one is what separates a pair of claps
/// from music, whose beats are a train rather than a pair — every beat is
/// cancelled by the next one.
///
/// Pure, over plain numbers, so it can be fed a room without a microphone
/// anywhere near it.
struct ClapDetector {
    struct Thresholds: Equatable {
        /// How far above the room a clap has to be, in decibels.
        var onsetRise: Double = 12
        /// And how loud in absolute terms, so a rustle in a silent room is not
        /// promoted to a clap for want of competition. Full scale is 0 dB.
        var absoluteLevel: Double = -28
        /// How much it must gain in `attackWindow`. A clap is at full volume
        /// within a few milliseconds; a raised voice takes fifty. This is the
        /// test that keeps a conversation quiet.
        var attackRise: Double = 18
        var attackWindow: TimeInterval = 0.015
        /// A clap that has not fallen back to within this of the room, within
        /// `maximumClapDuration`, was something sustained.
        var settleRise: Double = 6
        /// Or fallen this far from its own loudest moment, which is the quicker
        /// test of the two and the one that matters in a live room: waiting for
        /// a clap to reach the noise floor takes a tenth of a second, which is
        /// longer than the gap between two quick claps. That wait was why a
        /// quick pair registered as one.
        var collapseDrop: Double = 12
        var maximumClapDuration: TimeInterval = 0.25
        /// Quiet after one clap before the next can be heard.
        var refractory: TimeInterval = 0.05
        /// How far apart the two claps may be. The lower bound is what people
        /// actually do when they clap twice in earnest.
        var minimumGap: TimeInterval = 0.10
        var maximumGap: TimeInterval = 0.70
        /// How much louder one clap may be than the other. Two claps come from
        /// one pair of hands and match; a clap and a door do not, and neither
        /// does a strike and a ripple in its own tail.
        var matchedLevel: Double = 9

        /// Silence required after the second clap before it counts, as a
        /// multiple of the pair's own gap.
        ///
        /// This is what rules out music, and being proportional is the point: a
        /// rhythm repeats at roughly the spacing of any two beats in it, so
        /// waiting out one of those spacings catches the beat that follows. A
        /// fixed wait has a blind spot at every period just longer than itself
        /// — which is exactly where apps were opening themselves. It also means
        /// a quick double clap is answered quickly, because there is less to
        /// wait for.
        var holdOffFactor: Double = 2.0
        var minimumHoldOff: TimeInterval = 0.18
        var maximumHoldOff: TimeInterval = 0.85
        /// Silence required *before* the pair. A rhythm loses the odd beat to
        /// its own echo, and the survivors then look like a pair on their own —
        /// so the run-up has to be clear for longer than a bar.
        var leadIn: TimeInterval = 2.5
        /// And how soon after opening one app another may be opened. Shorter
        /// than the lead-in: a person coming back to clap again is not a
        /// rhythm.
        var rearm: TimeInterval = 1.0

        /// How fast the background estimate may climb, in decibels per second.
        /// Slow, so a clap barely raises the bar it is being judged against.
        var backgroundRise: Double = 6
        /// And the time constant it falls with when the room goes quiet.
        var backgroundFall: TimeInterval = 0.60

        /// A gap longer than this means the stream was interrupted; whatever was
        /// building is not part of what comes next.
        var maximumStreamGap: TimeInterval = 1.0

        static let `default` = Thresholds()
    }

    /// A clap that has been heard but has not yet proved it collapses.
    private struct Strike {
        var began: TimeInterval
        var peak: Double
    }

    let thresholds: Thresholds

    private var background: Double?
    private var time: TimeInterval?
    /// Recent levels, only as far back as the attack window needs.
    private var recent: [(time: TimeInterval, level: Double)] = []
    private var pending: Strike?
    /// Confirmed claps, most recent last.
    private var claps: [Strike] = []
    /// When a pair will be reported, if nothing else is heard first.
    private var reportAt: TimeInterval?
    private var nextOnsetAllowed: TimeInterval = -.greatestFiniteMagnitude
    private var mutedUntil: TimeInterval = -.greatestFiniteMagnitude
    private var lastReport: TimeInterval = -.greatestFiniteMagnitude

    init(thresholds: Thresholds = .default) {
        self.thresholds = thresholds
    }

    /// Feeds one loudness reading, as a magnitude where 1 is full scale.
    /// Returns `true` on the reading that completes a double clap.
    mutating func heard(level: Double, at readingTime: TimeInterval) -> Bool {
        let decibels = 20 * log10(max(level, 1e-7))

        guard let last = time, readingTime > last,
              readingTime - last <= thresholds.maximumStreamGap,
              let room = background
        else {
            background = decibels
            time = readingTime
            recent = [(readingTime, decibels)]
            pending = nil
            return false
        }

        let elapsed = readingTime - last
        time = readingTime

        recent.append((readingTime, decibels))
        // Keep just enough to reach back one attack window.
        while recent.count > 2, readingTime - recent[1].time >= thresholds.attackWindow {
            recent.removeFirst()
        }
        let wasAt = recent[0].level
        let justWas = recent.count >= 2 ? recent[recent.count - 2].level : decibels

        // Asymmetric: creeps up, settles down. Climbing slowly is what stops a
        // clap from raising the bar it is being measured against; falling on a
        // time constant is what lets the room get quiet again afterwards.
        background = decibels > room
            ? room + thresholds.backgroundRise * elapsed
            : room + (decibels - room) * min(1, elapsed / thresholds.backgroundFall)

        guard readingTime >= mutedUntil else {
            pending = nil
            return false
        }

        let isLoudEnough = decibels >= room + thresholds.onsetRise
            && decibels >= thresholds.absoluteLevel

        if var strike = pending {
            strike.peak = max(strike.peak, decibels)
            pending = strike

            // A second clap landing on the first one's tail. Measured against
            // the reading right before it, not against the attack window, which
            // is still looking at the silence in front of the first clap and
            // would read its whole decay as a run of strikes. And it has to be
            // a strike rather than a ripple in that decay, which means as loud
            // as the one already in hand.
            let isRestrike = decibels - justWas >= thresholds.attackRise
                && decibels >= strike.peak - thresholds.matchedLevel
                && readingTime - strike.began >= thresholds.refractory

            if isLoudEnough, isRestrike {
                pending = Strike(began: readingTime, peak: decibels)
                reportAt = nil
                confirm(strike, endedAt: readingTime)
            } else if decibels <= room + thresholds.settleRise
                        || decibels <= strike.peak - thresholds.collapseDrop {
                pending = nil
                confirm(strike, endedAt: readingTime)
            } else if readingTime - strike.began > thresholds.maximumClapDuration {
                // Still loud: sustained, so never a clap.
                pending = nil
            }
        } else if readingTime >= nextOnsetAllowed, isLoudEnough,
                  decibels - wasAt >= thresholds.attackRise {
            pending = Strike(began: readingTime, peak: decibels)
            // A pair waiting out its hold-off is waiting for silence, and this
            // is not silence. Cancelling here rather than on the confirmation a
            // tenth of a second later is what catches the next beat of a rhythm
            // in time.
            reportAt = nil
        }

        if let deadline = reportAt, readingTime >= deadline {
            reportAt = nil
            lastReport = readingTime
            return true
        }
        return false
    }

    /// The launcher is making a noise of its own; ignore the microphone for a
    /// while, and forget anything half-heard.
    mutating func mute(for duration: TimeInterval, from now: TimeInterval) {
        mutedUntil = max(mutedUntil, now + duration)
        pending = nil
        claps.removeAll()
        reportAt = nil
    }

    mutating func reset() {
        background = nil
        time = nil
        recent.removeAll()
        pending = nil
        claps.removeAll()
        reportAt = nil
        nextOnsetAllowed = -.greatestFiniteMagnitude
        mutedUntil = -.greatestFiniteMagnitude
        lastReport = -.greatestFiniteMagnitude
    }

    /// Exposed for tests: whether a pair is waiting out its hold-off.
    var isAwaitingSilence: Bool { reportAt != nil }

    private mutating func confirm(_ strike: Strike, endedAt: TimeInterval) {
        nextOnsetAllowed = endedAt + thresholds.refractory

        claps.append(strike)
        if claps.count > 3 { claps.removeFirst(claps.count - 3) }
        guard claps.count >= 2 else { return }

        let second = claps[claps.count - 1]
        let first = claps[claps.count - 2]
        let gap = second.began - first.began
        guard gap >= thresholds.minimumGap, gap <= thresholds.maximumGap else { return }
        // Two claps from one pair of hands are about as loud as each other.
        guard abs(second.peak - first.peak) <= thresholds.matchedLevel else { return }

        // Quiet before it, and not hard on the heels of the last app opened.
        if claps.count >= 3, first.began - claps[claps.count - 3].began <= thresholds.leadIn { return }
        guard first.began - lastReport > thresholds.rearm else { return }

        let hold = min(thresholds.maximumHoldOff,
                       max(thresholds.minimumHoldOff, gap * thresholds.holdOffFactor))
        reportAt = second.began + hold
    }
}

// MARK: - Test double

/// Used by previews, unit tests and the UI suite. Never opens a microphone.
@MainActor
final class InertClapListener: ClapListening {
    var onDoubleClap: (() -> Void)?
    private(set) var isListening = false
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var mutedFor: [TimeInterval] = []

    func start() {
        isListening = true
        startCount += 1
    }

    func stop() {
        isListening = false
        stopCount += 1
    }

    func mute(for duration: TimeInterval) {
        mutedFor.append(duration)
    }

    /// Simulates a double clap, so the wiring can be tested without a room.
    func emit() {
        onDoubleClap?()
    }
}
