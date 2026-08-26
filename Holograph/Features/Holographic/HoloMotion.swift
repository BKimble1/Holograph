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
    /// Set by `-holdLoadingScreen` so a test can assert on the intro.
    var holdsLoadingScreen = false
    /// Keeps the intro up indefinitely, for the one test that photographs it.
    var freezesLoadingScreen = false
    /// Where the viewer is, when head tracking is running. Lives here rather
    /// than in a view's `@State` because the camera's callback outlives any
    /// particular view struct, and a service holding a stale copy of a view is
    /// exactly the bug that pattern invites.
    var headPerspective: HeadPerspective = .neutral

    init(
        isDisabledForTesting: Bool = false,
        holdsLoadingScreen: Bool = false,
        freezesLoadingScreen: Bool = false
    ) {
        self.freezesLoadingScreen = freezesLoadingScreen
        self.isDisabledForTesting = isDisabledForTesting
        self.holdsLoadingScreen = holdsLoadingScreen
    }

    /// Whether shimmer, scan-line drift and particles should keep ticking.
    var runsContinuousEffects: Bool {
        isSceneActive && !prefersReducedMotion && !isDisabledForTesting
    }

    /// Fed straight into `TimelineView(.animation(minimumInterval:paused:))`.
    var timelinePaused: Bool { !runsContinuousEffects }

    /// Whether depth, tilt and parallax should be applied while scrolling.
    var appliesDepthEffects: Bool { !prefersReducedMotion }

    /// How much of the head-tracked perspective to apply, 0…1.
    ///
    /// Reduce Motion does not switch it off outright — a window that responds
    /// to where you are sitting is the point of the feature, and losing it
    /// entirely is a worse answer than losing most of it. What it does is take
    /// the movement down to a quarter, which keeps the sense of depth while
    /// putting the actual travel well inside what Reduce Motion is asking for.
    /// Under test it is off completely, so screenshots do not depend on a face.
    var headParallaxScale: Double {
        if isDisabledForTesting { return 0 }
        if prefersReducedMotion { return 0.25 }
        return 1
    }

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
        // Photographing the intro should not be a race against a timer that
        // launch and an orientation change can already outrun on a slow runner.
        if freezesLoadingScreen { return .seconds(60 * 60) }
        if holdsLoadingScreen { return .seconds(8) }
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
