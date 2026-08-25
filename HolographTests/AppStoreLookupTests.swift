import XCTest
@testable import Holograph

final class AppStoreLookupTests: XCTestCase {
    private let payload = """
    {
      "resultCount": 1,
      "results": [
        {
          "trackId": 1234567890,
          "trackName": "Field Notes",
          "bundleId": "com.example.fieldnotes",
          "artworkUrl512": "https://example.com/artwork512.png",
          "artworkUrl100": "https://example.com/artwork100.png",
          "artworkUrl60": "https://example.com/artwork60.png"
        }
      ]
    }
    """

    func testDecodesTheFieldsTheEditorUses() throws {
        let metadata = try AppStoreLookupResponse.metadata(from: XCTUnwrap(payload.data(using: .utf8)))

        XCTAssertEqual(metadata.appID, 1_234_567_890)
        XCTAssertEqual(metadata.name, "Field Notes")
        XCTAssertEqual(metadata.bundleID, "com.example.fieldnotes")
        XCTAssertEqual(metadata.artworkURL?.absoluteString, "https://example.com/artwork512.png")
    }

    func testFallsBackToSmallerArtworkWhenTheLargeSizeIsMissing() throws {
        let json = """
        {"resultCount":1,"results":[{"trackId":7,"trackName":"Tiny","artworkUrl100":"https://example.com/a100.png"}]}
        """
        let metadata = try AppStoreLookupResponse.metadata(from: XCTUnwrap(json.data(using: .utf8)))

        XCTAssertEqual(metadata.artworkURL?.absoluteString, "https://example.com/a100.png")
        XCTAssertNil(metadata.bundleID)
    }

    func testAnEmptyResultSetIsReportedAsNotFound() throws {
        let json = #"{"resultCount":0,"results":[]}"#
        XCTAssertThrowsError(
            try AppStoreLookupResponse.metadata(from: XCTUnwrap(json.data(using: .utf8)))
        ) { error in
            XCTAssertEqual(error as? AppStoreLookupError, .notFound)
        }
    }

    func testMalformedJSONIsReportedAsADecodingFailure() {
        XCTAssertThrowsError(try AppStoreLookupResponse.metadata(from: Data("not json".utf8))) { error in
            XCTAssertEqual(error as? AppStoreLookupError, .decoding)
        }
    }

    func testServiceBuildsTheLookupURLAndDecodesTheResponse() async throws {
        let data = try XCTUnwrap(payload.data(using: .utf8))
        let requested = RequestRecorder()
        let service = AppStoreLookupService { url in
            await requested.record(url)
            return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }

        let metadata = try await service.metadata(forAppID: 1_234_567_890, countryCode: "GB")

        XCTAssertEqual(metadata.name, "Field Notes")
        let recorded = await requested.urls
        let url = try XCTUnwrap(recorded.first)
        XCTAssertEqual(url.host(), "itunes.apple.com")
        XCTAssertEqual(url.path(), "/lookup")
        let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertTrue(query.contains(URLQueryItem(name: "id", value: "1234567890")))
        XCTAssertTrue(query.contains(URLQueryItem(name: "country", value: "GB")))
    }

    func testServiceSurfacesHTTPErrors() async {
        let service = AppStoreLookupService { url in
            (Data(), HTTPURLResponse(url: url, statusCode: 503, httpVersion: nil, headerFields: nil)!)
        }

        do {
            _ = try await service.metadata(forAppID: 1, countryCode: nil)
            XCTFail("Expected a network error")
        } catch let error as AppStoreLookupError {
            XCTAssertEqual(error, .network("Status 503."))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testServiceSurfacesTransportErrors() async {
        struct Boom: Error {}
        let service = AppStoreLookupService { _ in throw Boom() }

        do {
            _ = try await service.metadata(forAppID: 1, countryCode: nil)
            XCTFail("Expected a network error")
        } catch let error as AppStoreLookupError {
            guard case .network = error else {
                return XCTFail("Expected .network, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testArtworkDownloadRejectsEmptyPayloads() async {
        let service = AppStoreLookupService { url in
            (Data(), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }

        do {
            _ = try await service.artworkData(at: try XCTUnwrap(URL(string: "https://example.com/a.png")))
            XCTFail("Expected an artwork error")
        } catch let error as AppStoreLookupError {
            XCTAssertEqual(error, .artworkUnavailable)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

/// Collects the URLs a stubbed loader was asked for.
private actor RequestRecorder {
    private(set) var urls: [URL] = []

    func record(_ url: URL) {
        urls.append(url)
    }
}
