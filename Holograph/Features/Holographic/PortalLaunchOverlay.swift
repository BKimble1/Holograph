import SwiftUI

/// The short "portal" flourish played between tapping the centred tile and the
/// system switching apps: the tile's own glow intensifies (handled by
/// `HolographicIconView`) while a soft flash in the tile's own shape lifts the
/// whole stage.
///
/// There used to be a ring here as well, and it was a mistake. It was drawn
/// from a `Circle`, so at rest — with no launch in progress at all — a cyan
/// circle sat across the middle of whichever tile was selected, cutting the
/// square artwork in half and reading as part of the icon rather than as
/// selection. Selection is already said clearly by scale, saturation,
/// brightness, glass intensity and bloom; it does not need a shape drawn over
/// the top of it, and certainly not one that disagrees with the tile's own
/// geometry.
@MainActor
struct PortalLaunchOverlay: View {
    /// 0...1
    let progress: Double
    let tileSize: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: tileSize * HoloTheme.tileCornerRatio, style: .continuous)
            .fill(Color.white)
            .frame(width: tileSize, height: tileSize)
            .blur(radius: tileSize * 0.10)
            .opacity(flashOpacity)
            .blendMode(.plusLighter)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// Rises quickly, then falls away. Zero at rest, so nothing of this is
    /// visible until a launch actually starts.
    private var flashOpacity: Double {
        let peak = 0.45
        if progress <= 0 { return 0 }
        if progress <= peak {
            return (progress / peak) * 0.42
        }
        return max(0, (1 - (progress - peak) / (1 - peak))) * 0.42
    }
}

#Preview("Portal") {
    ZStack {
        HoloBackgroundView()
        PortalLaunchOverlay(progress: 0.45, tileSize: 240)
    }
    .environment(HoloMotion())
}
