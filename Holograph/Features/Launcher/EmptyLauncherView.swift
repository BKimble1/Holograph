import SwiftUI

/// Shown instead of the carousel when nothing has been added yet.
///
/// It keeps the same stage, the same glass and the same glow — one holographic
/// tile that invites the first app. No onboarding flow, no wizard.
@MainActor
struct EmptyLauncherView: View {
    let tileSize: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: max(18, tileSize * 0.14)) {
                ZStack {
                    HoloTheme.tileShape(size: tileSize)
                        .fill(HoloTheme.cyan.opacity(0.14))
                        .frame(width: tileSize, height: tileSize)
                        .blur(radius: tileSize * 0.12)

                    HoloTheme.tileShape(size: tileSize)
                        .fill(
                            LinearGradient(
                                colors: [
                                    HoloTheme.cyan.opacity(0.16),
                                    HoloTheme.cyan.opacity(0.04)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: tileSize, height: tileSize)

                    HoloTheme.tileShape(size: tileSize)
                        .strokeBorder(
                            HoloTheme.cyanBright.opacity(0.55),
                            style: StrokeStyle(lineWidth: max(1, tileSize * 0.007), dash: [tileSize * 0.06, tileSize * 0.045])
                        )
                        .frame(width: tileSize, height: tileSize)

                    Image(systemName: "plus")
                        .font(.system(size: tileSize * 0.28, weight: .thin))
                        .foregroundStyle(HoloTheme.cyanBright)
                        .shadow(color: HoloTheme.cyan.opacity(0.8), radius: tileSize * 0.06)
                }
                .compositingGroup()
                .shadow(color: HoloTheme.cyan.opacity(0.4), radius: tileSize * 0.14)

                HoloPedestalView(width: tileSize * 1.5, intensity: 0.7)
                    .frame(height: tileSize * 0.17)
                    .padding(.top, -tileSize * 0.28)

                VStack(spacing: 8) {
                    Text("Add Your First Tile")
                        .font(.system(size: max(19, min(32, tileSize * 0.14)), weight: .medium, design: .rounded))
                        .foregroundStyle(.white)
                    Text("TAP TO OPEN SETTINGS")
                        .font(.system(size: max(10, min(13, tileSize * 0.055)), weight: .semibold, design: .rounded))
                        .tracking(2.4)
                        .foregroundStyle(HoloTheme.secondaryText.opacity(0.85))
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(AccessibilityID.emptyStatePlaceholder)
        .accessibilityLabel("Add your first app, website or folder")
        .accessibilityHint("Opens Settings so you can add an app to the launcher.")
        .accessibilityAddTraits(.isButton)
    }
}

#Preview("Empty state") {
    ZStack {
        HoloBackgroundView()
        EmptyLauncherView(tileSize: 240) {}
    }
    .environment(HoloMotion())
}
