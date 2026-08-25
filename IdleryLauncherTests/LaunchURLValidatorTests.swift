import XCTest
@testable import IdleryLauncher

final class LaunchURLValidatorTests: XCTestCase {
    func testAcceptsCustomSchemesUsedByTheIdleryApps() throws {
        let schemes = [
            "idler-corecredit://launch",
            "idler-offrent://launch",
            "idler-magshift://launch",
            "idler-turbid://launch"
        ]
        for raw in schemes {
            let result = LaunchURLValidator.validate(raw)
            guard case .success(let url) = result else {
                return XCTFail("Expected \(raw) to validate, got \(result)")
            }
            XCTAssertEqual(url.absoluteString, raw)
        }
    }

    func testAcceptsSchemeWithNoPath() throws {
        guard case .success(let url) = LaunchURLValidator.validate("idler-turbid://") else {
            return XCTFail("Expected a bare custom scheme to validate")
        }
        XCTAssertEqual(url.scheme, "idler-turbid")
    }

    func testTrimsSurroundingWhitespace() throws {
        guard case .success(let url) = LaunchURLValidator.validate("  idler-offrent://launch \n") else {
            return XCTFail("Expected trimming")
        }
        XCTAssertEqual(url.absoluteString, "idler-offrent://launch")
    }

    func testRejectsEmptyInput() {
        XCTAssertEqual(LaunchURLValidator.validate("   "), .failure(.empty))
    }

    func testRejectsInputWithoutAScheme() {
        XCTAssertEqual(LaunchURLValidator.validate("just-some-text"), .failure(.missingScheme))
    }

    func testRejectsSpaces() {
        XCTAssertEqual(LaunchURLValidator.validate("idler offrent://launch"), .failure(.malformed))
    }

    func testRejectsUnsupportedSchemes() {
        XCTAssertEqual(
            LaunchURLValidator.validate("javascript:alertMe"),
            .failure(.unsupportedScheme("javascript"))
        )
        XCTAssertEqual(
            LaunchURLValidator.validate("file:///etc/passwd"),
            .failure(.unsupportedScheme("file"))
        )
    }

    func testRejectsSchemesThatDoNotStartWithALetter() {
        // Foundation may report this as a missing scheme or as malformed
        // depending on how leniently it parses; either way it must not pass.
        guard case .failure = LaunchURLValidator.validate("1app://launch") else {
            return XCTFail("A scheme starting with a digit must be rejected")
        }
    }

    func testRejectsWebLinksWithoutAHost() {
        XCTAssertEqual(LaunchURLValidator.validate("https://"), .failure(.missingHost))
    }

    func testNormalisesBareDomainsToHTTPS() throws {
        guard case .success(let url) = LaunchURLValidator.validate("idlery.example.com/help") else {
            return XCTFail("Expected a bare domain to be normalised")
        }
        XCTAssertEqual(url.absoluteString, "https://idlery.example.com/help")
    }

    func testFallbackAcceptsEmptyString() throws {
        guard case .success(let url) = LaunchURLValidator.validateFallback("  ") else {
            return XCTFail("An empty fallback is valid")
        }
        XCTAssertNil(url)
    }

    func testFallbackValidatesWhenProvided() throws {
        guard case .success(let url) = LaunchURLValidator.validateFallback("https://apps.apple.com/app/id123456789") else {
            return XCTFail("Expected a valid fallback")
        }
        XCTAssertEqual(url?.host(), "apps.apple.com")
    }

    func testFallbackReportsErrorsForGarbage() {
        XCTAssertEqual(LaunchURLValidator.validateFallback("nope"), .failure(.missingScheme))
    }

    func testSchemeCharacterRules() {
        XCTAssertTrue(LaunchURLValidator.isValidScheme("idler-offrent"))
        XCTAssertTrue(LaunchURLValidator.isValidScheme("a1+b.c-d"))
        XCTAssertFalse(LaunchURLValidator.isValidScheme(""))
        XCTAssertFalse(LaunchURLValidator.isValidScheme("has space"))
        XCTAssertFalse(LaunchURLValidator.isValidScheme("_leading"))
    }
}
