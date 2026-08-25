import SwiftUI

@main
struct IdleryLauncherApp: App {
    @State private var composition: AppComposition

    init() {
        _composition = State(initialValue: AppComposition.make(environment: LaunchEnvironment.current))
    }

    var body: some Scene {
        WindowGroup {
            RootView(didFallBackToMemory: composition.didFallBackToMemory)
                .environment(composition.model)
                .environment(composition.motion)
                .environment(composition.services)
        }
    }
}

/// Keeps the shared `HoloMotion` switch in step with the scene and the user's
/// accessibility settings, then hands over to the one screen this app has.
@MainActor
struct RootView: View {
    let didFallBackToMemory: Bool

    @Environment(HoloMotion.self) private var motion
    @Environment(LauncherViewModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var hasReportedStorageFallback = false

    var body: some View {
        LauncherScreen()
            .onChange(of: scenePhase, initial: true) { _, phase in
                motion.isSceneActive = (phase == .active)
                if phase == .active { model.load() }
            }
            .onChange(of: reduceMotion, initial: true) { _, prefersReduced in
                motion.prefersReducedMotion = prefersReduced
            }
            .task {
                guard didFallBackToMemory, !hasReportedStorageFallback else { return }
                hasReportedStorageFallback = true
                model.alert = LauncherAlert(
                    title: "Running without saved apps",
                    message: "Your launcher library couldn’t be opened, so changes made now won’t be kept. Restarting the app usually fixes this."
                )
            }
    }
}
