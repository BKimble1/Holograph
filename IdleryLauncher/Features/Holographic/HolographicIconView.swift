import SwiftUI

/// The holographic treatment applied on top of an app's own artwork.
///
/// The rule that governs every layer here: *add light, never replace colour*.
/// Overlays use `.screen` and `.plusLighter` at low opacity so an orange tag
/// still reads as orange, just lit from inside a pane of cyan glass.
@MainActor
struct HolographicIconView: View {
    let item: LauncherItem
    let size: CGFloat
    /// 0 for a distant neighbour, 1 for the centred app. Drives how much of the
    /// treatment is applied so side icons stay quiet.
    let intensity: Double
    /// 0...1 while the launch ceremony plays.
    var launchProgress: Double = 0

    @Environment(HoloMotion.self) private var motion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: motion.timelinePaused)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            tile(time: time)
        }
        .frame(width: size, height: size)
    }

    private func tile(time: TimeInterval) -> some View {
        let shape = HoloTheme.tileShape(size: size)
        let glassOpacity = 0.30 * intensity
        let boost = 1 + launchProgress * 0.55

        return ZStack {
            // 1. Bloom behind the tile.
            shape
                .fill(HoloTheme.cyan)
                .frame(width: size * 1.02, height: size * 1.02)
                .blur(radius: size * 0.16)
                .opacity((0.10 + 0.34 * intensity) * boost)

            // 2. The app's own artwork, untouched.
            IconArtworkView(item: item, size: size)

            // 3. A pane of cyan glass over it.
            shape
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: HoloTheme.cyanBright.opacity(0.55), location: 0.0),
                            .init(color: HoloTheme.cyan.opacity(0.10), location: 0.42),
                            .init(color: .clear, location: 0.72),
                            .init(color: HoloTheme.cyan.opacity(0.28), location: 1.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .opacity(glassOpacity)
                .blendMode(.screen)

            // 4. Scan lines drifting slowly down the glass.
            ScanLineOverlay(spacing: max(3, size * 0.026), phase: scanPhase(time: time))
                .mask { shape }
                .opacity(0.16 * intensity)
                .blendMode(.plusLighter)

            // 5. A single soft shimmer sweeping diagonally.
            ShimmerBand(progress: shimmerProgress(time: time), size: size)
                .mask { shape }
                .opacity((0.5 + 0.5 * launchProgress) * intensity)
                .blendMode(.plusLighter)

            // 6. The illuminated edge.
            shape
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.85),
                            HoloTheme.cyanBright.opacity(0.75),
                            HoloTheme.cyan.opacity(0.35)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: max(1, size * 0.0075)
                )
                .opacity(0.35 + 0.6 * intensity)

            // 7. An inner hairline that sells the thickness of the glass.
            shape
                .inset(by: size * 0.028)
                .strokeBorder(HoloTheme.cyanBright.opacity(0.22 * intensity), lineWidth: max(0.5, size * 0.003))
        }
        .compositingGroup()
        .shadow(color: HoloTheme.cyan.opacity(0.55 * intensity * boost), radius: size * 0.16)
        .shadow(color: HoloTheme.cyanBright.opacity(0.22 * intensity), radius: size * 0.04)
    }

    private func scanPhase(time: TimeInterval) -> CGFloat {
        guard motion.runsContinuousEffects else { return 0 }
        return CGFloat(time.truncatingRemainder(dividingBy: 6)) * size * 0.05
    }

    private func shimmerProgress(time: TimeInterval) -> Double {
        guard motion.runsContinuousEffects else { return 0.35 }
        let period = 5.5
        return (time.truncatingRemainder(dividingBy: period)) / period
    }
}

/// Thin horizontal lines, drawn once per frame at 30fps.
@MainActor
struct ScanLineOverlay: View {
    let spacing: CGFloat
    let phase: CGFloat

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            guard spacing > 0.5 else { return }
            var path = Path()
            var y = phase.truncatingRemainder(dividingBy: spacing) - spacing
            let thickness = max(0.5, spacing * 0.22)
            while y < size.height {
                path.addRect(CGRect(x: 0, y: y, width: size.width, height: thickness))
                y += spacing
            }
            context.fill(path, with: .color(.white.opacity(0.55)))
        }
        .allowsHitTesting(false)
    }
}

/// A soft diagonal band of light that travels across the tile.
@MainActor
struct ShimmerBand: View {
    /// 0...1
    let progress: Double
    let size: CGFloat

    var body: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0.0),
                .init(color: Color.white.opacity(0.30), location: 0.45),
                .init(color: HoloTheme.cyanBright.opacity(0.22), location: 0.55),
                .init(color: .clear, location: 1.0)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(width: size * 2.2, height: size * 0.34)
        .rotationEffect(.degrees(-24))
        .offset(y: (CGFloat(progress) * 2.4 - 1.2) * size)
        .allowsHitTesting(false)
    }
}

/// The pool of light an icon appears to stand on.
@MainActor
struct HoloPedestalView: View {
    let width: CGFloat
    let intensity: Double

    var body: some View {
        ZStack {
            Ellipse()
                .fill(
                    RadialGradient(
                        gradient: Gradient(stops: [
                            .init(color: HoloTheme.cyanBright.opacity(0.55), location: 0.0),
                            .init(color: HoloTheme.cyan.opacity(0.22), location: 0.45),
                            .init(color: .clear, location: 1.0)
                        ]),
                        center: .center,
                        startRadius: 0,
                        endRadius: width * 0.5
                    )
                )
                .frame(width: width, height: width * 0.17)
                .blur(radius: width * 0.02)

            Ellipse()
                .stroke(HoloTheme.cyanBright.opacity(0.55), lineWidth: 1)
                .frame(width: width * 0.52, height: width * 0.075)
                .blur(radius: 0.6)
        }
        .opacity(intensity)
        .blendMode(.plusLighter)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

#Preview("Holographic tile") {
    ZStack {
        HoloBackgroundView()
        VStack(spacing: 40) {
            HolographicIconView(
                item: LauncherItem.previewItems()[2],
                size: 260,
                intensity: 1
            )
            HolographicIconView(
                item: LauncherItem.previewItems()[1],
                size: 170,
                intensity: 0.35
            )
        }
    }
    .environment(HoloMotion())
}
