import XCTest

@testable import LavaUI

/// The path data `Icon` draws is copied verbatim out of designs, so the
/// parser is held to SVG's grammar — including the parts people do not
/// write by hand, like arc flags run into the next number.
final class IconPathTests: XCTestCase {
    private func flatten(_ d: String) -> [[IconPoint]] { IconPathParser.flatten(d) }

    private func assertNear(_ p: IconPoint?, _ x: Float, _ y: Float,
                            file: StaticString = #filePath, line: UInt = #line) {
        guard let p else { return XCTFail("no point", file: file, line: line) }
        XCTAssertEqual(p.x, x, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(p.y, y, accuracy: 0.001, file: file, line: line)
    }

    /// Lucide's ×: two subpaths, the first with implicit linetos after M.
    func testMoveWithImplicitLinetoAndRelativeLine() {
        let paths = flatten("M18 6 6 18M6 6l12 12")
        XCTAssertEqual(paths.count, 2)
        XCTAssertEqual(paths[0], [IconPoint(x: 18, y: 6), IconPoint(x: 6, y: 18)])
        XCTAssertEqual(paths[1], [IconPoint(x: 6, y: 6), IconPoint(x: 18, y: 18)])
    }

    func testHorizontalVerticalAndClose() {
        let paths = flatten("M6 5h2v14H6z")
        XCTAssertEqual(paths, [[
            IconPoint(x: 6, y: 5), IconPoint(x: 8, y: 5), IconPoint(x: 8, y: 19),
            IconPoint(x: 6, y: 19), IconPoint(x: 6, y: 5),
        ]])
    }

    /// The Wi-Fi dot: `M12 20h.01` is a dot, and has to arrive as two points
    /// for a round-capped stroke to draw it.
    func testDotIsTwoPoints() {
        let paths = flatten("M12 20h.01")
        XCTAssertEqual(paths.count, 1)
        XCTAssertEqual(paths[0].count, 2)
        assertNear(paths[0].last, 12.01, 20)
    }

    /// The spinner: `a9 9 0 1 1-6.2-8.56`, flags with no separator and a
    /// negative number run into the flag. Every point is on the circle.
    func testArcFlagsRunIntoNumbers() {
        let paths = flatten("M21 12a9 9 0 1 1-6.2-8.56")
        XCTAssertEqual(paths.count, 1)
        let points = paths[0]
        XCTAssertGreaterThan(points.count, 20)
        assertNear(points.first, 21, 12)
        assertNear(points.last, 14.8, 3.44)
        for p in points {
            let r = ((p.x - 12) * (p.x - 12) + (p.y - 12) * (p.y - 12)).squareRoot()
            XCTAssertEqual(r, 9, accuracy: 0.02)
        }
    }

    /// Large-arc and sweep pick one of four arcs; the power glyph is the long
    /// way round the bottom.
    func testLargeArcGoesTheLongWay() {
        let points = flatten("M6.4 6.6a8 8 0 1 0 11.2 0")[0]
        let lowest = points.map(\.y).max() ?? 0
        XCTAssertGreaterThan(lowest, 17)
        assertNear(points.last, 17.6, 6.6)
    }

    func testCircleClosesOnItself() {
        let points = flatten(IconShape.circle(cx: 6, cy: 18, r: 3).pathData)[0]
        assertNear(points.first, 3, 18)
        assertNear(points.last, 3, 18)
        for p in points {
            let r = ((p.x - 6) * (p.x - 6) + (p.y - 18) * (p.y - 18)).squareRoot()
            XCTAssertEqual(r, 3, accuracy: 0.02)
        }
    }

    func testRoundedRectStaysInsideItsBox() {
        let points = flatten(IconShape.rect(x: 1, y: 1, width: 21, height: 12, rx: 3).pathData)[0]
        for p in points {
            XCTAssertGreaterThanOrEqual(p.x, 1 - 0.001)
            XCTAssertLessThanOrEqual(p.x, 22 + 0.001)
            XCTAssertGreaterThanOrEqual(p.y, 1 - 0.001)
            XCTAssertLessThanOrEqual(p.y, 13 + 0.001)
        }
        assertNear(points.first, 4, 1)
        assertNear(points.last, 4, 1)
    }

    /// Cubic, smooth cubic and the flame's mix of them end where they say.
    func testCurvesEndOnTheirEndpoints() {
        let flame = "M12 2c1 3.5-1.6 5.3-2.9 7.3C7.7 11.4 7 13 7 14.6 7 18.1 9.3 21 12 21s5-2.4 5-5.8"
        let points = flatten(flame)[0]
        assertNear(points.first, 12, 2)
        assertNear(points.last, 17, 15.2)
        let quad = flatten("M0 0Q5 10 10 0T20 0")[0]
        assertNear(quad.last, 20, 0)
        // The reflected control point puts T's bump below the axis.
        XCTAssertLessThan(quad.map(\.y).min() ?? 0, -1)
    }

    /// The Wi-Fi fan's ink runs from the top arc's crest (y≈5, less the
    /// stroke) to the dot (20, plus it), so it sits half a unit low.
    func testInkOffsetCentresTheFan() {
        let fan: [IconShape] = [.path("M5 12.55a11 11 0 0 1 14 0M8.5 16.05a6 6 0 0 1 7 0M2 8.82a15 15 0 0 1 20 0M12 20h.01")]
        let shift = IconPathCache.inkOffset(fan, strokeWidth: 2)
        XCTAssertEqual(shift.x, 0, accuracy: 0.05)
        XCTAssertEqual(shift.y, -0.5, accuracy: 0.05)
        // A speaker with no waves leans left; centring moves it right.
        let speaker = IconPathCache.inkOffset([.path("M11 5 6 9H2v6h4l5 4Z")], strokeWidth: 2)
        XCTAssertEqual(speaker.x, 12 - (1 + 12) / 2, accuracy: 0.05)
        // A glyph already centred stays put.
        let cross = IconPathCache.inkOffset([.path("M18 6 6 18M6 6l12 12")], strokeWidth: 2)
        XCTAssertEqual(cross.x, 0, accuracy: 0.001)
        XCTAssertEqual(cross.y, 0, accuracy: 0.001)
    }

    func testGarbageDrawsWhatParsed() {
        let paths = flatten("M1 1L5 5L")
        XCTAssertEqual(paths, [[IconPoint(x: 1, y: 1), IconPoint(x: 5, y: 5)]])
        XCTAssertEqual(flatten(""), [])
        XCTAssertEqual(flatten("Z 1 2"), [])
    }
}
