import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Small, optional tactile accents. iPads without a Taptic Engine simply get
/// nothing, which is why every call site treats this as a nicety rather than
/// part of the interaction.
@MainActor
protocol FeedbackProviding: AnyObject {
    func selectionChanged()
    func launchImpact()
    func failure()
}

@MainActor
final class SystemFeedback: FeedbackProviding {
    // Built on first use. Nothing UIKit-shaped is constructed while the app is
    // still starting up.
    #if canImport(UIKit)
    private lazy var selection = UISelectionFeedbackGenerator()
    private lazy var impact = UIImpactFeedbackGenerator(style: .medium)
    private lazy var notification = UINotificationFeedbackGenerator()
    #endif

    func selectionChanged() {
        #if canImport(UIKit)
        selection.selectionChanged()
        #endif
    }

    func launchImpact() {
        #if canImport(UIKit)
        impact.impactOccurred(intensity: 0.85)
        #endif
    }

    func failure() {
        #if canImport(UIKit)
        notification.notificationOccurred(.warning)
        #endif
    }
}

/// Used by previews and tests.
@MainActor
final class SilentFeedback: FeedbackProviding {
    private(set) var selectionCount = 0
    private(set) var impactCount = 0
    private(set) var failureCount = 0

    func selectionChanged() { selectionCount += 1 }
    func launchImpact() { impactCount += 1 }
    func failure() { failureCount += 1 }
}
