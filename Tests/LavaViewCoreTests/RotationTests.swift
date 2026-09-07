import XCTest

@testable import LavaViewCore

/// Turning pixels, checked on buffers small enough to write out by hand.
///
/// This is the part with an off-by-one in it: a quarter turn that reads the
/// source row from the wrong end is a mirrored photograph, and at photo sizes
/// that is not something you can see by squinting at a debugger.
final class RotationTests: XCTestCase {
    /// A 2×3 image whose every pixel is identifiable: red channel is x,
    /// green is y, alpha opaque.
    private func grid(width: Int, height: Int) -> [UInt8] {
        var out: [UInt8] = []
        for y in 0..<height {
            for x in 0..<width {
                out.append(contentsOf: [UInt8(x), UInt8(y), 0, 255])
            }
        }
        return out
    }

    private func pixel(
        _ buffer: [UInt8], width: Int, x: Int, y: Int
    ) -> (x: UInt8, y: UInt8) {
        let i = (y * width + x) * 4
        return (buffer[i], buffer[i + 1])
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

    // MARK: - Pixels

    func testQuarterTurnMovesTheTopLeftToTheTopRight() {
        // Clockwise: the pixel that was at the top-left ends up top-right.
        let src = grid(width: 2, height: 3)
        guard let out = PixelRotate.rotate(
            pixels: src, width: 2, height: 3, by: .quarter
        ) else { return XCTFail("rotate refused a well-formed buffer") }

        XCTAssertEqual(out.width, 3)
        XCTAssertEqual(out.height, 2)
        // Source (0,0) → destination (2,0) in a 3-wide result.
        let corner = pixel(out.pixels, width: out.width, x: 2, y: 0)
        XCTAssertEqual(corner.x, 0)
        XCTAssertEqual(corner.y, 0)
        // Source (1,2) → destination (0,1).
        let opposite = pixel(out.pixels, width: out.width, x: 0, y: 1)
        XCTAssertEqual(opposite.x, 1)
        XCTAssertEqual(opposite.y, 2)
    }

    func testThreeQuarterTurnIsTheMirrorOfTheQuarterTurn() {
        let src = grid(width: 2, height: 3)
        guard let cw = PixelRotate.rotate(pixels: src, width: 2, height: 3, by: .quarter),
              let ccw = PixelRotate.rotate(pixels: src, width: 2, height: 3, by: .threeQuarter)
        else { return XCTFail("rotate refused a well-formed buffer") }

        // Source (0,0) goes top-right clockwise and bottom-left the other way.
        let a = pixel(ccw.pixels, width: ccw.width, x: 0, y: 1)
        XCTAssertEqual(a.x, 0)
        XCTAssertEqual(a.y, 0)
        XCTAssertNotEqual(cw.pixels, ccw.pixels)
    }

    func testHalfTurnReversesTheBuffer() {
        let src = grid(width: 2, height: 3)
        guard let out = PixelRotate.rotate(
            pixels: src, width: 2, height: 3, by: .half
        ) else { return XCTFail("rotate refused a well-formed buffer") }
        XCTAssertEqual(out.width, 2)
        XCTAssertEqual(out.height, 3)
        let corner = pixel(out.pixels, width: 2, x: 0, y: 0)
        XCTAssertEqual(corner.x, 1)
        XCTAssertEqual(corner.y, 2)
    }

    func testFourQuarterTurnsReturnTheOriginalPixels() {
        var pixels = grid(width: 5, height: 3)
        var w = 5
        var h = 3
        for _ in 0..<4 {
            guard let out = PixelRotate.rotate(
                pixels: pixels, width: w, height: h, by: .quarter
            ) else { return XCTFail("rotate refused a well-formed buffer") }
            pixels = out.pixels
            w = out.width
            h = out.height
        }
        XCTAssertEqual(w, 5)
        XCTAssertEqual(h, 3)
        XCTAssertEqual(pixels, grid(width: 5, height: 3))
    }

    func testNoTurnCopiesNothing() {
        let src = grid(width: 3, height: 2)
        let out = PixelRotate.rotate(pixels: src, width: 3, height: 2, by: .none)
        XCTAssertEqual(out?.pixels, src)
    }

    func testABufferThatDoesNotMatchItsDimensionsIsRefused() {
        XCTAssertNil(PixelRotate.rotate(pixels: [0, 0, 0, 255], width: 4, height: 4, by: .quarter))
        XCTAssertNil(PixelRotate.rotate(pixels: [], width: 0, height: 0, by: .quarter))
    }

    // MARK: - Alpha

    func testTransparencyIsFoundWhereverItIs() {
        var pixels = grid(width: 4, height: 4)
        XCTAssertFalse(PixelRotate.hasTransparency(pixels: pixels))
        pixels[pixels.count - 1] = 128
        XCTAssertTrue(PixelRotate.hasTransparency(pixels: pixels))
    }
}
