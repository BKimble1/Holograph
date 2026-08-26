import Foundation
import SwiftData

/// The persisted representation of a tile.
///
/// The type is still called `StoredLauncherApp` although it now holds websites
/// and folders too, and that is deliberate: SwiftData derives the entity name
/// from the class name, so renaming it would orphan every record already on
/// somebody's iPad. The name is a historical fact about the store, not a
/// statement about what it holds.
///
/// URLs are stored as strings: a value that somehow becomes unparseable should
/// not make the whole store unreadable, and mapping to `LauncherItem` is where
/// we decide what to do about it.
@Model
final class StoredLauncherApp {
    /// Assigned once at insert and never reused, so no uniqueness constraint is
    /// needed — and the schema stays as plain as SwiftData allows.
    var identifier: UUID
    var name: String
    /// Empty for a folder, which goes nowhere.
    ///
    /// Left non-optional on purpose. Turning an existing required attribute
    /// optional is a schema change with real migration risk, and an empty
    /// string carries the same meaning with none.
    var launchURLString: String
    var fallbackURLString: String?
    var sortOrder: Int
    /// PNG data capped at `IconProcessor.maxPixelSize`; see `IconProcessor`.
    var iconData: Data?
    var isDemo: Bool
    var createdAt: Date
    var modifiedAt: Date

    // MARK: - Added when the launcher grew past apps
    //
    // Both are optional so SwiftData migrates every existing store on its own,
    // with no versioned plan and nothing to go wrong. A record written before
    // this change has `nil` for both, which reads back as exactly what it was:
    // an app on the root wall.

    /// The raw value of `LauncherItemKind`. `nil` means a record from before
    /// there was anything but apps.
    var kindRaw: String?
    /// The folder this belongs to, or `nil` for the root wall.
    var parentFolderID: UUID?

    init(
        identifier: UUID = UUID(),
        kind: LauncherItemKind = .app,
        name: String,
        launchURLString: String,
        fallbackURLString: String? = nil,
        parentFolderID: UUID? = nil,
        sortOrder: Int,
        iconData: Data? = nil,
        isDemo: Bool = false,
        createdAt: Date = .now,
        modifiedAt: Date = .now
    ) {
        self.identifier = identifier
        self.kindRaw = kind.rawValue
        self.name = name
        self.launchURLString = launchURLString
        self.fallbackURLString = fallbackURLString
        self.parentFolderID = parentFolderID
        self.sortOrder = sortOrder
        self.iconData = iconData
        self.isDemo = isDemo
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }
}

extension StoredLauncherApp {
    /// What this record is. Anything unrecognised — a record from before kinds
    /// existed, or one written by a later version — reads as an app, which is
    /// the one kind every version of Holograph has understood.
    var kind: LauncherItemKind {
        kindRaw.flatMap(LauncherItemKind.init(rawValue:)) ?? .app
    }

    /// `nil` when the stored launch URL can no longer be parsed. Callers drop
    /// such rows from the wall rather than crashing on them. A folder has no
    /// URL and is never dropped for want of one.
    var item: LauncherItem? {
        let kind = self.kind
        let url = URL(string: launchURLString)
        guard kind == .folder || url != nil else { return nil }
        return LauncherItem(
            id: identifier,
            kind: kind,
            name: name,
            launchURL: kind == .folder ? nil : url,
            fallbackURL: fallbackURLString.flatMap(URL.init(string:)),
            parentFolderID: kind == .folder ? nil : parentFolderID,
            sortOrder: sortOrder,
            iconData: iconData,
            isDemo: isDemo,
            createdAt: createdAt,
            modifiedAt: modifiedAt
        )
    }

    func apply(_ draft: LauncherItemDraft, modifiedAt date: Date) {
        kindRaw = draft.kind.rawValue
        name = draft.name
        launchURLString = draft.launchURL?.absoluteString ?? ""
        fallbackURLString = draft.fallbackURL?.absoluteString
        // A folder is never inside anything, whatever a caller asks for.
        parentFolderID = draft.kind == .folder ? nil : draft.parentFolderID
        iconData = draft.iconData
        isDemo = draft.isDemo
        self.modifiedAt = date
    }
}
