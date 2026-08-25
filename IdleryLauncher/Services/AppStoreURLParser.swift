import Foundation

/// Extracts the numeric Apple app identifier from a public App Store link.
///
/// This is a convenience for prefilling the editor only. The App Store link is
/// never assumed to be the app's launch link.
enum AppStoreURLParser {
    private static let appleHostSuffixes = ["apps.apple.com", "itunes.apple.com", "apple.co"]

    /// Accepts things like:
    /// - `https://apps.apple.com/us/app/some-app/id123456789`
    /// - `https://apps.apple.com/app/id123456789?mt=8`
    /// - `https://itunes.apple.com/lookup?id=123456789`
    /// - `id123456789`
    /// - `123456789`
    static func appID(from raw: String) -> Int? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let bare = bareIdentifier(in: trimmed) { return bare }

        guard let components = URLComponents(string: trimmed),
              let host = components.host?.lowercased(),
              appleHostSuffixes.contains(where: { host == $0 || host.hasSuffix("." + $0) })
        else { return nil }

        if let queryValue = components.queryItems?.first(where: { $0.name.lowercased() == "id" })?.value,
           let identifier = digitsOnly(queryValue) {
            return identifier
        }

        for segment in components.path.split(separator: "/") {
            if let identifier = identifier(inPathSegment: String(segment)) { return identifier }
        }
        return nil
    }

    /// `"id123456789"` or a plain numeric string typed on its own.
    private static func bareIdentifier(in text: String) -> Int? {
        guard !text.contains("/"), !text.contains(":") else { return nil }
        if let value = identifier(inPathSegment: text) { return value }
        return digitsOnly(text)
    }

    private static func identifier(inPathSegment segment: String) -> Int? {
        let lowercased = segment.lowercased()
        guard lowercased.hasPrefix("id") else { return nil }
        return digitsOnly(String(segment.dropFirst(2)))
    }

    private static func digitsOnly(_ text: String) -> Int? {
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }), text.count >= 3 else { return nil }
        return Int(text)
    }
}
