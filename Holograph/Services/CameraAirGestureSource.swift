import Foundation
import OSLog

#if canImport(AVFoundation) && canImport(Vision) && os(iOS)
import AVFoundation

/// Air gestures, on top of the shared front-camera session.
///
/// Why this way. Nothing on an iPad reports a hand waving a foot or two away —
/// there is no proximity or depth API for it — and ARKit body tracking is far
/// heavier than the question deserves. `VNDetectHumanHandPoseRequest` returns 21
/// landmarks per hand from an ordinary camera frame, and at one to two feet the
/// hand fills enough of the frame that a VGA feed tracks it comfortably.
///
/// The capture session itself lives in `HoloCameraSource`, because head-tracked
/// depth wants the same frames and two sessions would be twice the power for
/// the same pictures. This type is the part that is only about gestures:
/// attaching, detaching, and asking for permission.
@MainActor
final class CameraAirGestureSource: AirGestureObserving {
    var onGesture: ((AirGesture) -> Void)?
    private(set) var isWatching = false

    private let camera: HoloCameraSource

    init(camera: HoloCameraSource = .shared) {
        self.camera = camera
    }

    func start() {
        guard !isWatching else { return }
        isWatching = true
        camera.onGesture = { [weak self] gesture in self?.onGesture?(gesture) }
        camera.start(.gestures)
    }

    func stop() {
        guard isWatching else { return }
        isWatching = false
        camera.stop(.gestures)
    }

    // MARK: - Permission

    static func requestAccess() async -> Bool {
        await HoloCameraSource.requestAccess()
    }

    static var isAccessDenied: Bool { HoloCameraSource.isAccessDenied }
}

/// Head-tracked depth, on top of the same session.
///
/// A face bounding box is all this needs: where somebody is sitting, not who
/// they are. Nothing is recognised, matched, embedded or stored.
@MainActor
final class CameraHeadTrackingSource: HeadTracking {
    var onPerspective: ((HeadPerspective) -> Void)?
    private(set) var isWatching = false

    private let camera: HoloCameraSource

    init(camera: HoloCameraSource = .shared) {
        self.camera = camera
    }

    func start() {
        guard !isWatching else { return }
        isWatching = true
        camera.onPerspective = { [weak self] perspective in self?.onPerspective?(perspective) }
        camera.start(.head)
    }

    func stop() {
        guard isWatching else { return }
        isWatching = false
        camera.stop(.head)
        // The scene must not be left leaning wherever the last frame put it.
        onPerspective?(.neutral)
    }

    static func requestAccess() async -> Bool {
        await HoloCameraSource.requestAccess()
    }

    static var isAccessDenied: Bool { HoloCameraSource.isAccessDenied }
}

#else

/// Non-iOS builds get sources that watch nothing rather than a build error.
@MainActor
final class CameraAirGestureSource: AirGestureObserving {
    var onGesture: ((AirGesture) -> Void)?
    private(set) var isWatching = false
    func start() { isWatching = true }
    func stop() { isWatching = false }
    static func requestAccess() async -> Bool { false }
    static var isAccessDenied: Bool { true }
}

@MainActor
final class CameraHeadTrackingSource: HeadTracking {
    var onPerspective: ((HeadPerspective) -> Void)?
    private(set) var isWatching = false
    func start() { isWatching = true }
    func stop() { isWatching = false }
    static func requestAccess() async -> Bool { false }
    static var isAccessDenied: Bool { true }
}

#endif
