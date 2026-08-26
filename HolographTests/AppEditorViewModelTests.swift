import XCTest
@testable import Holograph

@MainActor
final class AppEditorViewModelTests: XCTestCase {
    private func makeEditor(
        item: LauncherItem? = nil,
        metadata: StubMetadataProvider = StubMetadataProvider()
    ) -> AppEditorViewModel {
        AppEditorViewModel(
            item: item,
            iconProcessor: IconProcessor(maxPixelSize: 64),
            metadataProvider: metadata
        )
    }

    func testAddModeStartsEmpty() {
        let editor = makeEditor()

        XCTAssertFalse(editor.isEditing)
        XCTAssertEqual(editor.title, "Add App")
        XCTAssertEqual(editor.name, "")
        XCTAssertNil(editor.iconData)
        XCTAssertFalse(editor.canSave)
    }

    func testEditModePrefillsFromTheItem() {
        let item = TestFixtures.item(name: "Field Notes", fallback: "https://example.com")
        let editor = makeEditor(item: item)

        XCTAssertTrue(editor.isEditing)
        XCTAssertEqual(editor.title, "Edit App")
        XCTAssertEqual(editor.name, "Field Notes")
        XCTAssertEqual(editor.launchURLText, "idlery-test-field-notes://launch")
        XCTAssertEqual(editor.fallbackURLText, "https://example.com")
    }

    func testValidationBlocksSavingUntilTheRequiredFieldsAreGood() {
        let editor = makeEditor()

        XCTAssertNil(editor.makeDraft())
        XCTAssertTrue(editor.showsValidation)
        XCTAssertNotNil(editor.nameError)
        XCTAssertNotNil(editor.launchURLError)

        editor.name = "  OffRent  "
        editor.launchURLText = "idler-offrent://launch"

        let draft = editor.makeDraft()
        XCTAssertEqual(draft?.name, "OffRent")
        XCTAssertEqual(draft?.launchURL?.absoluteString, "idler-offrent://launch")
        XCTAssertNil(draft?.fallbackURL)
    }

    func testAnInvalidFallbackBlocksSaving() {
        let editor = makeEditor()
        editor.name = "OffRent"
        editor.launchURLText = "idler-offrent://launch"
        editor.fallbackURLText = "not a link"

        XCTAssertNil(editor.makeDraft())
        XCTAssertNotNil(editor.fallbackURLError)
    }

    func testSavingClearsTheDemoFlagSoAnEditedDemoBecomesTheUsersOwn() {
        let demo = LauncherItem(
            name: "Tagfield",
            launchURL: TestFixtures.placeholderURL,
            isDemo: true
        )
        let editor = makeEditor(item: demo)
        editor.name = "My Real App"
        editor.launchURLText = "idler-offrent://launch"

        XCTAssertEqual(editor.makeDraft()?.isDemo, false)
    }

    func testPreviewItemAlwaysHasSomethingToShow() {
        let editor = makeEditor()
        XCTAssertEqual(editor.previewItem.name, "New App")

        editor.name = "Turbid"
        XCTAssertEqual(editor.previewItem.name, "Turbid")
    }

    // MARK: - App Store prefill

    func testLookUpIsDisabledUntilTheLinkContainsAnIdentifier() {
        let editor = makeEditor()
        XCTAssertFalse(editor.canLookUpAppStoreLink)

        editor.appStoreLinkText = "https://apps.apple.com/us/app/thing/id1234567890"
        XCTAssertTrue(editor.canLookUpAppStoreLink)
    }

    func testLookUpFillsTheNameAndFallbackButNeverTheLaunchLink() async {
        let editor = makeEditor(
            metadata: StubMetadataProvider(
                metadata: AppStoreMetadata(
                    appID: 1_234_567_890,
                    name: "Field Notes",
                    bundleID: "com.example.fieldnotes",
                    artworkURL: nil
                )
            )
        )
        editor.appStoreLinkText = "https://apps.apple.com/us/app/thing/id1234567890"

        await editor.lookUpAppStoreLink()

        XCTAssertEqual(editor.name, "Field Notes")
        XCTAssertEqual(editor.fallbackURLText, "https://apps.apple.com/app/id1234567890")
        XCTAssertEqual(editor.launchURLText, "", "The App Store link must never become the launch link")
        guard case .succeeded = editor.prefillState else {
            return XCTFail("Expected a successful prefill, got \(editor.prefillState)")
        }
    }

    func testLookUpNeverOverwritesWhatTheUserAlreadyTyped() async {
        let editor = makeEditor(
            metadata: StubMetadataProvider(
                metadata: AppStoreMetadata(appID: 7, name: "Store Name", bundleID: nil, artworkURL: nil)
            )
        )
        editor.name = "My Name"
        editor.fallbackURLText = "https://example.com/mine"
        editor.appStoreLinkText = "id1234567890"

        await editor.lookUpAppStoreLink()

        XCTAssertEqual(editor.name, "My Name")
        XCTAssertEqual(editor.fallbackURLText, "https://example.com/mine")
    }

    func testLookUpFailsGracefullyAndLeavesManualEntryIntact() async {
        let editor = makeEditor(metadata: StubMetadataProvider(metadataError: .notFound))
        editor.name = "Typed By Hand"
        editor.appStoreLinkText = "id1234567890"

        await editor.lookUpAppStoreLink()

        XCTAssertEqual(editor.name, "Typed By Hand")
        guard case .failed(let message) = editor.prefillState else {
            return XCTFail("Expected a failure state, got \(editor.prefillState)")
        }
        XCTAssertFalse(message.isEmpty)
    }

    func testLookUpRejectsALinkWithoutAnIdentifier() async {
        let editor = makeEditor()
        editor.appStoreLinkText = "https://example.com/not-the-app-store"

        await editor.lookUpAppStoreLink()

        guard case .failed = editor.prefillState else {
            return XCTFail("Expected a failure state, got \(editor.prefillState)")
        }
    }

    func testLookUpDownloadsAndProcessesArtworkWhenNoIconIsSet() async {
        let artwork = TestFixtures.pngData(width: 300, height: 300)
        let editor = makeEditor(
            metadata: StubMetadataProvider(
                metadata: AppStoreMetadata(
                    appID: 7,
                    name: "Arty",
                    bundleID: nil,
                    artworkURL: URL(string: "https://example.com/artwork.png")
                ),
                artwork: artwork
            )
        )
        editor.appStoreLinkText = "id1234567890"

        await editor.lookUpAppStoreLink()

        let iconData = editor.iconData
        XCTAssertNotNil(iconData)
        XCTAssertNotEqual(iconData, artwork, "Artwork should be processed, not stored raw")
    }

    // MARK: - Icon import

    func testImportingAnIconShrinksItToTheCeiling() async {
        let editor = makeEditor()

        await editor.importIcon(from: TestFixtures.pngData(width: 1024, height: 1024))

        XCTAssertNotNil(editor.iconData)
        XCTAssertNil(editor.iconError)
        XCTAssertFalse(editor.isImportingIcon)
    }

    func testImportingGarbageReportsAnErrorInsteadOfStoringIt() async {
        let editor = makeEditor()

        await editor.importIcon(from: Data([0x01, 0x02, 0x03]))

        XCTAssertNil(editor.iconData)
        XCTAssertNotNil(editor.iconError)
    }

    func testClearingTheIconRemovesItAndAnyError() async {
        let editor = makeEditor()
        await editor.importIcon(from: TestFixtures.pngData(width: 128, height: 128))
        XCTAssertNotNil(editor.iconData)

        editor.clearIcon()

        XCTAssertNil(editor.iconData)
        XCTAssertNil(editor.iconError)
    }
}
