import Foundation
import Observation

/// Runs one calibration from start to finish.
///
/// The three exercises are deliberately short and specific. A calibration that
/// asks somebody to "move naturally for thirty seconds" measures a person being
/// self-conscious; one that asks for three flicks measures three flicks.
@MainActor
@Observable
final class CalibrationModel {
    enum Exercise: String, CaseIterable, Identifiable {
        case hand
        case head
        case clap

        var id: String { rawValue }

        var title: String {
            switch self {
            case .hand: return "Hand Flicks"
            case .head: return "Head Position"
            case .clap: return "Clapping"
            }
        }

        var instruction: String {
            switch self {
            case .hand:
                return "Hold a hand a foot or two in front of the screen and flick it sideways three times, the way you would to change apps. Flick as you normally would — this is measuring you, not testing you."
            case .head:
                return "Look slowly around the edges of the screen: left, right, top, bottom. Keep your head where you would normally hold it."
            case .clap:
                return "Clap twice, briskly, three separate times. Clap as loudly or as quietly as you actually would."
            }
        }

        var symbol: String {
            switch self {
            case .hand: return "hand.wave"
            case .head: return "cube.transparent"
            case .clap: return "hands.clap"
            }
        }

        var needsCamera: Bool { self != .clap }
        var needsMicrophone: Bool { self == .clap }
    }

    enum Phase: Equatable {
        case idle
        case measuring
        case done(String)
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var progress: Double = 0
    /// What has been measured so far in this run, for the live readout.
    private(set) var detail = ""

    let exercise: Exercise
    private let sensor: CalibrationSensing
    private let defaults: UserDefaults

    private var hand = HandCalibrator()
    private var head = HeadCalibrator()
    private var clap = ClapCalibrator()

    init(
        exercise: Exercise,
        sensor: CalibrationSensing,
        defaults: UserDefaults = .standard
    ) {
        self.exercise = exercise
        self.sensor = sensor
        self.defaults = defaults
    }

    var isMeasuring: Bool { phase == .measuring }

    func start() {
        guard phase != .measuring else { return }
        hand.reset()
        head.reset()
        clap.reset()
        progress = 0
        detail = ""
        phase = .measuring

        switch exercise {
        case .hand:
            sensor.onHandReading = { [weak self] reading, time in
                self?.receive(hand: reading, at: time)
            }
            sensor.startCamera()
        case .head:
            sensor.onHeadReading = { [weak self] reading, _ in
                self?.receive(head: reading)
            }
            sensor.startCamera()
        case .clap:
            sensor.onSoundLevel = { [weak self] level, time in
                self?.receive(level: level, at: time)
            }
            sensor.startMicrophone()
        }
    }

    /// Stops everything. Safe to call more than once, and called on the way out
    /// of the screen however it is left.
    func stop() {
        sensor.onHandReading = nil
        sensor.onHeadReading = nil
        sensor.onSoundLevel = nil
        if exercise.needsCamera { sensor.stopCamera() }
        if exercise.needsMicrophone { sensor.stopMicrophone() }
        if phase == .measuring { phase = .idle }
    }

    /// Gives up on this run and says why, rather than leaving somebody waving
    /// at a screen that is not listening.
    func giveUp() {
        guard phase == .measuring else { return }
        finish(with: .failed(notEnoughMessage))
    }

    private var notEnoughMessage: String {
        switch exercise {
        case .hand:
            return "Didn’t catch three flicks. Make sure your hand is in front of the screen and fully in shot, then try again."
        case .head:
            return "Didn’t see enough movement. Look right around the edges of the screen and try again."
        case .clap:
            return "Didn’t hear three double claps. Clap a little more sharply, and leave a pause between each pair."
        }
    }

    // MARK: - Receiving

    private func receive(hand reading: HandReading, at time: TimeInterval) {
        hand.handSeen(reading, at: time)
        progress = hand.progress
        detail = hand.flicks.isEmpty
            ? "Waiting for a flick…"
            : "\(hand.flicks.count) of \(HandCalibrator.wanted) flicks"
        guard hand.isComplete, let result = hand.result() else { return }
        save {
            $0.flickStartSpeed = result.startSpeed
            $0.flickTravelSpans = result.travelSpans
        }
        finish(with: .done(
            String(
                format: "Set to your flick: %.1f spans a second, %.2f spans of travel.",
                result.startSpeed, result.travelSpans
            )
        ))
    }

    private func receive(head reading: HeadReading) {
        head.headSeen(reading)
        progress = head.progress
        detail = "Watching…"
        guard head.isComplete else { return }
        guard let range = head.result() else {
            finish(with: .failed(notEnoughMessage))
            return
        }
        save { $0.headRange = range }
        finish(with: .done(
            String(format: "Set to how far you actually move: %.2f of the frame.", range)
        ))
    }

    private func receive(level: Double, at time: TimeInterval) {
        clap.heard(level: level, at: time)
        progress = clap.progress
        detail = clap.pairs.isEmpty
            ? "Listening…"
            : "\(clap.pairs.count) of \(ClapCalibrator.wanted) double claps"
        guard clap.isComplete, let result = clap.result() else { return }
        save {
            $0.clapLevel = result.level
            $0.clapMaximumGap = result.maximumGap
        }
        finish(with: .done(
            String(
                format: "Set to your clap: down to %.0f dB, up to %.2fs apart.",
                result.level, result.maximumGap
            )
        ))
    }

    private func save(_ change: (inout CalibrationProfile) -> Void) {
        var profile = CalibrationStore.load(from: defaults)
        change(&profile)
        profile.measuredAt = Date()
        CalibrationStore.save(profile, to: defaults)
    }

    private func finish(with phase: Phase) {
        stop()
        self.phase = phase
        progress = 1
    }
}
