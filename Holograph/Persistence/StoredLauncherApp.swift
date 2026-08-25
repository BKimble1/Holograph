import Foundation
import SwiftData

/// The persisted representation of a launchable app.
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
    var launchURLString: String
    var fallbackURLString: String?
    var sortOrder: Int
    /// PNG data capped at `IconProcessor.maxPixelSize`; see `IconProcessor`.
    var iconData: Data?
    var isDemo: Bool
    var createdAt: Date
    var modifiedAt: Date

    init(
        identifier: UUID = UUID(),
        name: String,
        launchURLString: String,
        fallbackURLString: String? = nil,
        sortOrder: Int,
        iconData: Data? = nil,
        isDemo: Bool = false,
        createdAt: Date = .now,
        modifiedAt: Date = .now
    ) {
        self.identifier = identifier
        self.name = name
        self.launchURLString = launchURLString
        self.fallbackURLString = fallbackURLString
        self.sortOrder = sortOrder
        self.iconData = iconData
        self.isDemo = isDemo
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }
}

extension StoredLauncherApp {
    /// `nil` when the stored launch URL can no longer be parsed. Callers drop
    /// such rows from the carousel rather than crashing on them.
    var item: LauncherItem? {
        guard let launchURL = URL(string: launchURLString) else { return nil }
        return LauncherItem(
            id: identifier,
            name: name,
            launchURL: launchURL,
            fallbackURL: fallbackURLString.flatMap(URL.init(string:)),
            sortOrder: sortOrder,
            iconData: iconData,
            isDemo: isDemo,
            createdAt: createdAt,
            modifiedAt: modifiedAt
        )
    }

    func apply(_ draft: LauncherItemDraft, modifiedAt date: Date) {
        name = draft.name
        launchURLString = draft.launchURL.absoluteString
        fallbackURLString = draft.fallbackURL?.absoluteString
        iconData = draft.iconData
        isDemo = draft.isDemo
        self.modifiedAt = date
    }
}
