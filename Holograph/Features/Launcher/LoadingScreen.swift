import SwiftUI

/// The first thing the app shows: the launcher mark settling onto its pedestal
/// of light, with "powered by idlery" in small print along the bottom.
///
/// It stands on the same backdrop as the launcher, so handing over is a plain
/// cross-fade rather than a change of scene.
@MainActor
struct LoadingScreen: View {
    @Environment(HoloMotion.self) private var motion

    @State private var hasAppeared = false

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let logoSize = min(max(side * 0.36, 168), 420)

            ZStack {
                HoloBackgroundView()

                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    mark(size: logoSize)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                VStack {
                    Spacer(minLength: 0)
                    poweredByIdlery
                        .padding(.bottom, side < 500 ? 20 : 34)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .background(HoloTheme.backgroundDeep)
        .ignoresSafeArea(edges: .top)
        .accessibilityIdentifier(AccessibilityID.loadingScreen)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Holograph is starting")
        .onAppear {
            withAnimation(entrance) { hasAppeared = true }
        }
    }

    // MARK: - Pieces

    private func mark(size: CGFloat) -> some View {
        VStack(spacing: 0) {
            Image("LaunchLogo")
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .shadow(color: HoloTheme.cyan.opacity(0.45), radius: size * 0.10)
                .scaleEffect(scale)
                .opacity(hasAppeared ? 1 : 0)

            HoloPedestalView(width: size * 0.86, intensity: hasAppeared ? 0.9 : 0)
                .frame(height: size * 0.14)
                .padding(.top, -size * 0.22)
        }
        .accessibilityHidden(true)
    }

    private var poweredByIdlery: some View {
        HStack(spacing: 7) {
            Text("powered by")
                .font(.system(size: 12, weight: .regular, design: .rounded))
                .foregroundStyle(HoloTheme.secondaryText.opacity(0.72))

            Image("IdleryWordmark")
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(height: 17)
                .accessibilityHidden(true)
        }
        .opacity(hasAppeared ? 1 : 0)
        .animation(motion.prefersReducedMotion ? .easeInOut(duration: 0.3) : .easeOut(duration: 0.5).delay(0.28), value: hasAppeared)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Powered by Idlery")
        .accessibilityIdentifier(AccessibilityID.poweredByIdlery)
    }

    // MARK: - Motion

    /// Reduce Motion gets a plain fade; everything else gets a short settle.
    private var entrance: Animation {
        motion.prefersReducedMotion
            ? .easeInOut(duration: 0.3)
            : .spring(response: 0.75, dampingFraction: 0.78)
    }

    private var scale: CGFloat {
        guard !motion.prefersReducedMotion else { return 1 }
        return hasAppeared ? 1 : 0.88
    }
}

#Preview("Loading") {
    LoadingScreen()
        .environment(HoloMotion())
}
