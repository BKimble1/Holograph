import Foundation

/// Deterministic switches used by automated UI tests.
///
/// Everything here is opt-in through launch arguments, so a build installed from
/// TestFlight or the App Store — which cannot receive launch arguments — always
/// takes the production path.
struct LaunchEnvironment: Sendable, Equatable {
    enum StoreKind: Sendable, Equatable {
        case persistent
        case inMemory
    }

    enum SeedKind: Sendable, Equatable {
        /// Leave whatever is already in the store.
        case untouched
        /// Replace the contents with the five demo apps.
        case demoApps
        /// Replace the contents with nothing, to exercise the empty state.
        case empty
    }

    enum LauncherKind: Sendable, Equatable {
        case system
        case stubbedSuccess
        case stubbedFailure
    }

    var store: StoreKind = .persistent
    var seed: SeedKind = .untouched
    var launcher: LauncherKind = .system
    var animationsDisabled = false
    var isUITesting = false

    enum Argument {
        static let uiTesting = "-uiTesting"
        static let inMemoryStore = "-inMemoryStore"
        static let seedDemoApps = "-seedDemoApps"
        static let seedEmpty = "-seedEmpty"
        static let disableAnimations = "-disableAnimations"
        static let mockLaunchSuccess = "-mockLaunchSuccess"
        static let mockLaunchFailure = "-mockLaunchFailure"
    }

    static func make(from arguments: [String]) -> LaunchEnvironment {
        var environment = LaunchEnvironment()
        let flags = Set(arguments)

        environment.isUITesting = flags.contains(Argument.uiTesting)
        if flags.contains(Argument.inMemoryStore) { environment.store = .inMemory }
        if flags.contains(Argument.seedDemoApps) { environment.seed = .demoApps }
        if flags.contains(Argument.seedEmpty) { environment.seed = .empty }
        if flags.contains(Argument.disableAnimations) { environment.animationsDisabled = true }
        if flags.contains(Argument.mockLaunchSuccess) { environment.launcher = .stubbedSuccess }
        if flags.contains(Argument.mockLaunchFailure) { environment.launcher = .stubbedFailure }

        return environment
    }

    static var current: LaunchEnvironment {
        make(from: ProcessInfo.processInfo.arguments)
    }
}
