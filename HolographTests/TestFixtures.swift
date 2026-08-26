import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import Holograph

enum TestFixtures {
    static func draft(
        name: String,
        scheme: String = "idlery-test",
        fallback: String? = nil,
        iconData: Data? = nil,
        isDemo: Bool = false
    ) -> LauncherItemDraft {
        LauncherItemDraft(
            kind: .app,
            name: name,
            launchURL: URL(string: "\(scheme)://launch") ?? placeholderURL,
            fallbackURL: fallback.flatMap(URL.init(string:)),
            iconData: iconData,
            isDemo: isDemo
        )
    }

    static func item(
        name: String,
        sortOrder: Int = 0,
        fallback: String? = nil,
        isDemo: Bool = false
    ) -> LauncherItem {
        LauncherItem(
            name: name,
            launchURL: URL(string: "idlery-test-\(slug(name))://launch") ?? placeholderURL,
            fallbackURL: fallback.flatMap(URL.init(string:)),
            sortOrder: sortOrder,
            isDemo: isDemo
        )
    }

    /// Lower-cased and hyphenated so generated URLs are always well formed.
    static func slug(_ name: String) -> String {
        name.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .joined(separator: "-")
    }

    static var placeholderURL: URL {
        URL(string: "idlery-test://placeholder") ?? URL(fileURLWithPath: "/")
    }

    /// A real PNG of the requested pixel dimensions, built with Core Graphics so
    /// it works on any actor and decodes through the same ImageIO path the app
    /// uses.
    static func pngData(width: Int, height: Int) -> Data {
        guard width > 0, height > 0 else { return Data() }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return Data() }

        context.setFillColor(red: 0.95, green: 0.5, blue: 0.1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width / 3, height: height / 3))

        guard let image = context.makeImage() else { return Data() }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { return Data() }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return Data() }
        return output as Data
    }
}

/// Answers lookups from a fixed payload so tests never touch the network.
struct StubMetadataProvider: AppStoreMetadataProviding {
    var metadata: AppStoreMetadata?
    var metadataError: AppStoreLookupError?
    var artwork: Data?

    func metadata(forAppID appID: Int, countryCode: String?) async throws -> AppStoreMetadata {
        if let metadataError { throw metadataError }
        guard let metadata else { throw AppStoreLookupError.notFound }
        return metadata
    }

    func artworkData(at url: URL) async throws -> Data {
        guard let artwork else { throw AppStoreLookupError.artworkUnavailable }
        return artwork
    }
}


/// The view model, wired to stubs, for the suites that exercise behaviour
/// rather than storage.
///
/// Shared rather than rebuilt in each file: several suites now need the same
/// arrangement, and three copies of it would drift.
@MainActor
final class LauncherHarness {
    let model: LauncherViewModel
    let repository: InMemoryLauncherRepository
    let launcher: StubAppLauncher
    let feedback: SilentFeedback
    let sound: SilentSound
    let selectionStore: InMemorySelectionStore
    let motion: HoloMotion

    init(items: [LauncherItem] = [], launchSucceeds: Bool = true) {
        repository = InMemoryLauncherRepository(items: items)
        launcher = StubAppLauncher(outcome: launchSucceeds)
        feedback = SilentFeedback()
        sound = SilentSound()
        selectionStore = InMemorySelectionStore()
        // Testing mode collapses the launch ceremony to a single millisecond.
        motion = HoloMotion(isDisabledForTesting: true)
        model = LauncherViewModel(
            repository: repository,
            launcher: launcher,
            feedback: feedback,
            sound: sound,
            selectionStore: selectionStore,
            motion: motion
        )
    }
}
