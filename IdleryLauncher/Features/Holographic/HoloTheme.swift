import SwiftUI

/// The single source of truth for the launcher's palette and proportions.
///
/// Everything is tuned to read as "restrained holographic": one cyan family,
/// a very deep navy ground, and light added rather than colour replaced so the
/// user's own icon artwork stays recognisable.
enum HoloTheme {
    // MARK: Colours

    /// Near-black navy used for the top of the backdrop.
    static var backgroundTop: Color { Color(red: 0.016, green: 0.043, blue: 0.075) }
    /// Even deeper navy at the edges of the screen.
    static var backgroundDeep: Color { Color(red: 0.004, green: 0.012, blue: 0.027) }
    /// The primary cyan accent.
    static var cyan: Color { Color(red: 0.28, green: 0.76, blue: 1.0) }
    /// A brighter cyan for illuminated edges and highlights.
    static var cyanBright: Color { Color(red: 0.66, green: 0.93, blue: 1.0) }
    /// Muted text colour for secondary labels such as TAP TO OPEN.
    static var secondaryText: Color { Color(red: 0.62, green: 0.72, blue: 0.82) }

    // MARK: Proportions

    /// Corner radius of a holographic tile, as a fraction of its size.
    static var tileCornerRatio: CGFloat { 0.223 }
    /// How large a neighbouring icon is relative to the centred one.
    static var neighbourScale: Double { 0.66 }
    /// How large the second ring of icons is.
    static var outerScale: Double { 0.44 }

    // MARK: Timing

    static var selectionAnimation: Animation { .spring(response: 0.42, dampingFraction: 0.82) }
    static var reducedMotionAnimation: Animation { .easeInOut(duration: 0.2) }

    static func tileShape(size: CGFloat) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: size * tileCornerRatio, style: .continuous)
    }
}
