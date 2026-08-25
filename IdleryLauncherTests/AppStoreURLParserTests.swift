import XCTest
@testable import IdleryLauncher

final class AppStoreURLParserTests: XCTestCase {
    func testParsesModernAppStoreLink() {
        XCTAssertEqual(
            AppStoreURLParser.appID(from: "https://apps.apple.com/us/app/some-app/id1234567890"),
            1_234_567_890
        )
    }

    func testParsesLinkWithoutCountryCode() {
        XCTAssertEqual(AppStoreURLParser.appID(from: "https://apps.apple.com/app/id987654321"), 987_654_321)
    }

    func testParsesLegacyITunesLinkWithQuery() {
        XCTAssertEqual(
            AppStoreURLParser.appID(from: "https://itunes.apple.com/us/app/some-app/id555000111?mt=8&uo=4"),
            555_000_111
        )
    }

    func testParsesLookupStyleQueryParameter() {
        XCTAssertEqual(AppStoreURLParser.appID(from: "https://itunes.apple.com/lookup?id=42424242"), 42_424_242)
    }

    func testParsesBareIdentifier() {
        XCTAssertEqual(AppStoreURLParser.appID(from: "id1122334455"), 1_122_334_455)
        XCTAssertEqual(AppStoreURLParser.appID(from: "1122334455"), 1_122_334_455)
    }

    func testTrimsWhitespace() {
        XCTAssertEqual(AppStoreURLParser.appID(from: "  https://apps.apple.com/app/id321321321  "), 321_321_321)
    }

    func testRejectsNonAppleHosts() {
        XCTAssertNil(AppStoreURLParser.appID(from: "https://example.com/app/id1234567890"))
    }

    func testRejectsLinksWithoutAnIdentifier() {
        XCTAssertNil(AppStoreURLParser.appID(from: "https://apps.apple.com/us/app/some-app"))
    }

    func testRejectsEmptyAndGarbage() {
        XCTAssertNil(AppStoreURLParser.appID(from: ""))
        XCTAssertNil(AppStoreURLParser.appID(from: "   "))
        XCTAssertNil(AppStoreURLParser.appID(from: "idler-offrent://launch"))
        XCTAssertNil(AppStoreURLParser.appID(from: "id12"))
    }
}
