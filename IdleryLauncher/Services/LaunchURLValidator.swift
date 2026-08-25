import Foundation

/// Why a user supplied launch URL cannot be used.
enum LaunchURLValidationError: LocalizedError, Equatable {
    case empty
    case malformed
    case missingScheme
    case invalidScheme(String)
    case unsupportedScheme(String)
    case missingHost

    var errorDescription: String? {
        switch self {
        case .empty:
            return "Enter a launch link."
        case .malformed:
            return "That link isn’t formatted correctly."
        case .missingScheme:
            return "Include a scheme, for example idler-offrent://launch."
        case .invalidScheme(let scheme):
            return "“\(scheme)” isn’t a valid URL scheme."
        case .unsupportedScheme(let scheme):
            return "The “\(scheme)” scheme can’t be used to launch an app."
        case .missingHost:
            return "Web links need a host, for example https://example.com."
        }
    }
}

/// Validates and lightly normalises the links a user types into the editor.
///
/// The launcher deliberately never asks `canOpenURL` about arbitrary custom
/// schemes — that requires declaring every scheme up front and would amount to
/// probing which apps are installed. Instead we make sure the string is a
/// well-formed URL and let `UIApplication.open` report the real outcome.
enum LaunchURLValidator {
    /// Schemes that either cannot foreground an app or are unsafe to hand to
    /// `UIApplication.open`.
    static let unsupportedSchemes: Set<String> = ["javascript", "data", "file", "about", "blob"]

    /// Trims the input and adds `https://` when the user typed a bare domain.
    static func normalize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        guard !trimmed.contains("://") else { return trimmed }
        // "mailto:someone" style URLs already carry a scheme.
        if let colon = trimmed.firstIndex(of: ":"),
           isValidScheme(String(trimmed[trimmed.startIndex..<colon])) {
            return trimmed
        }
        if trimmed.contains(".") && !trimmed.contains(" ") {
            return "https://" + trimmed
        }
        return trimmed
    }

    /// Validates a required launch link.
    static func validate(_ raw: String) -> Result<URL, LaunchURLValidationError> {
        let normalized = normalize(raw)
        guard !normalized.isEmpty else { return .failure(.empty) }
        guard !normalized.contains(" ") else { return .failure(.malformed) }
        guard let components = URLComponents(string: normalized) else { return .failure(.malformed) }

        guard let scheme = components.scheme, !scheme.isEmpty else {
            return .failure(.missingScheme)
        }
        guard isValidScheme(scheme) else {
            return .failure(.invalidScheme(scheme))
        }
        let lowercased = scheme.lowercased()
        guard !unsupportedSchemes.contains(lowercased) else {
            return .failure(.unsupportedScheme(lowercased))
        }
        if lowercased == "http" || lowercased == "https" {
            guard let host = components.host, !host.isEmpty, host.contains(".") else {
                return .failure(.missingHost)
            }
        }
        guard let url = components.url else { return .failure(.malformed) }
        return .success(url)
    }

    /// Validates the optional fallback link. An empty string is valid and means
    /// "no fallback configured".
    static func validateFallback(_ raw: String) -> Result<URL?, LaunchURLValidationError> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .success(nil) }
        return validate(trimmed).map { Optional($0) }
    }

    /// RFC 3986: scheme = ALPHA *( ALPHA / DIGIT / "+" / "-" / "." )
    static func isValidScheme(_ scheme: String) -> Bool {
        guard let first = scheme.first, first.isLetter, first.isASCII else { return false }
        return scheme.allSatisfy { character in
            guard character.isASCII else { return false }
            return character.isLetter || character.isNumber || character == "+" || character == "-" || character == "."
        }
    }
}
