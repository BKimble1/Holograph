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

    /// What is being made. Chosen up front for a new entry, and fixed once an
    /// entry exists — a website is not an app that changed its mind.
    var kind: LauncherItemKind
    var name: String
    var launchURLText: String
    var websiteURLText: String
    var fallbackURLText: String
    var appStoreLinkText: String = ""
    /// Which folder this belongs to, or `nil` for the root wall. Folders
    /// themselves are never inside anything.
    var parentFolderID: UUID?
    /// The folders available to put this in, supplied by whoever presents the
    /// editor so this stays free of the repository.
    var availableFolders: [LauncherItem] = []

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
    private let logger = Logger(subsystem: "com.idlery.holograph", category: "editor")

    init(
        item: LauncherItem?,
        kind: LauncherItemKind = .app,
        availableFolders: [LauncherItem] = [],
        iconProcessor: IconProcessor,
        metadataProvider: AppStoreMetadataProviding
    ) {
        self.existingItem = item
        self.kind = item?.kind ?? kind
        self.name = item?.name ?? ""
        // One field per kind rather than one shared one: the two are validated
        // differently, and a half-typed app scheme should not survive into a
        // website that will not accept it.
        self.launchURLText = item?.kind == .website ? "" : (item?.launchURL?.absoluteString ?? "")
        self.websiteURLText = item?.kind == .website ? (item?.launchURL?.absoluteString ?? "") : ""
        self.fallbackURLText = item?.fallbackURL?.absoluteString ?? ""
        self.parentFolderID = item?.parentFolderID
        self.availableFolders = availableFolders
        self.iconData = item?.iconData
        self.iconProcessor = iconProcessor
        self.metadataProvider = metadataProvider
    }

    var isEditing: Bool { existingItem != nil }

    /// The kind cannot change under an existing entry: its stored URL was
    /// validated as one thing, and quietly reinterpreting it as another is how
    /// a launcher ends up with a tile that opens nothing.
    var canChooseKind: Bool { !isEditing && kind != .folder }

    var title: String {
        switch (isEditing, kind) {
        case (true, .app): return "Edit App"
        case (true, .website): return "Edit Website"
        case (true, .folder): return "Edit Folder"
        case (false, .folder): return "New Folder"
        case (false, _): return "Add to Holograph"
        }
    }

    // MARK: - Validation

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var nameError: String? {
        guard trimmedName.isEmpty else { return nil }
        switch kind {
        case .app: return "Give this app a name."
        case .website: return "Give this website a name."
        case .folder: return "Give this folder a name."
        }
    }

    var launchURLError: String? {
        guard kind == .app else { return nil }
        if case .failure(let error) = LaunchURLValidator.validate(launchURLText) {
            return error.errorDescription
        }
        return nil
    }

    var websiteURLError: String? {
        guard kind == .website else { return nil }
        if case .failure(let error) = WebsiteURLValidator.validate(websiteURLText) {
            return error.errorDescription
        }
        return nil
    }

    var validatedWebsiteURL: URL? {
        if case .success(let url) = WebsiteURLValidator.validate(websiteURLText) { return url }
        return nil
    }

    var fallbackURLError: String? {
        guard kind == .app else { return nil }
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
        nameError == nil && launchURLError == nil && websiteURLError == nil && fallbackURLError == nil
    }

    /// Where this entry will actually send the user, or `nil` for a folder.
    var destinationURL: URL? {
        switch kind {
        case .app: return validatedLaunchURL
        case .website: return validatedWebsiteURL
        case .folder: return nil
        }
    }

    /// Returns a draft when everything checks out, otherwise turns the inline
    /// validation on and returns `nil`.
    func makeDraft() -> LauncherItemDraft? {
        showsValidation = true
        guard canSave else { return nil }
        if kind != .folder, destinationURL == nil { return nil }
        return LauncherItemDraft(
            kind: kind,
            name: trimmedName,
            launchURL: destinationURL,
            fallbackURL: kind == .app ? validatedFallbackURL : nil,
            parentFolderID: kind == .folder ? nil : parentFolderID,
            iconData: iconData,
            // Editing a demo entry makes it the user's own.
            isDemo: false
        )
    }

    /// A stand-in item used to preview the holographic treatment live.
    var previewItem: LauncherItem {
        LauncherItem(
            id: existingItem?.id ?? UUID(),
            kind: kind,
            name: trimmedName.isEmpty ? placeholderName : trimmedName,
            launchURL: destinationURL,
            iconData: iconData
        )
    }

    private var placeholderName: String {
        switch kind {
        case .app: return "New App"
        case .website: return "New Website"
        case .folder: return "New Folder"
        }
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

    /// Only apps come from the App Store.
    var showsAppStorePrefill: Bool { kind == .app }

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
