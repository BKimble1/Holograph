import Foundation
import Observation
import OSLog
import SwiftUI

/// Backs the Add/Edit screen: field state, validation, icon import and the
/// optional App Store prefill.
@MainActor
@Observable
final class AppEditorViewModel {
    enum PrefillState: Equatable {
        case idle
        case looking
        case succeeded(String)
        case failed(String)
    }

    var name: String
    var launchURLText: String
    var fallbackURLText: String
    var appStoreLinkText: String = ""

    private(set) var iconData: Data?
    private(set) var iconError: String?
    private(set) var prefillState: PrefillState = .idle
    private(set) var isImportingIcon = false

    /// Populated once the user has tried to save, so the form is not shouting
    /// at them while they are still typing.
    private(set) var showsValidation = false

    let existingItem: LauncherItem?

    private let iconProcessor: IconProcessor
    private let metadataProvider: AppStoreMetadataProviding
    private let logger = Logger(subsystem: "com.idlery.launcher", category: "editor")

    init(
        item: LauncherItem?,
        iconProcessor: IconProcessor,
        metadataProvider: AppStoreMetadataProviding
    ) {
        self.existingItem = item
        self.name = item?.name ?? ""
        self.launchURLText = item?.launchURL.absoluteString ?? ""
        self.fallbackURLText = item?.fallbackURL?.absoluteString ?? ""
        self.iconData = item?.iconData
        self.iconProcessor = iconProcessor
        self.metadataProvider = metadataProvider
    }

    var isEditing: Bool { existingItem != nil }

    var title: String { isEditing ? "Edit App" : "Add App" }

    // MARK: - Validation

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var nameError: String? {
        guard trimmedName.isEmpty else { return nil }
        return "Give this app a name."
    }

    var launchURLError: String? {
        if case .failure(let error) = LaunchURLValidator.validate(launchURLText) {
            return error.errorDescription
        }
        return nil
    }

    var fallbackURLError: String? {
        if case .failure(let error) = LaunchURLValidator.validateFallback(fallbackURLText) {
            return error.errorDescription
        }
        return nil
    }

    var validatedLaunchURL: URL? {
        if case .success(let url) = LaunchURLValidator.validate(launchURLText) { return url }
        return nil
    }

    var validatedFallbackURL: URL? {
        if case .success(let url) = LaunchURLValidator.validateFallback(fallbackURLText) { return url }
        return nil
    }

    var canSave: Bool {
        nameError == nil && launchURLError == nil && fallbackURLError == nil
    }

    /// Returns a draft when everything checks out, otherwise turns the inline
    /// validation on and returns `nil`.
    func makeDraft() -> LauncherItemDraft? {
        showsValidation = true
        guard canSave, let launchURL = validatedLaunchURL else { return nil }
        return LauncherItemDraft(
            name: trimmedName,
            launchURL: launchURL,
            fallbackURL: validatedFallbackURL,
            iconData: iconData,
            // Editing a demo entry makes it the user's own.
            isDemo: false
        )
    }

    /// A stand-in item used to preview the holographic treatment live.
    var previewItem: LauncherItem {
        LauncherItem(
            id: existingItem?.id ?? UUID(),
            name: trimmedName.isEmpty ? "New App" : trimmedName,
            launchURL: validatedLaunchURL ?? URL(string: "idlery-launcher://preview") ?? URL(fileURLWithPath: "/"),
            iconData: iconData
        )
    }

    // MARK: - Icon import

    func importIcon(from data: Data) async {
        isImportingIcon = true
        iconError = nil
        defer { isImportingIcon = false }
        do {
            let processed = try await iconProcessor.processInBackground(data)
            iconData = processed.data
        } catch {
            logger.error("Icon import failed: \(error.localizedDescription, privacy: .public)")
            iconError = (error as? LocalizedError)?.errorDescription ?? "That image couldn’t be used."
        }
    }

    func clearIcon() {
        iconData = nil
        iconError = nil
    }

    // MARK: - App Store prefill

    var canLookUpAppStoreLink: Bool {
        AppStoreURLParser.appID(from: appStoreLinkText) != nil
    }

    /// Best-effort convenience. Any failure leaves whatever the user typed
    /// untouched and explains itself in one line.
    func lookUpAppStoreLink() async {
        guard let appID = AppStoreURLParser.appID(from: appStoreLinkText) else {
            prefillState = .failed(AppStoreLookupError.invalidLink.localizedDescription)
            return
        }
        prefillState = .looking
        do {
            let metadata = try await metadataProvider.metadata(
                forAppID: appID,
                countryCode: Locale.current.region?.identifier
            )
            if trimmedName.isEmpty {
                name = metadata.name
            }
            if fallbackURLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                fallbackURLText = "https://apps.apple.com/app/id\(metadata.appID)"
            }
            var note = "Filled in details for \(metadata.name)."
            if iconData == nil, let artworkURL = metadata.artworkURL {
                do {
                    let raw = try await metadataProvider.artworkData(at: artworkURL)
                    let processed = try await iconProcessor.processInBackground(raw)
                    iconData = processed.data
                } catch {
                    note += " The artwork couldn’t be downloaded — choose an icon below."
                }
            }
            note += " The App Store link is only a fallback; set the app’s own launch link above."
            prefillState = .succeeded(note)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            prefillState = .failed(message)
        }
    }
}
