import SwiftUI

@main
struct IdleryLauncherApp: App {
    @State private var composition: AppComposition

    init() {
        // Only dependency wiring happens here. The library is seeded and loaded
        // from RootView's task, once the scene is actually running.
        _composition = State(initialValue: AppComposition.make(environment: LaunchEnvironment.current))
    }

    var body: some Scene {
        WindowGroup {
            RootView(composition: composition)
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
    let composition: AppComposition

    @Environment(HoloMotion.self) private var motion
    @Environment(LauncherViewModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var hasPreparedLibrary = false

    var body: some View {
        LauncherScreen()
            .onChange(of: scenePhase, initial: true) { _, phase in
                motion.isSceneActive = (phase == .active)
                // Returning from the app the user just launched should land on
                // the same icon, with any external changes picked up.
                if phase == .active, hasPreparedLibrary {
                    model.load()
                }
            }
            .onChange(of: reduceMotion, initial: true) { _, prefersReduced in
                motion.prefersReducedMotion = prefersReduced
            }
            .task {
                guard !hasPreparedLibrary else { return }
                hasPreparedLibrary = true
                composition.prepareLibrary()

                if composition.didFallBackToMemory {
                    model.alert = LauncherAlert(
                        title: "Running without saved apps",
                        message: "Your launcher library couldn’t be opened, so changes made now won’t be kept. Restarting the app usually fixes this."
                    )
                }
            }
    }
}
