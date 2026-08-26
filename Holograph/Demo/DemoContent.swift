import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// The five bundled demo apps.
///
/// They are deliberately fictional and use an `idlery-demo-` scheme prefix that
/// nothing on the device registers, so the launcher never implies these apps are
/// installed. They exist to show what a populated launcher looks like and to
/// give UI tests something deterministic to drive.
enum DemoContent {
    struct Blueprint: Sendable, Hashable {
        let name: String
        let scheme: String
        let artwork: DemoIconArtwork
    }

    /// Ordered so the equipment tag sits in the middle of the carousel.
    static let blueprints: [Blueprint] = [
        Blueprint(name: "Truebearing", scheme: "idlery-demo-truebearing", artwork: .compass),
        Blueprint(name: "Aquify", scheme: "idlery-demo-aquify", artwork: .waterDroplet),
        Blueprint(name: "Tagfield", scheme: "idlery-demo-tagfield", artwork: .equipmentTag),
        Blueprint(name: "Scanpoint", scheme: "idlery-demo-scanpoint", artwork: .wallScanner),
        Blueprint(name: "Corevault", scheme: "idlery-demo-corevault", artwork: .goldCore)
    ]

    static func launchURL(for blueprint: Blueprint) -> URL? {
        URL(string: "\(blueprint.scheme)://launch")
    }

    /// Drafts without artwork. Nonisolated, so previews, fixtures and tests can
    /// build the demo set without touching a rendering context.
    static func draftsWithoutIcons() -> [LauncherItemDraft] {
        blueprints.compactMap { blueprint in
            guard let url = launchURL(for: blueprint) else { return nil }
            return LauncherItemDraft(
                name: blueprint.name,
                launchURL: url,
                fallbackURL: nil,
                iconData: nil,
                isDemo: true
            )
        }
    }

    /// The full demo set, artwork included. Rasterising the shapes needs the
    /// main actor, which is why this is the isolated variant.
    @MainActor
    static func drafts() -> [LauncherItemDraft] {
        blueprints.compactMap { blueprint in
            guard let url = launchURL(for: blueprint) else { return nil }
            return LauncherItemDraft(
                name: blueprint.name,
                launchURL: url,
                fallbackURL: nil,
                iconData: DemoIconRenderer.shared.pngData(for: blueprint.artwork),
                isDemo: true
            )
        }
    }
}

/// Rasterises the demo artwork once per process so restoring demo apps or
/// seeding a UI test never re-renders the same shapes.
@MainActor
final class DemoIconRenderer {
    static let shared = DemoIconRenderer()

    /// 512pt matches `IconProcessor.maxPixelSize`, so demo and imported icons
    /// carry the same storage cost.
    private let pixelSize: CGFloat = 512
    private var cache: [DemoIconArtwork: Data] = [:]

    func pngData(for artwork: DemoIconArtwork) -> Data? {
        if let cached = cache[artwork] { return cached }
        guard let rendered = render(artwork) else { return nil }
        cache[artwork] = rendered
        return rendered
    }

    private func render(_ artwork: DemoIconArtwork) -> Data? {
        #if canImport(UIKit)
        let renderer = ImageRenderer(
            content: artwork.view
                .frame(width: pixelSize, height: pixelSize)
                .background(Color.clear)
        )
        renderer.scale = 1
        renderer.isOpaque = false
        return renderer.uiImage?.pngData()
        #else
        return nil
        #endif
    }
}

extension LauncherItem {
    /// Fixtures for previews and tests. Icons are omitted so these can be built
    /// off the main actor and without a rendering context.
    static func previewItems() -> [LauncherItem] {
        DemoContent.draftsWithoutIcons().enumerated().compactMap { index, draft in
            LauncherItem(
                kind: draft.kind,
                name: draft.name,
                launchURL: draft.launchURL,
                fallbackURL: draft.fallbackURL,
                sortOrder: index,
                iconData: nil,
                isDemo: true
            )
        }
    }
}
