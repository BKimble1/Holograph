import Foundation
import SwiftUI

/// Original, programmatically drawn artwork for the bundled demo apps.
///
/// Everything here is vector geometry authored for this project — no third
/// party icons, no Apple marks. Rendering the shapes rather than shipping
/// bitmaps keeps them crisp and keeps the repository free of binary blobs.
enum DemoIconArtwork: String, CaseIterable, Sendable {
    case equipmentTag
    case waterDroplet
    case wallScanner
    case goldCore
    case compass

    @MainActor
    @ViewBuilder
    var view: some View {
        switch self {
        case .equipmentTag: EquipmentTagArtwork()
        case .waterDroplet: WaterDropletArtwork()
        case .wallScanner: WallScannerArtwork()
        case .goldCore: GoldCoreArtwork()
        case .compass: CompassArtwork()
        }
    }
}

// MARK: - Geometry helpers

private extension CGRect {
    /// Maps a unit point (0...1) into this rect.
    func unit(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: minX + width * x, y: minY + height * y)
    }

    func length(_ value: CGFloat) -> CGFloat { min(width, height) * value }
}

// MARK: - Equipment tag

private struct TagShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let body = CGRect(
            x: rect.minX + rect.width * 0.275,
            y: rect.minY + rect.height * 0.145,
            width: rect.width * 0.45,
            height: rect.height * 0.71
        )
        path.addRoundedRect(in: body, cornerSize: CGSize(width: rect.length(0.085), height: rect.length(0.085)), style: .continuous)
        let holeRadius = rect.length(0.052)
        let holeCentre = rect.unit(0.5, 0.285)
        path.addEllipse(in: CGRect(
            x: holeCentre.x - holeRadius,
            y: holeCentre.y - holeRadius,
            width: holeRadius * 2,
            height: holeRadius * 2
        ))
        return path
    }
}

private struct CheckmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: rect.unit(0.375, 0.605))
        path.addLine(to: rect.unit(0.463, 0.700))
        path.addLine(to: rect.unit(0.645, 0.470))
        return path
    }
}

@MainActor
private struct EquipmentTagArtwork: View {
    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack {
                TagShape()
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.96, green: 0.53, blue: 0.13), Color(red: 0.82, green: 0.32, blue: 0.03)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        style: FillStyle(eoFill: true)
                    )
                    .overlay {
                        TagShape()
                            .stroke(Color.white.opacity(0.22), style: StrokeStyle(lineWidth: side * 0.008))
                    }
                CheckmarkShape()
                    .stroke(
                        Color(red: 0.98, green: 0.94, blue: 0.84),
                        style: StrokeStyle(lineWidth: side * 0.085, lineCap: .round, lineJoin: .round)
                    )
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

// MARK: - Water droplet

private struct DropletShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: rect.unit(0.5, 0.135))
        path.addCurve(
            to: rect.unit(0.795, 0.585),
            control1: rect.unit(0.60, 0.28),
            control2: rect.unit(0.795, 0.44)
        )
        path.addCurve(
            to: rect.unit(0.5, 0.875),
            control1: rect.unit(0.795, 0.755),
            control2: rect.unit(0.665, 0.875)
        )
        path.addCurve(
            to: rect.unit(0.205, 0.585),
            control1: rect.unit(0.335, 0.875),
            control2: rect.unit(0.205, 0.755)
        )
        path.addCurve(
            to: rect.unit(0.5, 0.135),
            control1: rect.unit(0.205, 0.44),
            control2: rect.unit(0.40, 0.28)
        )
        path.closeSubpath()
        return path
    }
}

@MainActor
private struct WaterDropletArtwork: View {
    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            DropletShape()
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.36, green: 0.72, blue: 0.98),
                            Color(red: 0.05, green: 0.36, blue: 0.78)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay {
                    DropletShape()
                        .stroke(Color.white.opacity(0.28), lineWidth: side * 0.012)
                }
                .overlay(alignment: .topLeading) {
                    Ellipse()
                        .fill(Color.white.opacity(0.35))
                        .frame(width: side * 0.11, height: side * 0.18)
                        .rotationEffect(.degrees(24))
                        .offset(x: side * 0.335, y: side * 0.42)
                        .blur(radius: side * 0.012)
                }
                .compositingGroup()
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

// MARK: - Wall scanner / radar

private let scannerRingRadii: [CGFloat] = [0.34, 0.235, 0.13]

@MainActor
private struct WallScannerArtwork: View {
    private let cyan = Color(red: 0.35, green: 0.85, blue: 1.0)

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack {
                ForEach(Array(scannerRingRadii.enumerated()), id: \.offset) { index, radius in
                    Circle()
                        .stroke(
                            cyan.opacity(index == 0 ? 0.95 : 0.6),
                            lineWidth: side * (index == 0 ? 0.028 : 0.016)
                        )
                        .frame(width: side * radius * 2, height: side * radius * 2)
                }
                Rectangle()
                    .fill(cyan.opacity(0.35))
                    .frame(width: side * 0.68, height: side * 0.012)
                Rectangle()
                    .fill(cyan.opacity(0.35))
                    .frame(width: side * 0.012, height: side * 0.68)

                SweepWedge()
                    .fill(
                        AngularGradient(
                            gradient: Gradient(colors: [cyan.opacity(0.0), cyan.opacity(0.55)]),
                            center: .center,
                            startAngle: .degrees(-90),
                            endAngle: .degrees(-20)
                        )
                    )
                    .frame(width: side * 0.68, height: side * 0.68)

                Circle()
                    .fill(Color.white)
                    .frame(width: side * 0.055, height: side * 0.055)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

private struct SweepWedge: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        path.move(to: centre)
        path.addArc(
            center: centre,
            radius: rect.width / 2,
            startAngle: .degrees(-90),
            endAngle: .degrees(-20),
            clockwise: false
        )
        path.closeSubpath()
        return path
    }
}

// MARK: - Gold core

private struct RosetteShape: Shape {
    let lobes: Int
    let innerRatio: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2
        let inner = outer * innerRatio
        let steps = lobes * 2
        for step in 0..<steps {
            let angle = (Double(step) / Double(steps)) * 2 * .pi - .pi / 2
            let radius = step.isMultiple(of: 2) ? outer : inner
            let point = CGPoint(
                x: centre.x + CGFloat(cos(angle)) * radius,
                y: centre.y + CGFloat(sin(angle)) * radius
            )
            if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}

@MainActor
private struct GoldCoreArtwork: View {
    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.98, green: 0.85, blue: 0.48),
                                Color(red: 0.72, green: 0.51, blue: 0.09)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: side * 0.70, height: side * 0.70)
                Circle()
                    .stroke(Color(red: 0.42, green: 0.29, blue: 0.04).opacity(0.55), lineWidth: side * 0.022)
                    .frame(width: side * 0.70, height: side * 0.70)
                RosetteShape(lobes: 12, innerRatio: 0.78)
                    .fill(Color(red: 0.99, green: 0.92, blue: 0.68).opacity(0.85))
                    .frame(width: side * 0.46, height: side * 0.46)
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.85, green: 0.63, blue: 0.16),
                                Color(red: 0.58, green: 0.39, blue: 0.05)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: side * 0.24, height: side * 0.24)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

// MARK: - Compass

private struct CompassStarShape: Shape {
    /// `waist` controls how pinched the star is between its points.
    let waist: CGFloat
    let rotationDegrees: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2
        let inner = outer * waist
        let rotation = rotationDegrees * .pi / 180
        for step in 0..<8 {
            let angle = (Double(step) / 8.0) * 2 * .pi - .pi / 2 + rotation
            let radius = step.isMultiple(of: 2) ? outer : inner
            let point = CGPoint(
                x: centre.x + CGFloat(cos(angle)) * radius,
                y: centre.y + CGFloat(sin(angle)) * radius
            )
            if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}

@MainActor
private struct CompassArtwork: View {
    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack {
                CompassStarShape(waist: 0.30, rotationDegrees: 45)
                    .fill(Color(red: 0.24, green: 0.45, blue: 0.62).opacity(0.75))
                    .frame(width: side * 0.66, height: side * 0.66)
                CompassStarShape(waist: 0.20, rotationDegrees: 0)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.78, green: 0.90, blue: 0.99),
                                Color(red: 0.32, green: 0.55, blue: 0.75)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: side * 0.80, height: side * 0.80)
                CompassStarShape(waist: 0.20, rotationDegrees: 0)
                    .stroke(Color.white.opacity(0.35), lineWidth: side * 0.008)
                    .frame(width: side * 0.80, height: side * 0.80)
                Circle()
                    .fill(Color(red: 0.09, green: 0.18, blue: 0.28))
                    .frame(width: side * 0.10, height: side * 0.10)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

#Preview("Demo artwork") {
    ZStack {
        Color(red: 0.01, green: 0.03, blue: 0.06).ignoresSafeArea()
        HStack(spacing: 24) {
            ForEach(DemoIconArtwork.allCases, id: \.self) { artwork in
                artwork.view.frame(width: 120, height: 120)
            }
        }
    }
}
