import SwiftUI

/// Minimal dots along the bottom of the stage.
///
/// Above a dozen apps a full row of dots stops being minimal, so it collapses
/// into a slim progress rail that conveys the same thing.
@MainActor
struct PageIndicator: View {
    let count: Int
    let selectedIndex: Int?

    private let dotLimit = 12

    var body: some View {
        Group {
            if count > 1 && count <= dotLimit {
                dots
            } else if count > dotLimit {
                rail
            }
        }
        .accessibilityIdentifier(AccessibilityID.pageIndicator)
        .accessibilityHidden(true)
    }

    private var dots: some View {
        HStack(spacing: 12) {
            ForEach(0..<count, id: \.self) { index in
                Circle()
                    .fill(index == selectedIndex ? HoloTheme.cyanBright : Color.white.opacity(0.22))
                    .frame(
                        width: index == selectedIndex ? 8 : 6,
                        height: index == selectedIndex ? 8 : 6
                    )
                    .shadow(
                        color: index == selectedIndex ? HoloTheme.cyan.opacity(0.9) : .clear,
                        radius: 5
                    )
            }
        }
        .animation(.easeInOut(duration: 0.2), value: selectedIndex)
    }

    private var rail: some View {
        GeometryReader { proxy in
            let progress = count > 1 ? Double(selectedIndex ?? 0) / Double(count - 1) : 0
            let knobWidth = max(28, proxy.size.width / CGFloat(count))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule()
                    .fill(HoloTheme.cyanBright)
                    .frame(width: knobWidth)
                    .offset(x: CGFloat(progress) * (proxy.size.width - knobWidth))
                    .shadow(color: HoloTheme.cyan.opacity(0.8), radius: 5)
            }
        }
        .frame(width: 180, height: 3)
        .animation(.easeInOut(duration: 0.2), value: selectedIndex)
    }
}
