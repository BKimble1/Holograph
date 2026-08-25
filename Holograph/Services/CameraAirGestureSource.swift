import Foundation
import OSLog

#if canImport(AVFoundation) && canImport(Vision) && os(iOS)
import AVFoundation
import Vision

/// Watches the front camera for a hand flicked left or right in front of the
/// screen, using Vision's hand-pose model.
///
/// Why this way. Nothing on an iPad reports a hand waving a foot or two away —
/// there is no proximity or depth API for it — and ARKit body tracking is far
/// heavier than the question deserves. `VNDetectHumanHandPoseRequest` returns 21
/// landmarks per hand from an ordinary camera frame, and at one to two feet the
/// hand fills enough of the frame that a 640×480 feed tracks it comfortably. The
/// gesture needs exactly one number — where the hand sits across the frame — so
/// the feed is kept deliberately small and slow: VGA at roughly 18 readings a
/// second, late frames discarded.
///
/// Nothing is recorded. Frames are analysed and thrown away; the only thing that
/// leaves this object is a direction.
@MainActor
final class CameraAirGestureSource: AirGestureObserving {
    var onGesture: ((AirGesture) -> Void)?
    private(set) var isWatching = false

    private let engine: CaptureEngine
    private let logger = Logger(subsystem: "com.idlery.holograph", category: "airgesture")

    init() {
        let relay = GestureRelay()
        engine = CaptureEngine(onGesture: { [relay] gesture in relay.deliver(gesture) })
        relay.handler = { [weak self] gesture in self?.onGesture?(gesture) }
    }

    func start() {
        guard !isWatching else { return }
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            logger.info("air gestures started without camera permission; staying off")
            return
        }
        isWatching = true
        engine.start()
    }

    func stop() {
        guard isWatching else { return }
        isWatching = false
        engine.stop()
    }

    // MARK: - Permission

    /// Asks for camera access, reporting whether it was granted.
    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
        default:
            return false
        }
    }

    /// `true` when the answer is no and only the Settings app can change it.
    static var isAccessDenied: Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        return status == .denied || status == .restricted
    }
}

// MARK: - Delivery

/// Carries a gesture from the capture queue back to the main actor.
///
/// `@unchecked Sendable` because `handler` is written once during `init`, before
/// the session that could call it has been started.
private final class GestureRelay: @unchecked Sendable {
    var handler: (@MainActor (AirGesture) -> Void)?

    func deliver(_ gesture: AirGesture) {
        Task { @MainActor in self.handler?(gesture) }
    }
}

// MARK: - Capture

/// Owns the capture session and everything that runs off the main actor.
///
/// `@unchecked Sendable` because every mutable member is confined to `queue`,
/// which is both the configuration queue and the one AVFoundation delivers
/// sample buffers on — a constraint the compiler cannot see but the code keeps.
private final class CaptureEngine: @unchecked Sendable {
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "com.idlery.holograph.airgesture")
    private let processor: FrameProcessor
    private let logger = Logger(subsystem: "com.idlery.holograph", category: "airgesture")

    private var isConfigured = false
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?

    init(onGesture: @escaping @Sendable (AirGesture) -> Void) {
        processor = FrameProcessor()
        processor.onGesture = onGesture
    }

    func start() {
        queue.async { [self] in
            guard configure() else { return }
            if !session.isRunning { session.startRunning() }
        }
    }

    func stop() {
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
            processor.reset()
        }
    }

    /// Builds the session once. Returns whether it is usable.
    private func configure() -> Bool {
        if isConfigured { return true }

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        // VGA is ample for a hand at arm's length and keeps Vision cheap.
        if session.canSetSessionPreset(.vga640x480) {
            session.sessionPreset = .vga640x480
        }

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            logger.error("no usable front camera for air gestures")
            return false
        }
        session.addInput(input)

        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(processor, queue: queue)
        guard session.canAddOutput(output) else {
            logger.error("could not attach the video output for air gestures")
            return false
        }
        session.addOutput(output)

        if let connection = output.connection(with: .video) {
            // Mirrored, so the frame matches what the user sees of themselves:
            // move a hand to your right and it moves right in the image. Without
            // this the front camera records the view from where the camera
            // stands, which has left and right the other way round.
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = true
            }

            // Upright, and kept upright as the iPad turns — otherwise the axis a
            // horizontal flick moves along changes with the orientation.
            let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
            rotationCoordinator = coordinator
            rotationObservation = coordinator.observe(
                \.videoRotationAngleForHorizonLevelCapture,
                options: [.initial, .new]
            ) { [weak self] _, change in
                guard let self, let angle = change.newValue else { return }
                queue.async { self.applyRotation(angle) }
            }
        }

        isConfigured = true
        return true
    }

    private func applyRotation(_ angle: CGFloat) {
        guard let connection = output.connection(with: .video),
              connection.isVideoRotationAngleSupported(angle) else { return }
        connection.videoRotationAngle = angle
        // The frame's axes just moved; a path measured across the old ones is
        // not a gesture.
        processor.reset()
    }
}

// MARK: - Frames

/// Runs Vision on the capture queue and keeps the detector fed.
///
/// `@unchecked Sendable` for the same reason as the engine: all of its mutable
/// state belongs to the capture queue. Nothing here touches the main actor —
/// `onSwipe` hops for itself.
private final class FrameProcessor: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    var onGesture: (@Sendable (AirGesture) -> Void)?

    private var detector = AirGestureDetector()
    private let request = VNDetectHumanHandPoseRequest()
    private var lastAnalysis: TimeInterval = -.greatestFiniteMagnitude
    private var framesWithoutHand = 0

    /// A launcher does not need sixty readings a second to see a flick, and the
    /// camera is somebody's battery.
    private let analysisInterval: TimeInterval = 1.0 / 18.0
    /// Below this a landmark is a guess, and a guessed position is a phantom
    /// gesture.
    private let minimumConfidence: Float = 0.6
    /// A frame or two without a hand is a hiccup in tracking, not a hand
    /// leaving the frame.
    private let framesBeforeHandIsGone = 4

    override init() {
        request.maximumHandCount = 1
        super.init()
    }

    func reset() {
        detector.handLost()
        framesWithoutHand = 0
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        guard timestamp.isFinite else { return }
        guard timestamp - lastAnalysis >= analysisInterval else { return }
        lastAnalysis = timestamp

        // Vision reports positions normalised to the frame, so a square distance
        // needs the frame's own proportions to come back out.
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let width = Double(CVPixelBufferGetWidth(pixels))
        let height = Double(CVPixelBufferGetHeight(pixels))
        guard height > 0 else { return }
        let aspect = width / height

        // The connection already delivers the frame upright and mirrored, so
        // Vision needs no further orientation.
        let handler = VNImageRequestHandler(cmSampleBuffer: sampleBuffer, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return
        }

        guard let observation = request.results?.first,
              let reading = Self.reading(
                  from: observation,
                  aspect: aspect,
                  minimumConfidence: minimumConfidence
              )
        else {
            framesWithoutHand += 1
            if framesWithoutHand >= framesBeforeHandIsGone { detector.handLost() }
            return
        }

        framesWithoutHand = 0
        if let gesture = detector.handSeen(reading, time: timestamp) {
            onGesture?(gesture)
        }
    }

    /// Reduces a hand to the two numbers the detector needs, both measured
    /// against the hand's own size so distance from the camera drops out.
    ///
    /// Position comes from the wrist and knuckles rather than a fingertip:
    /// knuckles stay put while fingers curl, so it follows the hand rather than
    /// whatever shape the fingers are making. The knuckle span is the ruler —
    /// it is the one measurement on a hand that barely changes as the fingers
    /// move, which is exactly what a scale reference has to be.
    static func reading(
        from observation: VNHumanHandPoseObservation,
        aspect: Double,
        minimumConfidence: Float
    ) -> HandReading? {
        func point(_ joint: VNHumanHandPoseObservation.JointName) -> CGPoint? {
            guard let found = try? observation.recognizedPoint(joint),
                  found.confidence >= minimumConfidence else { return nil }
            // Stretch x by the aspect ratio so both axes are in the same units.
            return CGPoint(x: found.location.x * aspect, y: found.location.y)
        }

        let knuckleJoints: [VNHumanHandPoseObservation.JointName] =
            [.wrist, .indexMCP, .middleMCP, .ringMCP, .littleMCP]
        let knuckles = knuckleJoints.compactMap(point)
        // One landmark is not a hand; it is a knuckle-shaped false positive.
        guard knuckles.count >= 2 else { return nil }

        guard let index = point(.indexMCP), let little = point(.littleMCP) else { return nil }
        let span = hypot(index.x - little.x, index.y - little.y)
        // A hand seen edge-on has almost no span, and dividing by it would turn
        // a twitch into a swipe.
        guard span > 0.02 else { return nil }

        let centreX = knuckles.map(\.x).reduce(0, +) / Double(knuckles.count)

        let tipJoints: [VNHumanHandPoseObservation.JointName] =
            [.thumbTip, .indexTip, .middleTip, .ringTip, .littleTip]
        let tips = tipJoints.compactMap(point)
        // Fewer than four fingertips cannot say whether a hand is open or shut.
        guard tips.count >= 4 else { return nil }
        let tipCentre = CGPoint(
            x: tips.map(\.x).reduce(0, +) / Double(tips.count),
            y: tips.map(\.y).reduce(0, +) / Double(tips.count)
        )
        let spread = tips
            .map { hypot($0.x - tipCentre.x, $0.y - tipCentre.y) }
            .reduce(0, +) / Double(tips.count)

        return HandReading(x: centreX / span, spread: spread / span)
    }
}

#endif
