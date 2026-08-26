import Foundation

/// What a tile on the wall actually is.
///
/// Three kinds, and no more: an app the system opens, a website Holograph opens
/// inside itself, and a folder that holds either. Folders deliberately cannot
/// contain folders — one level is what a launcher this size needs, and nesting
/// buys complexity nobody asked for.
enum LauncherItemKind: String, Codable, Sendable, CaseIterable {
    case app
    case website
    case folder

    /// How VoiceOver names it, and how Settings labels it.
    var noun: String {
        switch self {
        case .app: return "app"
        case .website: return "website"
        case .folder: return "folder"
        }
    }

    /// Whether an item of this kind is opened by leaving Holograph.
    var leavesHolograph: Bool { self == .app }
}

/// A tile as the UI sees it.
///
/// This is a plain, `Sendable` snapshot of a persisted record. Views and view
/// models never touch SwiftData objects directly, which keeps the UI layer free
/// of persistence concerns and makes previews and tests trivial.
struct LauncherItem: Identifiable, Hashable, Sendable {
    let id: UUID
    var kind: LauncherItemKind
    var name: String
    /// Where activating this sends the user. Always `nil` for a folder, which
    /// goes nowhere — it opens in place — and never `nil` for anything else.
    var launchURL: URL?
    var fallbackURL: URL?
    /// A folder this also appears in, or `nil` when it appears only on the
    /// wall.
    ///
    /// *Also*, not *instead*. Putting something in a folder groups it; it does
    /// not take it off the wall, any more than a playlist takes a song out of
    /// your library. Folders are a second way to reach the same tile.
    var parentFolderID: UUID?
    /// Position on the wall.
    var sortOrder: Int
    /// Position inside its folder, which is independent of its position on the
    /// wall — the same tile can be third on the wall and first in a folder.
    var folderSortOrder: Int
    var iconData: Data?
    var isDemo: Bool
    var createdAt: Date
    var modifiedAt: Date

    init(
        id: UUID = UUID(),
        kind: LauncherItemKind = .app,
        name: String,
        launchURL: URL? = nil,
        fallbackURL: URL? = nil,
        parentFolderID: UUID? = nil,
        sortOrder: Int = 0,
        folderSortOrder: Int = 0,
        iconData: Data? = nil,
        isDemo: Bool = false,
        createdAt: Date = .init(timeIntervalSinceReferenceDate: 0),
        modifiedAt: Date = .init(timeIntervalSinceReferenceDate: 0)
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.launchURL = launchURL
        self.fallbackURL = fallbackURL
        self.parentFolderID = parentFolderID
        self.sortOrder = sortOrder
        self.folderSortOrder = folderSortOrder
        self.iconData = iconData
        self.isDemo = isDemo
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }

    /// Up to two initials, used when an icon is missing or unreadable.
    var monogram: String {
        let words = name
            .split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" })
            .prefix(2)
        let initials = words.compactMap { $0.first }.map(String.init).joined()
        return initials.isEmpty ? "?" : initials.uppercased()
    }

    var isFolder: Bool { kind == .folder }
    var isWebsite: Bool { kind == .website }

    /// A short, human readable description of where this item will send the user.
    var launchTargetDescription: String {
        guard let launchURL else { return "this folder" }
        switch kind {
        case .website:
            return launchURL.host() ?? launchURL.absoluteString
        case .app, .folder:
            if let scheme = launchURL.scheme, !scheme.isEmpty {
                return "\(scheme)://"
            }
            return launchURL.absoluteString
        }
    }

    /// What Settings shows under the name. A folder has no link, so it says how
    /// much is in it instead — filled in by the caller, which is the only thing
    /// that knows.
    func subtitle(folderCount: Int = 0) -> String {
        switch kind {
        case .folder:
            return folderCount == 1 ? "1 item" : "\(folderCount) items"
        case .app, .website:
            return launchURL?.absoluteString ?? ""
        }
    }
}

/// The editable payload used to create or update a `LauncherItem`.
///
/// URLs are already validated by the time a draft reaches the repository — see
/// `LaunchURLValidator` and `WebsiteURLValidator`.
struct LauncherItemDraft: Hashable, Sendable {
    var kind: LauncherItemKind
    var name: String
    var launchURL: URL?
    var fallbackURL: URL?
    var parentFolderID: UUID?
    var iconData: Data?
    var isDemo: Bool

    init(
        kind: LauncherItemKind = .app,
        name: String,
        launchURL: URL? = nil,
        fallbackURL: URL? = nil,
        parentFolderID: UUID? = nil,
        iconData: Data? = nil,
        isDemo: Bool = false
    ) {
        self.kind = kind
        self.name = name
        self.launchURL = launchURL
        self.fallbackURL = fallbackURL
        self.parentFolderID = parentFolderID
        self.iconData = iconData
        self.isDemo = isDemo
    }
}

extension LauncherItem {
    var draft: LauncherItemDraft {
        LauncherItemDraft(
            kind: kind,
            name: name,
            launchURL: launchURL,
            fallbackURL: fallbackURL,
            parentFolderID: parentFolderID,
            iconData: iconData,
            isDemo: isDemo
        )
    }
}

// MARK: - Scoping

extension Array where Element == LauncherItem {
    /// What the main wall shows: everything.
    ///
    /// Being in a folder does not hide a tile from the wall. A folder is a
    /// grouping you can also reach things through, not a drawer they are moved
    /// into and disappear from.
    var rootItems: [LauncherItem] {
        sortedForDisplay()
    }

    /// What one folder holds, in the folder's own order.
    func children(of folderID: UUID) -> [LauncherItem] {
        filter { $0.parentFolderID == folderID }
            .sorted { ($0.folderSortOrder, $0.createdAt) < ($1.folderSortOrder, $1.createdAt) }
    }

    /// What could still be added to a folder: everything that is not a folder
    /// and is not already in this one.
    func addableToFolder(_ folderID: UUID) -> [LauncherItem] {
        filter { !$0.isFolder && $0.parentFolderID != folderID }.sortedForDisplay()
    }

    /// Only the folders, for the "move into…" pickers.
    var folders: [LauncherItem] {
        filter(\.isFolder).sortedForDisplay()
    }

    /// Ordering is per scope, so the same rule is applied after every filter.
    func sortedForDisplay() -> [LauncherItem] {
        sorted { ($0.sortOrder, $0.createdAt) < ($1.sortOrder, $1.createdAt) }
    }
}
