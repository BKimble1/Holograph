import Foundation

/// A launchable app as the UI sees it.
///
/// This is a plain, `Sendable` snapshot of a persisted record. Views and view
/// models never touch SwiftData objects directly, which keeps the UI layer free
/// of persistence concerns and makes previews and tests trivial.
struct LauncherItem: Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    var launchURL: URL
    var fallbackURL: URL?
    var sortOrder: Int
    var iconData: Data?
    var isDemo: Bool
    var createdAt: Date
    var modifiedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        launchURL: URL,
        fallbackURL: URL? = nil,
        sortOrder: Int = 0,
        iconData: Data? = nil,
        isDemo: Bool = false,
        createdAt: Date = .init(timeIntervalSinceReferenceDate: 0),
        modifiedAt: Date = .init(timeIntervalSinceReferenceDate: 0)
    ) {
        self.id = id
        self.name = name
        self.launchURL = launchURL
        self.fallbackURL = fallbackURL
        self.sortOrder = sortOrder
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

    /// A short, human readable description of where this item will send the user.
    var launchTargetDescription: String {
        if let scheme = launchURL.scheme, !scheme.isEmpty {
            return "\(scheme)://"
        }
        return launchURL.absoluteString
    }
}

/// The editable payload used to create or update a `LauncherItem`.
///
/// URLs are already validated by the time a draft reaches the repository — see
/// `LaunchURLValidator`.
struct LauncherItemDraft: Hashable, Sendable {
    var name: String
    var launchURL: URL
    var fallbackURL: URL?
    var iconData: Data?
    var isDemo: Bool

    init(
        name: String,
        launchURL: URL,
        fallbackURL: URL? = nil,
        iconData: Data? = nil,
        isDemo: Bool = false
    ) {
        self.name = name
        self.launchURL = launchURL
        self.fallbackURL = fallbackURL
        self.iconData = iconData
        self.isDemo = isDemo
    }
}

extension LauncherItem {
    var draft: LauncherItemDraft {
        LauncherItemDraft(
            name: name,
            launchURL: launchURL,
            fallbackURL: fallbackURL,
            iconData: iconData,
            isDemo: isDemo
        )
    }
}
