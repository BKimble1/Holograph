import CoreGraphics
import ImageIO
import XCTest
@testable import IdleryLauncher

@MainActor
final class IconProcessorTests: XCTestCase {
    private let processor = IconProcessor(maxPixelSize: 128)

    private func pixelSize(of data: Data) throws -> (width: Int, height: Int) {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )
        let width = try XCTUnwrap(properties[kCGImagePropertyPixelWidth] as? Int)
        let height = try XCTUnwrap(properties[kCGImagePropertyPixelHeight] as? Int)
        return (width, height)
    }

    func testOversizedImagesAreClampedToTheCeiling() throws {
        let processed = try processor.process(TestFixtures.pngData(width: 2048, height: 1536))

        XCTAssertEqual(processed.pixelSize, 128)
        let size = try pixelSize(of: processed.data)
        XCTAssertEqual(size.width, 128)
        XCTAssertEqual(size.height, 128)
    }

    func testNonSquareImagesAreCentreCroppedToASquare() throws {
        let processed = try processor.process(TestFixtures.pngData(width: 400, height: 100))

        let size = try pixelSize(of: processed.data)
        XCTAssertEqual(size.width, size.height)
        XCTAssertLessThanOrEqual(size.width, 128)
    }

    func testSmallImagesStayWithinTheCeiling() throws {
        let processed = try processor.process(TestFixtures.pngData(width: 64, height: 64))

        XCTAssertLessThanOrEqual(processed.pixelSize, 128)
        XCTAssertGreaterThanOrEqual(processed.pixelSize, 32)
    }

    func testProcessingShrinksLargePhotographs() throws {
        let original = TestFixtures.pngData(width: 2048, height: 2048)
        let processed = try processor.process(original)

        XCTAssertLessThan(processed.data.count, original.count)
    }

    func testEmptyDataIsRejected() {
        XCTAssertThrowsError(try processor.process(Data())) { error in
            XCTAssertEqual(error as? IconProcessingError, .emptyData)
        }
    }

    func testGarbageIsRejectedRatherThanCrashing() {
        let garbage = Data([0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07])
        XCTAssertThrowsError(try processor.process(garbage)) { error in
            XCTAssertEqual(error as? IconProcessingError, .unreadableImage)
        }
    }

    func testTruncatedPNGIsRejected() {
        let valid = TestFixtures.pngData(width: 64, height: 64)
        let truncated = valid.prefix(20)
        XCTAssertThrowsError(try processor.process(Data(truncated)))
    }

    func testDefaultCeilingIsFiveHundredAndTwelve() {
        XCTAssertEqual(IconProcessor().maxPixelSize, 512)
    }

    func testCeilingCannotBeSetAbsurdlyLow() {
        XCTAssertEqual(IconProcessor(maxPixelSize: 1).maxPixelSize, 32)
    }

    func testBackgroundProcessingProducesTheSameResult() async throws {
        let source = TestFixtures.pngData(width: 300, height: 300)
        let direct = try processor.process(source)
        let background = try await processor.processInBackground(source)

        XCTAssertEqual(direct.pixelSize, background.pixelSize)
    }

    func testCorruptStoredIconFallsBackToAMonogram() {
        // The view layer must survive icon data that no longer decodes.
        XCTAssertNil(IconArtworkView.image(from: Data([0xDE, 0xAD, 0xBE, 0xEF])))
        XCTAssertNil(IconArtworkView.image(from: nil))
        XCTAssertNil(IconArtworkView.image(from: Data()))
    }

    func testMonogramFallsBackForEveryName() {
        XCTAssertEqual(TestFixtures.item(name: "Field Notes").monogram, "FN")
        XCTAssertEqual(TestFixtures.item(name: "Turbid").monogram, "T")
        XCTAssertEqual(TestFixtures.item(name: "core-credit").monogram, "CC")
        XCTAssertEqual(TestFixtures.item(name: " ").monogram, "?")
    }
}
