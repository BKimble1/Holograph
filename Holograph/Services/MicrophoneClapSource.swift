import Foundation
import OSLog

#if canImport(AVFoundation) && os(iOS)
import AVFoundation

/// Listens to the microphone for two claps, and opens the centred app.
///
/// Why the microphone rather than the camera. Opening an app used to be a hand
/// thrown open in front of the lens, which asked the camera to tell a deliberate
/// pose from an ordinary one at two feet — a judgement it is not good at, and
/// one that competed with the swipe for the same hand. A clap is unambiguous,
/// works with the iPad across the room, and needs no line of sight.
///
/// Nothing is recorded. Each buffer is reduced to a handful of loudness numbers
/// on the audio thread and discarded; no audio is stored, and nothing leaves the
/// iPad. The only thing that comes out of here is "that was two claps".
@MainActor
final class MicrophoneClapSource: ClapListening {
    var onDoubleClap: (() -> Void)?
    /// Raw loudness, for calibration — which is measuring the thresholds the
    /// detector uses and so cannot depend on them.
    var onLevel: ((Double, TimeInterval) -> Void)?
    private(set) var isListening = false

    private let engine: ClapEngine
    private let logger = Logger(subsystem: "com.idlery.holograph", category: "clap")

    init() {
        let relay = ClapRelay()
        engine = ClapEngine(
            onDoubleClap: { [relay] in relay.deliver() },
            onLevel: { [relay] level, time in relay.deliverLevel(level, time) }
        )
        relay.handler = { [weak self] in self?.onDoubleClap?() }
        relay.levelHandler = { [weak self] level, time in self?.onLevel?(level, time) }
    }

    func start() {
        guard !isListening else { return }
        guard AVAudioApplication.shared.recordPermission == .granted else {
            logger.info("clap to open started without microphone permission; staying off")
            return
        }
        isListening = true
        // Whatever has been measured about how this person claps.
        engine.setProfile(CalibrationStore.load())
        HoloAudioSession.requireInput()
        engine.start()
    }

    func stop() {
        guard isListening else { return }
        isListening = false
        engine.stop()
        HoloAudioSession.releaseInput()
    }

    func mute(for duration: TimeInterval) {
        engine.mute(for: duration)
    }

    /// Whether raw loudness is reported alongside claps. Only calibration wants
    /// it, and it is a stream of numbers thirty times a second.
    func setReportsLevels(_ reports: Bool) {
        engine.setReportsLevels(reports)
    }

    // MARK: - Permission

    /// Asks for the microphone, reporting whether it was granted.
    static func requestAccess() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .undetermined:
            return await AVAudioApplication.requestRecordPermission()
        default:
            return false
        }
    }

    /// `true` when the answer is no and only the Settings app can change it.
    static var isAccessDenied: Bool {
        AVAudioApplication.shared.recordPermission == .denied
    }
}

// MARK: - Delivery

/// Carries the result from the audio queue back to the main actor.
///
/// `@unchecked Sendable` because `handler` is written once during `init`, before
/// anything that could call it has been started.
private final class ClapRelay: @unchecked Sendable {
    var handler: (@MainActor () -> Void)?
    var levelHandler: (@MainActor (Double, TimeInterval) -> Void)?

    func deliver() {
        Task { @MainActor in self.handler?() }
    }

    func deliverLevel(_ level: Double, _ time: TimeInterval) {
        Task { @MainActor in self.levelHandler?(level, time) }
    }
}

// MARK: - Listening

/// Owns the audio engine and everything that runs off the main actor.
///
/// `@unchecked Sendable` because every mutable member is confined to `queue` —
/// a constraint the compiler cannot see but the code keeps. The one exception is
/// the tap closure, which runs on a realtime audio thread and does nothing but
/// reduce the buffer to a few numbers and hand them over.
private final class ClapEngine: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "com.idlery.holograph.clap")
    private let onDoubleClap: @Sendable () -> Void
    private let onLevel: @Sendable (Double, TimeInterval) -> Void
    private var reportsLevels = false
    private let logger = Logger(subsystem: "com.idlery.holograph", category: "clap")

    private var detector = ClapDetector()
    private var isRunning = false
    /// The most recent reading's timestamp, which is the clock everything here
    /// shares. Muting is expressed against it rather than against a wall clock,
    /// so there is only ever one notion of time in play.
    private var lastReading: TimeInterval = 0
    private var configurationObserver: NSObjectProtocol?

    init(
        onDoubleClap: @escaping @Sendable () -> Void,
        onLevel: @escaping @Sendable (Double, TimeInterval) -> Void
    ) {
        self.onDoubleClap = onDoubleClap
        self.onLevel = onLevel
    }

    func setReportsLevels(_ reports: Bool) {
        queue.async { [self] in reportsLevels = reports }
    }

    /// Rebuilds the detector around whatever has been measured about this
    /// person's clap.
    func setProfile(_ profile: CalibrationProfile) {
        queue.async { [self] in
            detector = ClapDetector(thresholds: ClapDetector.Thresholds.default.applying(profile))
        }
    }

    deinit {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
    }

    func start() {
        queue.async { [self] in
            guard !isRunning else { return }
            detector.reset()
            guard install() else { return }
            do {
                engine.prepare()
                try engine.start()
                isRunning = true
            } catch {
                logger.error("microphone unavailable: \(error.localizedDescription, privacy: .public)")
                engine.inputNode.removeTap(onBus: 0)
            }
        }
    }

    func stop() {
        queue.async { [self] in
            guard isRunning else { return }
            isRunning = false
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            detector.reset()
        }
    }

    func mute(for duration: TimeInterval) {
        queue.async { [self] in
            detector.mute(for: duration, from: lastReading)
        }
    }

    /// Attaches the tap. Returns whether the input is usable at all — a format
    /// with no channels means there is nothing to listen to.
    private func install() -> Bool {
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            logger.error("no usable microphone input for clap to open")
            return false
        }

        observeConfigurationChanges()
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, when in
            guard let self, let channel = buffer.floatChannelData?[0] else { return }
            let samples = UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))
            let peaks = ClapLevels.peaks(of: samples)
            guard !peaks.isEmpty else { return }

            // Sample time is the steadiest clock available here and needs no
            // conversion; the host clock is the fallback for inputs that do not
            // report one.
            let rate = when.sampleRate > 0 ? when.sampleRate : buffer.format.sampleRate
            let base = when.isSampleTimeValid && rate > 0
                ? Double(when.sampleTime) / rate
                : AVAudioTime.seconds(forHostTime: when.hostTime)
            let step = Double(ClapLevels.chunkFrames) / max(rate, 1)

            queue.async { [self] in
                for (index, peak) in peaks.enumerated() {
                    let time = base + Double(index) * step
                    lastReading = time
                    if reportsLevels { onLevel(Double(peak), time) }
                    if detector.heard(level: Double(peak), at: time) {
                        onDoubleClap()
                    }
                }
            }
        }
        return true
    }

    /// A route change — headphones, a Bluetooth speaker, a call ending — tears
    /// the graph down underneath us. Without this the feature simply stops
    /// working and says nothing about it.
    private func observeConfigurationChanges() {
        guard configurationObserver == nil else { return }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            queue.async { [self] in
                guard isRunning else { return }
                isRunning = false
                engine.inputNode.removeTap(onBus: 0)
                engine.stop()
                detector.reset()
                guard install() else { return }
                do {
                    engine.prepare()
                    try engine.start()
                    isRunning = true
                } catch {
                    logger.error("could not restart after a route change: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }
}

#else

/// Non-iOS builds get a listener that hears nothing rather than a build error.
@MainActor
final class MicrophoneClapSource: ClapListening {
    var onDoubleClap: (() -> Void)?
    /// Raw loudness, for calibration — which is measuring the thresholds the
    /// detector uses and so cannot depend on them.
    var onLevel: ((Double, TimeInterval) -> Void)?
    private(set) var isListening = false

    func start() { isListening = true }
    func stop() { isListening = false }
    func mute(for duration: TimeInterval) {}

    static func requestAccess() async -> Bool { false }
    static var isAccessDenied: Bool { true }
}

#endif
