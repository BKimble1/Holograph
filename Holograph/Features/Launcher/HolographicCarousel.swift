import SwiftUI

/// The carousel stage's own coordinate space.
///
/// File scope rather than a member, because `visualEffect`'s closure runs off
/// the main actor and could not read a constant belonging to a `@MainActor`
/// view.
private let holoCarouselStageSpace = "holograph.carousel.stage"

/// The horizontally scrolling wall of holographic tiles.
///
/// Built on the iOS 17 scrolling APIs — `scrollTargetBehavior(.viewAligned)`
/// plus `scrollPosition(id:)` — so snapping, rubber banding, trackpad scrolling
/// and momentum all come from the system and feel native. Depth, dimming and
/// tilt are layered on with `visualEffect`, which reads live scroll geometry
/// every frame without pushing state back into the view tree.
@MainActor
struct HolographicCarousel: View {
    let items: [LauncherItem]
    @Binding var selectedID: UUID?
    let tileSize: CGFloat
    let launchProgress: Double
    let onActivate: (LauncherItem) -> Void

    @Environment(HoloMotion.self) private var motion

    /// Gap between tile slots. Slots stay a constant width; neighbours shrink
    /// visually, which is what opens up the space seen in the design.
    private var spacing: CGFloat { tileSize * 0.16 }

    var body: some View {
        GeometryReader { stage in
            let containerWidth = stage.size.width
            let sideInset = max(0, (containerWidth - tileSize) / 2)

            ScrollViewReader { scroller in
                ScrollView(.horizontal) {
                    LazyHStack(spacing: spacing) {
                        ForEach(items) { item in
                            tile(for: item, containerWidth: containerWidth)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.viewAligned)
                .scrollPosition(id: $selectedID, anchor: .center)
                .scrollIndicators(.hidden)
                // A scroll view clips to its bounds, and the selected tile's
                // halo is a shadow half a tile wide — far more than the stage
                // leaves around it. So the glow was being sliced off on a
                // straight line above and below the wall, which is the one
                // thing a glow must never do. The tiles are already faded by
                // distance, so nothing else needs the clip.
                .scrollClipDisabled()
                .contentMargins(.horizontal, sideInset, for: .scrollContent)
                // `scrollPosition` alone does not always land on the selected
                // tile the first time the row is laid out — the lazy stack has
                // not built it yet. Re-assert it once the row exists, and again
                // whenever the contents change underneath us.
                .task(id: items.map(\.id)) {
                    guard let selectedID else { return }
                    await Task.yield()
                    scroller.scrollTo(selectedID, anchor: .center)
                }
            }
        }
        .coordinateSpace(.named(holoCarouselStageSpace))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.carousel)
        .accessibilityLabel("App carousel")
    }

    private func tile(for item: LauncherItem, containerWidth: CGFloat) -> some View {
        // Everything the visual effect needs is captured as a plain value so the
        // closure never reaches back into view state.
        let isSelected = item.id == selectedID
        let slotWidth = tileSize + spacing
        let usesDepth = motion.appliesDepthEffects
        let size = tileSize

        return HolographicIconView(
            item: item,
            size: size,
            intensity: isSelected ? 1 : 0.28,
            launchProgress: isSelected ? launchProgress : 0
        )
        .saturation(isSelected ? 1 : 0.24)
        .brightness(isSelected ? 0 : -0.05)
        .overlay {
            if isSelected {
                PortalLaunchOverlay(progress: launchProgress, tileSize: size)
            }
        }
        .animation(motion.transition, value: isSelected)
        .frame(width: size, height: size)
        .visualEffect { content, geometry in
            let offset = HolographicCarousel.normalisedOffset(
                midX: geometry.frame(in: .named(holoCarouselStageSpace)).midX,
                containerWidth: containerWidth,
                slotWidth: slotWidth
            )
            return content
                .scaleEffect(CGFloat(HolographicCarousel.scale(forOffset: offset, usesDepth: usesDepth)))
                .opacity(HolographicCarousel.opacity(forOffset: offset))
                .rotation3DEffect(
                    .degrees(usesDepth ? HolographicCarousel.tiltDegrees(forOffset: offset) : 0),
                    axis: (x: 0, y: 1, z: 0),
                    anchor: .center,
                    anchorZ: 0,
                    perspective: 0.55
                )
                .offset(
                    x: usesDepth
                        ? HolographicCarousel.parallax(forOffset: offset, slotWidth: slotWidth)
                        : 0
                )
        }
        .contentShape(Rectangle())
        .onTapGesture { onActivate(item) }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier(AccessibilityID.carouselItem(item.name))
        .accessibilityLabel(item.name)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityHint(isSelected ? "Opens \(item.name)." : "Brings \(item.name) to the centre.")
        .accessibilityAction(named: isSelected ? "Open" : "Bring to centre") { onActivate(item) }
    }
}

// MARK: - Depth maths
//
// Pure functions of "how many slots away from the centre is this tile", so the
// curve can be reasoned about and unit tested without a running scroll view.

extension HolographicCarousel {
    /// Distance from the centre of the container measured in slots: 0 is dead
    /// centre, ±1 is the immediate neighbour.
    nonisolated static func normalisedOffset(midX: CGFloat, containerWidth: CGFloat, slotWidth: CGFloat) -> Double {
        guard slotWidth > 0 else { return 0 }
        return Double((midX - containerWidth / 2) / slotWidth)
    }

    nonisolated static func scale(forOffset offset: Double, usesDepth: Bool) -> Double {
        let distance = min(abs(offset), 3)
        guard usesDepth else {
            // Reduce Motion: one gentle step down instead of continuous
            // perspective scaling.
            return distance < 0.5 ? 1.0 : 0.72
        }
        if distance <= 1 {
            return 1 - distance * (1 - HoloTheme.neighbourScale)
        }
        let beyond = min(distance - 1, 2) / 2
        return HoloTheme.neighbourScale - beyond * (HoloTheme.neighbourScale - HoloTheme.outerScale)
    }

    nonisolated static func opacity(forOffset offset: Double) -> Double {
        let distance = min(abs(offset), 3.2)
        if distance <= 1 {
            return 1 - distance * 0.36
        }
        let beyond = min(distance - 1, 2.2) / 2.2
        return max(0.06, 0.64 - beyond * 0.58)
    }

    nonisolated static func tiltDegrees(forOffset offset: Double) -> Double {
        let clamped = max(-2.5, min(2.5, offset))
        return -clamped * 13
    }

    /// Pulls distant tiles slightly towards the centre so the row reads as a
    /// shallow arc rather than a flat strip.
    nonisolated static func parallax(forOffset offset: Double, slotWidth: CGFloat) -> CGFloat {
        let clamped = max(-3.0, min(3.0, offset))
        let pull = -clamped * abs(clamped) * 0.035
        return CGFloat(pull) * slotWidth
    }
}
