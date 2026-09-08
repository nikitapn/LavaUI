import XCTest

@testable import LavaViewCore

/// Which way up a picture is, as bookkeeping.
///
/// The pixels themselves are turned by the decoder now, in one place for both
/// the screen and the file it saves — `canvas/tests/exif_test.cpp` is where the
/// off-by-one that mirrors a photograph is checked for. What is left here is
/// the arithmetic the viewer reasons with: that four right turns is none, that
/// a quarter turn swaps the axes a fit is computed from, and that an upright
/// picture says nothing in the bar.
final class RotationTests: XCTestCase {
    /// Every pixel identifiable: red channel is x, green is y, alpha opaque.
    private func grid(width: Int, height: Int) -> [UInt8] {
        var out: [UInt8] = []
        for y in 0..<height {
            for x in 0..<width {
                out.append(contentsOf: [UInt8(x), UInt8(y), 0, 255])
            }
        }
        return out
    }

    // MARK: - Bookkeeping

    func testTurningRightFourTimesIsIdentity() {
        var r = Rotation.none
        for _ in 0..<4 { r = r.turnedRight() }
        XCTAssertEqual(r, .none)
    }

    func testTurningLeftIsTheInverseOfRight() {
        XCTAssertEqual(Rotation.none.turnedRight().turnedLeft(), .none)
        XCTAssertEqual(Rotation.half.turnedLeft().turnedRight(), .half)
    }

    func testQuarterTurnsSwapTheAxes() {
        let size = PixelSize(width: 4000, height: 3000)
        XCTAssertEqual(Rotation.quarter.applied(to: size).width, 3000)
        XCTAssertEqual(Rotation.quarter.applied(to: size).height, 4000)
        XCTAssertEqual(Rotation.half.applied(to: size), size)
    }

    func testUprightHasNoBadge() {
        XCTAssertNil(Rotation.none.badge)
        XCTAssertEqual(Rotation.quarter.badge, "90°")
    }

    // MARK: - Alpha

    func testTransparencyIsFoundWhereverItIs() {
        var pixels = grid(width: 4, height: 4)
        XCTAssertFalse(SaveTarget.hasTransparency(pixels: pixels))
        pixels[pixels.count - 1] = 128
        XCTAssertTrue(SaveTarget.hasTransparency(pixels: pixels))
    }
}
