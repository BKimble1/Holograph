import SwiftUI

/// A fully wired launcher backed by an in-memory store, for the SwiftUI
/// previews in this target.
///
/// Intentionally not compiled out of release builds: `#Preview` bodies are, and
/// keeping the harness beside them avoids a configuration-dependent build break
/// for the sake of a few hundred bytes.
@MainActor
final class PreviewHarness {
    let model: LauncherViewModel
    let motion: HoloMotion
    let services: AppServices

    init(items: [LauncherItem] = LauncherItem.previewItems(), launchSucceeds: Bool = true) {
        let repository = InMemoryLauncherRepository(items: items)
        let launcher = StubAppLauncher(outcome: launchSucceeds)
        let feedback = SilentFeedback()
        let sound = SilentSound()
        let selectionStore = InMemorySelectionStore()
        let motion = HoloMotion()

        let model = LauncherViewModel(
            repository: repository,
            launcher: launcher,
            feedback: feedback,
            sound: sound,
            selectionStore: selectionStore,
            motion: motion
        )
        model.load()

        self.model = model
        self.motion = motion
        self.services = AppServices(
            repository: repository,
            launcher: launcher,
            feedback: feedback,
            sound: sound,
            airGestures: InertAirGestureSource(),
            selectionStore: selectionStore,
            metadataProvider: PreviewMetadataProvider()
        )
    }
}

/// Wraps any preview content in the harness's environment.
@MainActor
struct PreviewHost<Content: View>: View {
    @State private var harness: PreviewHarness
    private let content: (PreviewHarness) -> Content

    init(
        items: [LauncherItem] = LauncherItem.previewItems(),
        launchSucceeds: Bool = true,
        @ViewBuilder content: @escaping (PreviewHarness) -> Content
    ) {
        _harness = State(initialValue: PreviewHarness(items: items, launchSucceeds: launchSucceeds))
        self.content = content
    }

    var body: some View {
        content(harness)
            .environment(harness.model)
            .environment(harness.motion)
            .environment(harness.services)
    }
}

/// The launcher itself.
@MainActor
struct LauncherPreviewHost: View {
    var items: [LauncherItem] = LauncherItem.previewItems()
    var launchSucceeds = true

    var body: some View {
        PreviewHost(items: items, launchSucceeds: launchSucceeds) { _ in
            LauncherScreen()
        }
    }
}

/// The launcher with a sheet already presented over it, so sheet-only modifiers
/// such as `presentationBackground` behave as they do in the app.
@MainActor
struct SheetPreviewHost<Sheet: View>: View {
    @State private var isPresented = true
    private let items: [LauncherItem]
    private let sheet: (PreviewHarness) -> Sheet

    init(
        items: [LauncherItem] = LauncherItem.previewItems(),
        @ViewBuilder sheet: @escaping (PreviewHarness) -> Sheet
    ) {
        self.items = items
        self.sheet = sheet
    }

    var body: some View {
        PreviewHost(items: items) { harness in
            ZStack {
                HoloBackgroundView()
            }
            .sheet(isPresented: $isPresented) {
                sheet(harness)
                    .environment(harness.model)
                    .environment(harness.motion)
                    .environment(harness.services)
            }
        }
    }
}

/// Answers lookups from a canned payload so previews never touch the network.
struct PreviewMetadataProvider: AppStoreMetadataProviding {
    func metadata(forAppID appID: Int, countryCode: String?) async throws -> AppStoreMetadata {
        AppStoreMetadata(appID: appID, name: "Sample App", bundleID: "com.example.sample", artworkURL: nil)
    }

    func artworkData(at url: URL) async throws -> Data {
        throw AppStoreLookupError.artworkUnavailable
    }
}
