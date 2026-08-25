import XCTest
@testable import Holograph

/// The depth curve is pure maths, so its shape can be pinned down without a
/// running scroll view.
final class CarouselGeometryTests: XCTestCase {
    func testCentredTileIsAtOffsetZero() {
        let offset = HolographicCarousel.normalisedOffset(midX: 500, containerWidth: 1000, slotWidth: 260)
        XCTAssertEqual(offset, 0, accuracy: 0.0001)
    }

    func testNeighbouringSlotIsOneUnitAway() {
        let offset = HolographicCarousel.normalisedOffset(midX: 760, containerWidth: 1000, slotWidth: 260)
        XCTAssertEqual(offset, 1, accuracy: 0.0001)
    }

    func testZeroSlotWidthDoesNotDivideByZero() {
        XCTAssertEqual(HolographicCarousel.normalisedOffset(midX: 400, containerWidth: 1000, slotWidth: 0), 0)
    }

    func testCentredTileIsFullSizeAndOpaque() {
        XCTAssertEqual(HolographicCarousel.scale(forOffset: 0, usesDepth: true), 1, accuracy: 0.0001)
        XCTAssertEqual(HolographicCarousel.opacity(forOffset: 0), 1, accuracy: 0.0001)
    }

    func testNeighboursShrinkIntoTheDesignedRange() {
        let neighbour = HolographicCarousel.scale(forOffset: 1, usesDepth: true)
        XCTAssertEqual(neighbour, HoloTheme.neighbourScale, accuracy: 0.0001)
        XCTAssertTrue((0.60...0.70).contains(neighbour), "Design calls for 60–70% scale on neighbours")
    }

    func testOuterTilesRecedeFurtherStill() {
        let outer = HolographicCarousel.scale(forOffset: 3, usesDepth: true)
        XCTAssertEqual(outer, HoloTheme.outerScale, accuracy: 0.0001)
        XCTAssertLessThan(outer, HolographicCarousel.scale(forOffset: 1, usesDepth: true))
    }

    func testScaleAndOpacityAreSymmetricAroundTheCentre() {
        for offset in stride(from: 0.25, through: 3.0, by: 0.25) {
            XCTAssertEqual(
                HolographicCarousel.scale(forOffset: offset, usesDepth: true),
                HolographicCarousel.scale(forOffset: -offset, usesDepth: true),
                accuracy: 0.0001
            )
            XCTAssertEqual(
                HolographicCarousel.opacity(forOffset: offset),
                HolographicCarousel.opacity(forOffset: -offset),
                accuracy: 0.0001
            )
        }
    }

    func testScaleDecreasesMonotonicallyWithDistance() {
        var previous = HolographicCarousel.scale(forOffset: 0, usesDepth: true)
        for offset in stride(from: 0.1, through: 3.0, by: 0.1) {
            let current = HolographicCarousel.scale(forOffset: offset, usesDepth: true)
            XCTAssertLessThanOrEqual(current, previous + 0.0001, "Scale increased at offset \(offset)")
            previous = current
        }
    }

    func testOpacityNeverReachesZeroSoOuterTilesStayHinted() {
        for offset in stride(from: 0.0, through: 6.0, by: 0.5) {
            let opacity = HolographicCarousel.opacity(forOffset: offset)
            XCTAssertGreaterThan(opacity, 0)
            XCTAssertLessThanOrEqual(opacity, 1)
        }
    }

    func testReduceMotionReplacesTheContinuousCurveWithOneStep() {
        XCTAssertEqual(HolographicCarousel.scale(forOffset: 0, usesDepth: false), 1, accuracy: 0.0001)
        XCTAssertEqual(HolographicCarousel.scale(forOffset: 0.2, usesDepth: false), 1, accuracy: 0.0001)
        XCTAssertEqual(HolographicCarousel.scale(forOffset: 1, usesDepth: false), 0.72, accuracy: 0.0001)
        XCTAssertEqual(HolographicCarousel.scale(forOffset: 3, usesDepth: false), 0.72, accuracy: 0.0001)
    }

    func testTiltLeansAwayFromTheCentreAndIsClamped() {
        XCTAssertEqual(HolographicCarousel.tiltDegrees(forOffset: 0), 0, accuracy: 0.0001)
        XCTAssertLessThan(HolographicCarousel.tiltDegrees(forOffset: 1), 0)
        XCTAssertGreaterThan(HolographicCarousel.tiltDegrees(forOffset: -1), 0)
        XCTAssertEqual(
            HolographicCarousel.tiltDegrees(forOffset: 9),
            HolographicCarousel.tiltDegrees(forOffset: 2.5),
            accuracy: 0.0001
        )
    }

    func testParallaxPullsDistantTilesTowardsTheCentre() {
        XCTAssertEqual(HolographicCarousel.parallax(forOffset: 0, slotWidth: 260), 0, accuracy: 0.0001)
        XCTAssertLessThan(HolographicCarousel.parallax(forOffset: 2, slotWidth: 260), 0)
        XCTAssertGreaterThan(HolographicCarousel.parallax(forOffset: -2, slotWidth: 260), 0)
    }
}

final class LauncherLayoutTests: XCTestCase {
    func testLandscapeIPadGetsALargeTile() {
        let layout = LauncherLayout(size: CGSize(width: 1366, height: 1024))
        XCTAssertGreaterThan(layout.tileSize, 240)
        XCTAssertLessThanOrEqual(layout.tileSize, 320)
        XCTAssertFalse(layout.isCompact)
    }

    func testPortraitStaysUsable() {
        let layout = LauncherLayout(size: CGSize(width: 1024, height: 1366))
        XCTAssertGreaterThan(layout.tileSize, 108)
        XCTAssertLessThanOrEqual(layout.tileSize, 320)
    }

    func testNarrowSplitViewCollapsesToCompactSpacing() {
        let layout = LauncherLayout(size: CGSize(width: 375, height: 1024))
        XCTAssertTrue(layout.isCompact)
        XCTAssertGreaterThanOrEqual(layout.tileSize, 108)
    }

    func testTinyStageManagerWindowNeverProducesANegativeTile() {
        let layout = LauncherLayout(size: CGSize(width: 120, height: 90))
        XCTAssertGreaterThanOrEqual(layout.tileSize, 108)
        XCTAssertGreaterThan(layout.stageHeight, 0)
    }
}
