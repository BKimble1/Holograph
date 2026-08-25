import Foundation

/// A launcher that reports a fixed outcome and records what it was asked to
/// open.
///
/// Only ever installed when a `-mockLaunch…` launch argument is present, which
/// an App Store or TestFlight install cannot supply — so the shipping app always
/// goes through `SystemAppLauncher`. It lives in the app target rather than the
/// test bundle because UI tests drive the app from the outside.
@MainActor
final class StubAppLauncher: AppLaunching {
    private(set) var openedURLs: [URL] = []
    var outcome: Bool

    init(outcome: Bool) {
        self.outcome = outcome
    }

    func open(_ url: URL) async -> Bool {
        openedURLs.append(url)
        return outcome
    }
}
