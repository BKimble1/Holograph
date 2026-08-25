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
    /// Holds the loading screen open long enough for a test to photograph it
    /// and assert on it. `XCUIApplication.launch()` waits for the app to settle,
    /// which can already outlast the normal intro.
    var holdsLoadingScreen = false
    var freezesLoadingScreen = false

    enum Argument {
        static let uiTesting = "-uiTesting"
        static let inMemoryStore = "-inMemoryStore"
        static let seedDemoApps = "-seedDemoApps"
        static let seedEmpty = "-seedEmpty"
        static let disableAnimations = "-disableAnimations"
        static let mockLaunchSuccess = "-mockLaunchSuccess"
        static let mockLaunchFailure = "-mockLaunchFailure"
        static let holdLoadingScreen = "-holdLoadingScreen"
        static let freezeLoadingScreen = "-freezeLoadingScreen"
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
        if flags.contains(Argument.holdLoadingScreen) { environment.holdsLoadingScreen = true }
        if flags.contains(Argument.freezeLoadingScreen) { environment.freezesLoadingScreen = true }

        return environment
    }

    static var current: LaunchEnvironment {
        var environment = make(from: ProcessInfo.processInfo.arguments)
        if isHostingUnitTests {
            // Unit tests run inside this app. They exercise the repository
            // directly and must never touch — or create — the real library.
            environment.store = .inMemory
            environment.seed = .empty
            environment.animationsDisabled = true
        }
        return environment
    }

    /// `true` only in the app process that hosts the unit-test bundle. UI tests
    /// drive the app from a separate runner, so this stays `false` for them.
    static var isHostingUnitTests: Bool {
        let variables = ProcessInfo.processInfo.environment
        return variables["XCTestConfigurationFilePath"] != nil || variables["XCTestBundlePath"] != nil
    }
}
