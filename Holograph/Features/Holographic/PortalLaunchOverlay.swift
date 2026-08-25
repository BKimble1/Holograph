import SwiftUI

/// The short "portal" flourish played between tapping the centred app and the
/// system switching apps: the tile's own glow intensifies (handled by
/// `HolographicIconView`) while a ring expands out of it and a soft flash lifts
/// the whole stage.
@MainActor
struct PortalLaunchOverlay: View {
    /// 0...1
    let progress: Double
    let tileSize: CGFloat

    @Environment(HoloMotion.self) private var motion

    var body: some View {
        ZStack {
            if motion.appliesDepthEffects {
                ring
            }
            RoundedRectangle(cornerRadius: tileSize * HoloTheme.tileCornerRatio, style: .continuous)
                .fill(Color.white)
                .frame(width: tileSize, height: tileSize)
                .blur(radius: tileSize * 0.10)
                .opacity(flashOpacity)
                .blendMode(.plusLighter)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var ring: some View {
        Circle()
            .stroke(
                HoloTheme.cyanBright.opacity(max(0, 1 - progress) * 0.75),
                lineWidth: max(1, tileSize * 0.02 * (1 - progress))
            )
            .frame(
                width: tileSize * (0.7 + progress * 1.9),
                height: tileSize * (0.7 + progress * 1.9)
            )
            .blur(radius: tileSize * 0.008)
    }

    /// Rises quickly, then falls away as the ring expands.
    private var flashOpacity: Double {
        let peak = 0.45
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
