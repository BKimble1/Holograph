import Foundation

/// The raw feeds calibration needs.
///
/// Separate from `AirGestureObserving` and `ClapListening` on purpose: those
/// hand out *gestures*, decided by the very thresholds calibration is trying to
/// measure. Measuring a threshold with a tool that already applies it would
/// only ever confirm what was already there.
@MainActor
protocol CalibrationSensing: AnyObject {
    var onHandReading: ((HandReading, TimeInterval) -> Void)? { get set }
    var onHeadReading: ((HeadReading, TimeInterval) -> Void)? { get set }
    var onSoundLevel: ((Double, TimeInterval) -> Void)? { get set }

    func startCamera()
    func stopCamera()
    func startMicrophone()
    func stopMicrophone()
}

#if os(iOS)

/// Calibration on top of the shared camera and the microphone.
///
/// It attaches to the same `HoloCameraSource` everything else uses, so
/// calibrating while air gestures are on does not start a second session.
@MainActor
final class LiveCalibrationSensor: CalibrationSensing {
    var onHandReading: ((HandReading, TimeInterval) -> Void)?
    var onHeadReading: ((HeadReading, TimeInterval) -> Void)?
    var onSoundLevel: ((Double, TimeInterval) -> Void)?

    private let camera: HoloCameraSource
    private let microphone: MicrophoneClapSource
    private var isWatching = false
    private var isListening = false

    init(camera: HoloCameraSource = .shared, microphone: MicrophoneClapSource = MicrophoneClapSource()) {
        self.camera = camera
        self.microphone = microphone
    }

    func startCamera() {
        guard !isWatching else { return }
        isWatching = true
        camera.onHandReading = { [weak self] reading, time in self?.onHandReading?(reading, time) }
        camera.onHeadReading = { [weak self] reading, time in self?.onHeadReading?(reading, time) }
        camera.start(.calibration)
    }

    func stopCamera() {
        guard isWatching else { return }
        isWatching = false
        camera.onHandReading = nil
        camera.onHeadReading = nil
        camera.stop(.calibration)
    }

    func startMicrophone() {
        guard !isListening else { return }
        isListening = true
        microphone.onLevel = { [weak self] level, time in self?.onSoundLevel?(level, time) }
        microphone.setReportsLevels(true)
        microphone.start()
    }

    func stopMicrophone() {
        guard isListening else { return }
        isListening = false
        microphone.setReportsLevels(false)
        microphone.onLevel = nil
        microphone.stop()
    }
}

#endif

/// Used by previews, unit tests and the UI suite. Opens nothing, and lets a
/// test play a hand, a head or a room through the calibrators by hand.
@MainActor
final class InertCalibrationSensor: CalibrationSensing {
    var onHandReading: ((HandReading, TimeInterval) -> Void)?
    var onHeadReading: ((HeadReading, TimeInterval) -> Void)?
    var onSoundLevel: ((Double, TimeInterval) -> Void)?

    private(set) var cameraStarts = 0
    private(set) var cameraStops = 0
    private(set) var microphoneStarts = 0
    private(set) var microphoneStops = 0

    func startCamera() { cameraStarts += 1 }
    func stopCamera() { cameraStops += 1 }
    func startMicrophone() { microphoneStarts += 1 }
    func stopMicrophone() { microphoneStops += 1 }

    func emit(hand: HandReading, at time: TimeInterval) { onHandReading?(hand, time) }
    func emit(head: HeadReading, at time: TimeInterval) { onHeadReading?(head, time) }
    func emit(level: Double, at time: TimeInterval) { onSoundLevel?(level, time) }
}
