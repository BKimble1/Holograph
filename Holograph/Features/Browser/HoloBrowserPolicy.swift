import Foundation

/// What Holograph should do with a URL a page is trying to reach.
///
/// Pure, and separate from WebKit, because this is the part with actual
/// judgement in it and the part most worth testing. A web view is not needed to
/// ask "should this stay inside Holograph?".
enum WebNavigationDecision: Equatable, Sendable {
    /// Ordinary web navigation; let the web view have it.
    case allowInHolograph
    /// Not something a web view can run — a `tel:`, `mailto:` or an app's own
    /// scheme. Hand it to iPadOS, which is what the user meant by tapping it.
    case handToSystem(URL)
    /// Nothing good comes of following this one.
    case block
}

/// Decides where a navigation goes.
///
/// Holograph's whole promise for a website tile is that the site lives *inside*
/// it, so the default is to keep everything. The exceptions are narrow and
/// deliberate: schemes a web view cannot render at all, and schemes that exist
/// to run something rather than to show something.
enum HoloBrowserPolicy {
    /// Schemes a web view renders itself.
    static let webSchemes: Set<String> = ["http", "https"]

    /// Schemes that are a way to execute something rather than to visit
    /// something. Neither Holograph nor iPadOS should follow these from a page.
    static let blockedSchemes: Set<String> = ["javascript", "file", "data", "blob"]

    static func decision(for url: URL?) -> WebNavigationDecision {
        guard let url, let scheme = url.scheme?.lowercased(), !scheme.isEmpty else {
            return .block
        }
        if blockedSchemes.contains(scheme) { return .block }
        if webSchemes.contains(scheme) { return .allowInHolograph }
        // `about:blank` is what a web view opens a new frame with; it is not a
        // destination and must not be pushed at iPadOS.
        if scheme == "about" { return .allowInHolograph }
        return .handToSystem(url)
    }

    /// What the chrome shows for the current page: the site, plainly, rather
    /// than a full URL nobody reads.
    static func title(for url: URL?, pageTitle: String?) -> String {
        if let pageTitle, !pageTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return pageTitle
        }
        guard let url else { return "" }
        if let host = url.host() {
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        return url.absoluteString
    }
}
