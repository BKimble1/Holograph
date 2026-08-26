import Foundation
import Observation
import SwiftUI

/// The app's dependency container.
///
/// Views reach for it through the environment; every member is a protocol or a
/// value type so previews, unit tests and UI tests can substitute their own.
@MainActor
@Observable
final class AppServices {
    let repository: LauncherRepository
    let launcher: AppLaunching
    let feedback: FeedbackProviding
    let sound: SoundPlaying
    let airGestures: AirGestureObserving
    let headTracking: HeadTracking
    let claps: ClapListening
    let calibration: CalibrationSensing
    let selectionStore: SelectionStoring
    let iconProcessor: IconProcessor
    let metadataProvider: AppStoreMetadataProviding

    init(
        repository: LauncherRepository,
        launcher: AppLaunching,
        feedback: FeedbackProviding,
        sound: SoundPlaying,
        airGestures: AirGestureObserving,
        headTracking: HeadTracking,
        claps: ClapListening,
        calibration: CalibrationSensing,
        selectionStore: SelectionStoring,
        iconProcessor: IconProcessor = IconProcessor(),
        metadataProvider: AppStoreMetadataProviding = AppStoreLookupService()
    ) {
        self.repository = repository
        self.launcher = launcher
        self.feedback = feedback
        self.sound = sound
        self.airGestures = airGestures
        self.headTracking = headTracking
        self.claps = claps
        self.calibration = calibration
        self.selectionStore = selectionStore
        self.iconProcessor = iconProcessor
        self.metadataProvider = metadataProvider
    }
}

/// Wires everything together for a given launch environment.
///
/// This is the only place that decides "real store or in-memory", "real
/// launcher or stub" — the rest of the app just uses what it is handed.
///
/// Note what this deliberately does *not* do: it never touches the library and
/// never rasterises anything. `App.init()` runs before the scene exists, and
/// rendering SwiftUI content there can deadlock. Seeding and the first load
/// happen from `prepareLibrary()`, which the root view calls in a `task`.
@MainActor
struct AppComposition {
    let services: AppServices
    let motion: HoloMotion
    let model: LauncherViewModel
    /// `true` when the on-disk store could not be opened and we fell back to
    /// memory, so the UI can say so instead of silently losing data.
    let didFallBackToMemory: Bool
    /// Applied once the scene is up, not during `App.init()`.
    let pendingSeed: LaunchEnvironment.SeedKind

    static func make(environment: LaunchEnvironment) -> AppComposition {
        let wantsMemoryStore = environment.store == .inMemory
        let repository: LauncherRepository
        let storageDegraded: Bool

        switch ModelContainerFactory.make(inMemory: wantsMemoryStore) {
        case .ready(let container):
            repository = SwiftDataLauncherRepository(container: container)
            storageDegraded = false
        case .unavailable:
            // Nothing will persist, but the launcher still opens and works for
            // this session — and says so.
            repository = InMemoryLauncherRepository()
            storageDegraded = !wantsMemoryStore
        }

        let launcher: AppLaunching
        switch environment.launcher {
        case .system:
            launcher = SystemAppLauncher()
        case .stubbedSuccess:
            launcher = StubAppLauncher(outcome: true)
        case .stubbedFailure:
            launcher = StubAppLauncher(outcome: false)
        }

        let feedback: FeedbackProviding = environment.isUITesting ? SilentFeedback() : SystemFeedback()
        // Tests must stay silent and deterministic, and nothing should try to
        // start an audio engine inside a test host.
        let staysQuiet = environment.isUITesting || LaunchEnvironment.isHostingUnitTests

        // Tests get stubs: there is no camera and no room in the simulator, and
        // a UI test must not depend on either.
        let airGestures: AirGestureObserving
        let headTracking: HeadTracking
        let claps: ClapListening
        let calibration: CalibrationSensing
        #if os(iOS)
        // Both camera features attach to the same session; see HoloCameraSource.
        airGestures = staysQuiet ? InertAirGestureSource() : CameraAirGestureSource()
        headTracking = staysQuiet ? InertHeadTrackingSource() : CameraHeadTrackingSource()
        claps = staysQuiet ? InertClapListener() : MicrophoneClapSource()
        calibration = staysQuiet ? InertCalibrationSensor() : LiveCalibrationSensor()
        #else
        airGestures = InertAirGestureSource()
        headTracking = InertHeadTrackingSource()
        claps = InertClapListener()
        calibration = InertCalibrationSensor()
        #endif

        // The launch voice, in two layers. The neural model speaks when a
        // build ships one; the system's British voice speaks when it does not,
        // which is what makes a fresh download talk without being set up
        // first. Tests get neither: the weights are larger than the rest of
        // the app, and a unit suite that waits for Core ML is a unit suite
        // nobody runs.
        let speech: NeuralSpeaking = staysQuiet
            ? StubNeuralSpeech()
            : LayeredSpeech(preferred: KokoroSpeechEngine(), fallback: SystemVoiceSpeechEngine())
        let sound: SoundPlaying = staysQuiet ? SilentSound() : SystemSound(speech: speech)
        // The launcher's own tick and its voice come out of the same speaker the
        // microphone is pointed at, and two ticks in a second read as a perfectly
        // good double clap. Whenever it makes a noise, the listener looks away.
        sound.onOwnSound = { [weak claps] duration in
            claps?.mute(for: duration)
        }
        let selectionStore: SelectionStoring = environment.isUITesting
            ? InMemorySelectionStore()
            : UserDefaultsSelectionStore()

        let services = AppServices(
            repository: repository,
            launcher: launcher,
            feedback: feedback,
            sound: sound,
            airGestures: airGestures,
            headTracking: headTracking,
            claps: claps,
            calibration: calibration,
            selectionStore: selectionStore
        )

        let motion = HoloMotion(
            isDisabledForTesting: environment.animationsDisabled,
            holdsLoadingScreen: environment.holdsLoadingScreen,
            freezesLoadingScreen: environment.freezesLoadingScreen
        )

        let model = LauncherViewModel(
            repository: repository,
            launcher: launcher,
            feedback: feedback,
            sound: sound,
            selectionStore: selectionStore,
            motion: motion
        )

        return AppComposition(
            services: services,
            motion: motion,
            model: model,
            didFallBackToMemory: storageDegraded,
            pendingSeed: environment.seed
        )
    }

    /// Applies the launch-argument seed, if any, and performs the first load.
    /// Safe to call more than once; the caller guards it with a flag.
    func prepareLibrary() {
        Self.applySeed(pendingSeed, to: services.repository)
        model.load()
    }

    private static func applySeed(_ seed: LaunchEnvironment.SeedKind, to repository: LauncherRepository) {
        switch seed {
        case .untouched:
            // First run with nothing stored gets the demo set so the launcher is
            // never a blank stage by accident.
            if (try? repository.fetchAll())?.isEmpty == true, !FirstRunMarker.hasCompletedFirstRun {
                try? repository.replaceAll(with: DemoContent.drafts())
                FirstRunMarker.markFirstRunComplete()
            }
        case .demoApps:
            try? repository.replaceAll(with: DemoContent.drafts())
        case .empty:
            try? repository.removeAll()
        }
    }
}

/// Remembers that the demo apps were offered once, so a user who deletes them
/// never has them reappear.
enum FirstRunMarker {
    private static let key = "com.idlery.holograph.hasCompletedFirstRun"

    static var hasCompletedFirstRun: Bool {
        UserDefaults.standard.bool(forKey: key)
    }

    static func markFirstRunComplete() {
        UserDefaults.standard.set(true, forKey: key)
    }
}
