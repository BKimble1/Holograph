import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Renders an item's own artwork, falling back to a monogram tile when the
/// stored data is missing or no longer decodable.
@MainActor
struct IconArtworkView: View {
    let item: LauncherItem
    let size: CGFloat

    var body: some View {
        Group {
            if let image = Self.image(from: item.iconData) {
                image
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                MonogramArtwork(monogram: item.monogram, size: size)
            }
        }
        .frame(width: size, height: size)
        .clipShape(HoloTheme.tileShape(size: size))
    }

    /// `nil` for corrupt or truncated data — the caller shows a monogram rather
    /// than an empty hole.
    static func image(from data: Data?) -> Image? {
        #if canImport(UIKit)
        guard let data, !data.isEmpty, let uiImage = UIImage(data: data) else { return nil }
        return Image(uiImage: uiImage)
        #else
        return nil
        #endif
    }
}

@MainActor
private struct MonogramArtwork: View {
    let monogram: String
    let size: CGFloat

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.06, green: 0.16, blue: 0.26),
                    Color(red: 0.02, green: 0.07, blue: 0.14)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Text(monogram)
                .font(.system(size: size * 0.34, weight: .medium, design: .rounded))
                .foregroundStyle(HoloTheme.cyanBright.opacity(0.9))
        }
    }
}
