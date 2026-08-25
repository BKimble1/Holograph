import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A normalised, storage-ready icon.
struct ProcessedIcon: Sendable, Equatable {
    let data: Data
    /// Width and height in pixels (icons are always square once processed).
    let pixelSize: Int
}

enum IconProcessingError: LocalizedError, Equatable {
    case emptyData
    case unreadableImage
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .emptyData:
            return "That file was empty."
        case .unreadableImage:
            return "That file isn’t an image the launcher can read."
        case .encodingFailed:
            return "The icon couldn’t be prepared for storage."
        }
    }
}

/// Downscales, centre-crops and re-encodes imported artwork.
///
/// Pure ImageIO — `Data` in, `Data` out, no UIKit — so it is `Sendable` and can
/// run off the main actor without smuggling non-sendable image objects across
/// isolation boundaries. Keeping a hard pixel ceiling means importing a 48
/// megapixel photograph never lands a 48 megapixel blob in the store.
struct IconProcessor: Sendable {
    /// Longest edge kept after processing. 512pt covers a full-bleed iPad icon
    /// at 2x with room to spare.
    let maxPixelSize: Int

    init(maxPixelSize: Int = 512) {
        self.maxPixelSize = max(32, maxPixelSize)
    }

    func process(_ data: Data) throws -> ProcessedIcon {
        guard !data.isEmpty else { throw IconProcessingError.emptyData }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0
        else { throw IconProcessingError.unreadableImage }

        // ImageIO scales by the longest edge, so ask for a thumbnail large
        // enough that the square we crop out of it still meets the ceiling.
        // Scaling first would shrink a 4:3 photo's square to three quarters of
        // the limit for no reason.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailEdge(for: source)
        ]
        guard let scaled = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw IconProcessingError.unreadableImage
        }

        let squared = try centreCropToSquare(scaled)
        let encoded = try encodePNG(squared)
        return ProcessedIcon(data: encoded, pixelSize: squared.width)
    }

    /// The longest edge to request so that the centre square comes out at the
    /// ceiling. Falls back to the ceiling itself when the source will not say
    /// how big it is.
    private func thumbnailEdge(for source: CGImageSource) -> Int {
        guard
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int,
            width > 0, height > 0
        else { return maxPixelSize }

        let shortest = min(width, height)
        let longest = max(width, height)
        guard shortest > maxPixelSize else { return longest }
        return Int((Double(longest) / Double(shortest) * Double(maxPixelSize)).rounded(.up))
    }

    private func centreCropToSquare(_ image: CGImage) throws -> CGImage {
        let side = min(image.width, image.height)
        guard side > 0 else { throw IconProcessingError.unreadableImage }
        guard image.width != image.height else { return image }
        let rect = CGRect(
            x: (image.width - side) / 2,
            y: (image.height - side) / 2,
            width: side,
            height: side
        )
        guard let cropped = image.cropping(to: rect) else { throw IconProcessingError.unreadableImage }
        return cropped
    }

    private func encodePNG(_ image: CGImage) throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { throw IconProcessingError.encodingFailed }

        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw IconProcessingError.encodingFailed }
        let data = output as Data
        guard !data.isEmpty else { throw IconProcessingError.encodingFailed }
        return data
    }
}

extension IconProcessor {
    /// Convenience for callers on the main actor: hops to a background task so a
    /// large import never stalls the launcher's animation loop.
    func processInBackground(_ data: Data) async throws -> ProcessedIcon {
        let processor = self
        return try await Task.detached(priority: .userInitiated) {
            try processor.process(data)
        }.value
    }
}
