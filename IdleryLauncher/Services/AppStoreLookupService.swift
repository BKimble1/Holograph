import Foundation

/// The subset of the public iTunes lookup payload the editor uses to prefill.
struct AppStoreMetadata: Sendable, Equatable {
    var appID: Int
    var name: String
    var bundleID: String?
    var artworkURL: URL?
}

enum AppStoreLookupError: LocalizedError, Equatable {
    case invalidLink
    case notFound
    case network(String)
    case decoding
    case artworkUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidLink:
            return "That doesn’t look like an App Store link."
        case .notFound:
            return "No app was found for that link."
        case .network(let reason):
            return "Couldn’t reach the App Store. \(reason)"
        case .decoding:
            return "The App Store returned something unexpected."
        case .artworkUnavailable:
            return "The artwork for that app couldn’t be downloaded."
        }
    }
}

protocol AppStoreMetadataProviding: Sendable {
    func metadata(forAppID appID: Int, countryCode: String?) async throws -> AppStoreMetadata
    func artworkData(at url: URL) async throws -> Data
}

/// Wire format for `https://itunes.apple.com/lookup?id=...`.
struct AppStoreLookupResponse: Decodable, Sendable {
    struct Entry: Decodable, Sendable {
        let trackId: Int
        let trackName: String
        let bundleId: String?
        let artworkUrl512: String?
        let artworkUrl100: String?
        let artworkUrl60: String?
    }

    let resultCount: Int
    let results: [Entry]
}

extension AppStoreLookupResponse {
    /// Pulls the highest quality artwork the payload offers.
    static func metadata(from data: Data) throws -> AppStoreMetadata {
        let decoded: AppStoreLookupResponse
        do {
            decoded = try JSONDecoder().decode(AppStoreLookupResponse.self, from: data)
        } catch {
            throw AppStoreLookupError.decoding
        }
        guard let entry = decoded.results.first, decoded.resultCount > 0 else {
            throw AppStoreLookupError.notFound
        }
        let artworkString = entry.artworkUrl512 ?? entry.artworkUrl100 ?? entry.artworkUrl60
        return AppStoreMetadata(
            appID: entry.trackId,
            name: entry.trackName,
            bundleID: entry.bundleId,
            artworkURL: artworkString.flatMap(URL.init(string:))
        )
    }
}

/// Talks to Apple's public lookup endpoint.
///
/// The network call is injected as a closure so the type stays `Sendable` and
/// tests can exercise decoding and error handling without a live connection.
struct AppStoreLookupService: AppStoreMetadataProviding {
    typealias DataLoader = @Sendable (URL) async throws -> (Data, URLResponse)

    private let load: DataLoader

    init(load: @escaping DataLoader = { try await URLSession.shared.data(from: $0) }) {
        self.load = load
    }

    func metadata(forAppID appID: Int, countryCode: String?) async throws -> AppStoreMetadata {
        var components = URLComponents(string: "https://itunes.apple.com/lookup")
        var queryItems = [URLQueryItem(name: "id", value: String(appID))]
        if let countryCode, !countryCode.isEmpty {
            queryItems.append(URLQueryItem(name: "country", value: countryCode))
        }
        components?.queryItems = queryItems
        guard let url = components?.url else { throw AppStoreLookupError.invalidLink }

        let data: Data
        do {
            let (payload, response) = try await load(url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw AppStoreLookupError.network("Status \(http.statusCode).")
            }
            data = payload
        } catch let error as AppStoreLookupError {
            throw error
        } catch {
            throw AppStoreLookupError.network(error.localizedDescription)
        }

        return try AppStoreLookupResponse.metadata(from: data)
    }

    func artworkData(at url: URL) async throws -> Data {
        do {
            let (data, response) = try await load(url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw AppStoreLookupError.artworkUnavailable
            }
            guard !data.isEmpty else { throw AppStoreLookupError.artworkUnavailable }
            return data
        } catch let error as AppStoreLookupError {
            throw error
        } catch {
            throw AppStoreLookupError.network(error.localizedDescription)
        }
    }
}
