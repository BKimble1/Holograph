import Observation
import SwiftUI

/// Central switch for every continuous animation in the app.
///
/// Continuous effects are expensive on battery, pointless when the app is not
/// on screen, and unwelcome when the user has asked for reduced motion — so the
/// decision lives in one place that every `TimelineView` consults.
@MainActor
@Observable
final class HoloMotion {
    /// `false` whenever the scene is inactive or backgrounded.
    var isSceneActive = true
    /// Mirrors `\.accessibilityReduceMotion`.
    var prefersReducedMotion = false
    /// Set by the `-disableAnimations` launch argument so UI tests are stable.
    var isDisabledForTesting = false

    init(isDisabledForTesting: Bool = false) {
        self.isDisabledForTesting = isDisabledForTesting
    }

    /// Whether shimmer, scan-line drift and particles should keep ticking.
    var runsContinuousEffects: Bool {
        isSceneActive && !prefersReducedMotion && !isDisabledForTesting
    }

    /// Fed straight into `TimelineView(.animation(minimumInterval:paused:))`.
    var timelinePaused: Bool { !runsContinuousEffects }

    /// Whether depth, tilt and parallax should be applied while scrolling.
    var appliesDepthEffects: Bool { !prefersReducedMotion }

    /// The animation to use for discrete state changes such as selection.
    var transition: Animation {
        if prefersReducedMotion || isDisabledForTesting {
            return HoloTheme.reducedMotionAnimation
        }
        return HoloTheme.selectionAnimation
    }

    /// How long the loading screen holds before the launcher takes over. Short
    /// under test so the suite is not paced by an animation.
    var introDuration: Duration {
        if isDisabledForTesting { return .milliseconds(600) }
        if prefersReducedMotion { return .milliseconds(900) }
        return .milliseconds(1700)
    }

    /// How long the portal effect runs before the deep link is opened.
    var launchCeremonyDuration: Duration {
        if isDisabledForTesting { return .milliseconds(1) }
        if prefersReducedMotion { return .milliseconds(140) }
        return .milliseconds(420)
    }
}
