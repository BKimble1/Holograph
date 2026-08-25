import SwiftUI

/// Builds a fully wired launcher backed by an in-memory store.
///
/// Used by the SwiftUI previews in this target. It is intentionally not
/// compiled out of release builds: `#Preview` bodies are, and keeping the host
/// alongside them avoids a configuration-dependent build break for the sake of
/// a few hundred bytes.
@MainActor
struct LauncherPreviewHost: View {
    @State private var model: LauncherViewModel
    @State private var motion: HoloMotion
    @State private var services: AppServices

    init(items: [LauncherItem] = LauncherItem.previewItems(), launchSucceeds: Bool = true) {
        let repository = InMemoryLauncherRepository(items: items)
        let launcher = StubAppLauncher(outcome: launchSucceeds)
        let feedback = SilentFeedback()
        let selectionStore = InMemorySelectionStore()
        let motion = HoloMotion()

        let model = LauncherViewModel(
            repository: repository,
            launcher: launcher,
            feedback: feedback,
            selectionStore: selectionStore,
            motion: motion
        )
        model.load()

        _model = State(initialValue: model)
        _motion = State(initialValue: motion)
        _services = State(
            initialValue: AppServices(
                repository: repository,
                launcher: launcher,
                feedback: feedback,
                selectionStore: selectionStore,
                metadataProvider: PreviewMetadataProvider()
            )
        )
    }

    var body: some View {
        LauncherScreen()
            .environment(model)
            .environment(motion)
            .environment(services)
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

#Preview("Settings") {
    LauncherPreviewHost()
}
