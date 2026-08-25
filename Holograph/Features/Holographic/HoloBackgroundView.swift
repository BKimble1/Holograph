import SwiftUI

/// The deep navy stage the whole launcher stands on: a near-black gradient, one
/// restrained cyan bloom behind the selected app, a faint perspective grid and
/// a sparse drift of particles.
@MainActor
struct HoloBackgroundView: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    HoloTheme.backgroundTop,
                    HoloTheme.backgroundDeep
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            RadialGradient(
                gradient: Gradient(stops: [
                    .init(color: HoloTheme.cyan.opacity(0.20), location: 0.0),
                    .init(color: HoloTheme.cyan.opacity(0.07), location: 0.45),
                    .init(color: .clear, location: 1.0)
                ]),
                center: .center,
                startRadius: 0,
                endRadius: 520
            )
            .blendMode(.plusLighter)

            PerspectiveGrid()
                .opacity(0.5)

            ParticleField()

            // Vignette keeps attention in the middle of the stage.
            RadialGradient(
                gradient: Gradient(stops: [
                    .init(color: .clear, location: 0.45),
                    .init(color: HoloTheme.backgroundDeep.opacity(0.85), location: 1.0)
                ]),
                center: .center,
                startRadius: 0,
                endRadius: 900
            )
        }
        .background(HoloTheme.backgroundDeep)
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// A static grid with a shallow vanishing point. Static on purpose: it reads as
/// depth without costing a frame of animation.
@MainActor
private struct PerspectiveGrid: View {
    var body: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            let horizon = size.height * 0.52
            let lineColour = GraphicsContext.Shading.color(HoloTheme.cyan.opacity(0.075))

            // Horizontal lines, tightening towards the horizon.
            var path = Path()
            for step in 1...9 {
                let t = Double(step) / 9.0
                let eased = pow(t, 2.1)
                let y = horizon + eased * (size.height - horizon)
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(path, with: lineColour, lineWidth: 1)

            // Verticals converging on the vanishing point.
            var converging = Path()
            let vanishing = CGPoint(x: size.width / 2, y: horizon)
            for step in -7...7 where step != 0 {
                let x = size.width / 2 + CGFloat(step) * size.width * 0.14
                converging.move(to: CGPoint(x: x, y: size.height))
                converging.addLine(to: vanishing)
            }
            context.stroke(converging, with: lineColour, lineWidth: 1)
        }
        .blendMode(.plusLighter)
        .allowsHitTesting(false)
    }
}

/// Sparse motes drifting upwards. Positions come from a fixed seed so the field
/// looks identical every launch, which keeps UI-test snapshots stable.
@MainActor
private struct ParticleField: View {
    @Environment(HoloMotion.self) private var motion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: motion.timelinePaused)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            Canvas(rendersAsynchronously: false) { context, size in
                for mote in particleMotes {
                    let drift = CGFloat(time) * mote.speed
                    var y = mote.y - drift
                    y = y - floor(y)
                    let point = CGPoint(x: mote.x * size.width, y: y * size.height)
                    let rect = CGRect(
                        x: point.x - mote.radius,
                        y: point.y - mote.radius,
                        width: mote.radius * 2,
                        height: mote.radius * 2
                    )
                    context.fill(
                        Path(ellipseIn: rect),
                        with: .color(HoloTheme.cyanBright.opacity(mote.opacity))
                    )
                }
            }
        }
        .blendMode(.plusLighter)
        .allowsHitTesting(false)
    }
}

/// A drifting mote of light.
struct ParticleMote: Sendable {
    let x: CGFloat
    let y: CGFloat
    let radius: CGFloat
    let speed: CGFloat
    let opacity: Double
}

/// Fixed particle layout, computed once. Deterministic so the field looks the
/// same on every launch and in every test run.
let particleMotes: [ParticleMote] = {
    var generator = SplitMix64(seed: 0x1D1E_0000_C0FF_EE01)
    return (0..<44).map { _ in
        ParticleMote(
            x: CGFloat(generator.nextUnitDouble()),
            y: CGFloat(generator.nextUnitDouble()),
            radius: 0.6 + CGFloat(generator.nextUnitDouble()) * 1.6,
            speed: 0.004 + CGFloat(generator.nextUnitDouble()) * 0.014,
            opacity: 0.12 + generator.nextUnitDouble() * 0.32
        )
    }
}()

/// A tiny deterministic PRNG so particle layout never depends on `Random`'s
/// global state — the field is identical on every launch and in every test run.
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A value in 0..<1.
    mutating func nextUnitDouble() -> Double {
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }
}

#Preview("Backdrop") {
    HoloBackgroundView()
        .environment(HoloMotion())
}
