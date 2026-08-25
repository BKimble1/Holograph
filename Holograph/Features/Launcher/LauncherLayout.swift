import SwiftUI

/// Size-dependent metrics for the launcher stage.
///
/// Landscape on a full-screen iPad is the design target, but the same formula
/// keeps things sensible in portrait, Split View and Stage Manager by driving
/// everything off the smaller of the two dimensions.
struct LauncherLayout: Equatable {
    let size: CGSize

    var tileSize: CGFloat {
        let byHeight = size.height * 0.34
        let byWidth = size.width * 0.245
        return min(max(min(byHeight, byWidth), 108), 320)
    }

    /// Vertical room reserved for the carousel, including glow headroom.
    var stageHeight: CGFloat { tileSize * 1.42 }

    var pedestalWidth: CGFloat { tileSize * 1.5 }

    var titleFontSize: CGFloat { max(19, min(34, tileSize * 0.145)) }

    var captionFontSize: CGFloat { max(10, min(14, tileSize * 0.058)) }

    var captionSpacing: CGFloat { max(18, tileSize * 0.14) }

    /// Compact widths (a narrow Split View column) drop the extra breathing room.
    var isCompact: Bool { size.width < 620 }
}
