import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Opens a URL that belongs to another installed app.
///
/// Everything the UI knows about launching goes through this protocol, so the
/// carousel and the editor can be exercised with a stub that reports success or
/// failure on demand.
@MainActor
protocol AppLaunching: AnyObject {
    /// - Returns: `true` when the system accepted the URL and switched apps.
    func open(_ url: URL) async -> Bool
}

/// The production launcher.
///
/// Note the deliberate absence of `canOpenURL`: querying arbitrary user entered
/// schemes would require declaring them all in `LSApplicationQueriesSchemes` and
/// amounts to probing what the user has installed. We attempt the open and use
/// its result.
@MainActor
final class SystemAppLauncher: AppLaunching {
    func open(_ url: URL) async -> Bool {
        #if canImport(UIKit)
        return await UIApplication.shared.open(url, options: [:])
        #else
        return false
        #endif
    }
}

/// The outcome of trying to launch an item, including whatever recovery the
/// item makes possible.
enum LaunchOutcome: Equatable, Sendable {
    case opened(URL)
    case failed(canOfferFallback: Bool)
}

/// Owns the "try primary, offer fallback" policy so the view model stays thin
/// and the behaviour is unit-testable.
@MainActor
struct LaunchCoordinator {
    let launcher: AppLaunching

    func launch(_ item: LauncherItem) async -> LaunchOutcome {
        if await launcher.open(item.launchURL) {
            return .opened(item.launchURL)
        }
        return .failed(canOfferFallback: item.fallbackURL != nil)
    }

    func launchFallback(for item: LauncherItem) async -> LaunchOutcome {
        guard let fallback = item.fallbackURL else { return .failed(canOfferFallback: false) }
        if await launcher.open(fallback) {
            return .opened(fallback)
        }
        return .failed(canOfferFallback: false)
    }
}
