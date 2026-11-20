import XCTest

@testable import LavaUI

/// `StatusNotifierTray.areaDownscale`: what an app's 256px `IconPixmap` is
/// brought down to before it is uploaded.
final class TrayIconScaleTests: XCTestCase {
    private func pixel(_ rgba: [UInt8], _ w: Int, _ x: Int, _ y: Int) -> [UInt8] {
        let i = (y * w + x) * 4
        return Array(rgba[i..<i + 4])
    }

    /// Transparent pixels add coverage, not colour: a white edge against a
    /// clear margin stays white and goes half transparent, where averaging
    /// the channels straight would have greyed it.
    func testAMarginLowersAlphaAndLeavesColourAlone() {
        // 4×2: two clear columns, then two opaque white ones, per row.
        var src = [UInt8]()
        for _ in 0..<2 {
            src += [0, 0, 0, 0, 0, 0, 0, 0, 255, 255, 255, 255, 255, 255, 255, 255]
        }
        let (out, w, h) = StatusNotifierTray.areaDownscale(src, width: 4, height: 2, maxEdge: 2)
        XCTAssertEqual(w, 2)
        XCTAssertEqual(h, 1)
        XCTAssertEqual(pixel(out, w, 0, 0)[3], 0, "an all-clear cell gained coverage")
        XCTAssertEqual(pixel(out, w, 1, 0), [255, 255, 255, 255])

        // One cell straddling both: half covered, still white.
        let (mixed, mw, _) = StatusNotifierTray.areaDownscale(src, width: 4, height: 2, maxEdge: 1)
        XCTAssertEqual(mw, 1)
        XCTAssertEqual(Array(mixed[0..<3]), [255, 255, 255], "the clear half darkened the colour")
        XCTAssertEqual(Int(mixed[3]), 128, accuracy: 1)
    }

    func testSmallEnoughIsLeftAsItIs() {
        let src = [UInt8](repeating: 7, count: 16 * 16 * 4)
        let (out, w, h) = StatusNotifierTray.areaDownscale(src, width: 16, height: 16, maxEdge: 36)
        XCTAssertEqual(w, 16)
        XCTAssertEqual(h, 16)
        XCTAssertEqual(out, src)
    }

    func testTheLongerEdgeLandsOnTheCap() {
        let src = [UInt8](repeating: 255, count: 256 * 128 * 4)
        let (_, w, h) = StatusNotifierTray.areaDownscale(src, width: 256, height: 128, maxEdge: 36)
        XCTAssertEqual(w, 36)
        XCTAssertEqual(h, 18)
    }
}
