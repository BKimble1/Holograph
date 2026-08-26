import Foundation
import OSLog

#if canImport(AVFoundation) && canImport(Vision) && os(iOS)
import AVFoundation
import Vision

/// The one front-camera session in Holograph.
///
/// Two features want the camera — air gestures and head-tracked depth — and
/// they want the same frames. Running an `AVCaptureSession` each would be twice
/// the power, twice the thermal load, and on iPadOS the second one to start
/// simply loses. So there is one session here, and features attach to it.
///
/// It runs while at least one feature is attached and stops the moment the last
/// one lets go, which is what keeps the camera off behind Settings, behind the
/// browser and in the background.
///
/// Nothing is recorded. Frames are analysed and discarded; what leaves this
/// object is a direction and a viewing angle. No image, no face, no identity,
/// nothing stored anywhere.
@MainActor
final class HoloCameraSource {
    /// What a feature is asking the camera for.
    enum Consumer: Hashable, CaseIterable {
        case gestures
        case head
    }

    static let shared = HoloCameraSource()

    var onGesture: ((AirGesture) -> Void)?
    var onPerspective: ((HeadPerspective) -> Void)?

    private(set) var attached: Set<Consumer> = []
    var isRunning: Bool { !attached.isEmpty }

    private let engine: CaptureEngine
    private let logger = Logger(subsystem: "com.idlery.holograph", category: "camera")

    init() {
        let relay = CameraRelay()
        engine = CaptureEngine(
            onGesture: { [relay] gesture in relay.deliverGesture(gesture) },
            onPerspective: { [relay] perspective in relay.deliverPerspective(perspective) }
        )
        relay.gestureHandler = { [weak self] gesture in self?.onGesture?(gesture) }
        relay.perspectiveHandler = { [weak self] perspective in self?.onPerspective?(perspective) }
    }

    func start(_ consumer: Consumer) {
        guard !attached.contains(consumer) else { return }
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            logger.info("camera feature started without permission; staying off")
            return
        }
        attached.insert(consumer)
        engine.setAnalyses(hands: attached.contains(.gestures), faces: attached.contains(.head))
        engine.start()
    }

    func stop(_ consumer: Consumer) {
        guard attached.remove(consumer) != nil else { return }
        engine.setAnalyses(hands: attached.contains(.gestures), faces: attached.contains(.head))
        if attached.isEmpty {
            engine.stop()
        }
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

/// Carries results from the capture queue back to the main actor.
///
/// `@unchecked Sendable` because both handlers are written once during `init`,
/// before the session that could call them has been started.
private final class CameraRelay: @unchecked Sendable {
    var gestureHandler: (@MainActor (AirGesture) -> Void)?
    var perspectiveHandler: (@MainActor (HeadPerspective) -> Void)?

    func deliverGesture(_ gesture: AirGesture) {
        Task { @MainActor in self.gestureHandler?(gesture) }
    }

    func deliverPerspective(_ perspective: HeadPerspective) {
        Task { @MainActor in self.perspectiveHandler?(perspective) }
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
    private let queue = DispatchQueue(label: "com.idlery.holograph.camera")
    private let processor: FrameProcessor
    private let logger = Logger(subsystem: "com.idlery.holograph", category: "camera")

    private var isConfigured = false
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?

    init(
        onGesture: @escaping @Sendable (AirGesture) -> Void,
        onPerspective: @escaping @Sendable (HeadPerspective) -> Void
    ) {
        processor = FrameProcessor()
        processor.onGesture = onGesture
        processor.onPerspective = onPerspective
    }

    /// Which Vision requests are worth running. Face detection is not free, so
    /// it only runs when something is actually using a viewing angle.
    func setAnalyses(hands: Bool, faces: Bool) {
        queue.async { [self] in
            processor.tracksHands = hands
            processor.tracksFaces = faces
        }
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

        // VGA is ample for a hand at arm's length and a head in front of the
        // screen, and keeps Vision cheap.
        if session.canSetSessionPreset(.vga640x480) {
            session.sessionPreset = .vga640x480
        }

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            logger.error("no usable front camera")
            return false
        }
        session.addInput(input)

        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(processor, queue: queue)
        guard session.canAddOutput(output) else {
            logger.error("could not attach the video output")
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
        // not a gesture, and a head measured against them is not a viewpoint.
        processor.reset()
    }
}

// MARK: - Frames

/// Runs Vision on the capture queue and keeps both detectors fed.
///
/// `@unchecked Sendable` for the same reason as the engine: all of its mutable
/// state belongs to the capture queue. Nothing here touches the main actor —
/// the callbacks hop for themselves.
private final class FrameProcessor: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    var onGesture: (@Sendable (AirGesture) -> Void)?
    var onPerspective: (@Sendable (HeadPerspective) -> Void)?

    var tracksHands = false
    var tracksFaces = false

    private var detector = AirGestureDetector()
    private var tracker = HeadTracker()
    private let handRequest = VNDetectHumanHandPoseRequest()
    /// Rectangles only. Landmarks would cost more and say nothing extra about
    /// where somebody is sitting, and nothing here needs to know whose face it
    /// is — only roughly where it is.
    private let faceRequest = VNDetectFaceRectanglesRequest()

    private var lastAnalysis: TimeInterval = -.greatestFiniteMagnitude
    private var lastHandSeen: TimeInterval = -.greatestFiniteMagnitude
    private var lastFaceSeen: TimeInterval = -.greatestFiniteMagnitude
    /// A hand does not change width, so the last measured span stands in when
    /// the current frame is too blurred to measure one.
    private var lastSpan: Double?

    /// Thirty readings a second rather than eighteen.
    ///
    /// A flick lasts about three tenths of a second, and every reading lost to
    /// motion blur is a fifth of the evidence gone at eighteen. Sampling faster
    /// is worth far more than loosening what counts as a flick: measured
    /// against a model of the blur, it lifts a short flick from a two-in-three
    /// chance of registering to nine in ten, and unlike a looser threshold it
    /// costs nothing in false ones.
    private let analysisInterval: TimeInterval = 1.0 / 30.0
    /// Low, deliberately. A hand mid-flick is smeared across the frame and
    /// Vision is not confident about any part of it — which is exactly the
    /// moment the reading matters. Position comes from the average of several
    /// knuckles, so a middling landmark moves it very little, while discarding
    /// the frame outright loses the flick.
    private let minimumConfidence: Float = 0.35
    /// How long a hand may be unreadable before it counts as gone.
    private let handGoneAfter: TimeInterval = 0.5
    /// And a face. Longer, because losing the viewer for a moment should settle
    /// the scene gently rather than drop it.
    private let faceGoneAfter: TimeInterval = 0.25

    override init() {
        handRequest.maximumHandCount = 1
        super.init()
    }

    func reset() {
        detector.handLost()
        tracker.reset()
        lastHandSeen = -.greatestFiniteMagnitude
        lastFaceSeen = -.greatestFiniteMagnitude
        lastSpan = nil
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

        var requests: [VNRequest] = []
        if tracksHands { requests.append(handRequest) }
        if tracksFaces { requests.append(faceRequest) }
        guard !requests.isEmpty else { return }

        // One handler, both requests: the frame is decoded once however many
        // things are looking at it.
        let handler = VNImageRequestHandler(cmSampleBuffer: sampleBuffer, orientation: .up, options: [:])
        do {
            try handler.perform(requests)
        } catch {
            return
        }

        if tracksHands { processHands(aspect: aspect, at: timestamp) }
        if tracksFaces { processFaces(at: timestamp) }
    }

    private func processHands(aspect: Double, at timestamp: TimeInterval) {
        guard let observation = handRequest.results?.first,
              let reading = Self.handReading(
                  from: observation,
                  aspect: aspect,
                  minimumConfidence: minimumConfidence,
                  fallbackSpan: lastSpan
              )
        else {
            if timestamp - lastHandSeen >= handGoneAfter {
                detector.handLost()
                lastSpan = nil
            }
            return
        }

        lastHandSeen = timestamp
        lastSpan = reading.span
        if let gesture = detector.handSeen(reading, time: timestamp) {
            onGesture?(gesture)
        }
    }

    private func processFaces(at timestamp: TimeInterval) {
        // The nearest face is the one looking at the screen; anybody further
        // back is in the room, not using the iPad.
        guard let face = faceRequest.results?.max(by: { $0.boundingBox.height < $1.boundingBox.height }) else {
            if timestamp - lastFaceSeen >= faceGoneAfter {
                onPerspective?(tracker.headLost(at: timestamp))
            }
            return
        }
        lastFaceSeen = timestamp
        let box = face.boundingBox
        onPerspective?(
            tracker.headSeen(
                HeadReading(
                    // Vision's origin is the bottom left, and the frame is
                    // already mirrored, so this reads the way the viewer moves.
                    x: Double(box.midX) * 2 - 1,
                    y: Double(box.midY) * 2 - 1,
                    scale: Double(box.height)
                ),
                at: timestamp
            )
        )
    }

    /// Reduces a hand to what the detector needs, measured against the hand's
    /// own size so distance from the camera drops out.
    ///
    /// Position comes from the wrist and knuckles, never a fingertip: knuckles
    /// stay put while fingers curl, so it follows the hand rather than whatever
    /// shape the fingers are making. The knuckle span is the ruler — the one
    /// measurement on a hand that barely changes as the fingers move.
    static func handReading(
        from observation: VNHumanHandPoseObservation,
        aspect: Double,
        minimumConfidence: Float,
        fallbackSpan: Double? = nil
    ) -> HandReading? {
        func point(
            _ joint: VNHumanHandPoseObservation.JointName,
            confidence: Float = minimumConfidence
        ) -> CGPoint? {
            guard let found = try? observation.recognizedPoint(joint),
                  found.confidence >= confidence else { return nil }
            // Stretch x by the aspect ratio so both axes are in the same units.
            return CGPoint(x: found.location.x * aspect, y: found.location.y)
        }

        let knuckleJoints: [VNHumanHandPoseObservation.JointName] =
            [.wrist, .indexMCP, .middleMCP, .ringMCP, .littleMCP]
        let knuckles = knuckleJoints.compactMap { point($0) }
        // One landmark is not a hand; it is a knuckle-shaped false positive.
        guard knuckles.count >= 2 else { return nil }

        // A hand's width is the one thing about it that does not change, so a
        // frame too smeared to measure one borrows the last. Losing the ruler
        // used to lose the whole reading, mid-flick, every time.
        guard let span = span(from: observation, point: point) ?? fallbackSpan else { return nil }
        let centreX = knuckles.map(\.x).reduce(0, +) / Double(knuckles.count)

        // x and span travel separately. Dividing here would fold the noise in
        // the scale estimate into the position, which is most of a flick's worth
        // of phantom movement on a hand that is not moving at all.
        return HandReading(
            x: centreX,
            span: span,
            spread: spread(from: observation, span: span, point: point)
        )
    }

    /// The hand's width, in the frame's own units.
    ///
    /// Across the knuckles when both edges are visible; from the wrist to the
    /// middle knuckle otherwise, which is about a fifth longer than the hand is
    /// wide. Having a fallback matters: losing the ruler loses the reading.
    private static func span(
        from observation: VNHumanHandPoseObservation,
        point: (VNHumanHandPoseObservation.JointName, Float) -> CGPoint?
    ) -> Double? {
        var measured: Double?
        if let index = point(.indexMCP, 0.3), let little = point(.littleMCP, 0.3) {
            measured = hypot(index.x - little.x, index.y - little.y)
        } else if let wrist = point(.wrist, 0.3), let middle = point(.middleMCP, 0.3) {
            measured = hypot(wrist.x - middle.x, wrist.y - middle.y) / 1.2
        }
        // A hand seen edge-on has almost no span, and dividing by it would turn
        // a twitch into a swipe.
        guard let measured, measured > 0.02 else { return nil }
        return measured
    }

    /// How far the fingertips sit from their own centre, in spans, or `nil` when
    /// too few of them can be seen to tell an open hand from a closed one.
    private static func spread(
        from observation: VNHumanHandPoseObservation,
        span: Double,
        point: (VNHumanHandPoseObservation.JointName, Float) -> CGPoint?
    ) -> Double? {
        let tipJoints: [VNHumanHandPoseObservation.JointName] =
            [.thumbTip, .indexTip, .middleTip, .ringTip, .littleTip]
        let tips = tipJoints.compactMap { point($0, 0.4) }
        guard tips.count >= 3 else { return nil }

        let centre = CGPoint(
            x: tips.map(\.x).reduce(0, +) / Double(tips.count),
            y: tips.map(\.y).reduce(0, +) / Double(tips.count)
        )
        let mean = tips
            .map { hypot($0.x - centre.x, $0.y - centre.y) }
            .reduce(0, +) / Double(tips.count)
        return mean / span
    }
}

#endif
