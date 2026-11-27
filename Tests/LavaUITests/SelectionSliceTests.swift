import XCTest
@testable import LavaUI

/// The rounded outline of an editor selection, one row's band at a time.
final class SelectionSliceTests: XCTestCase {
    private func slice(_ span: (Float, Float), above: (Float, Float)? = nil,
                       below: (Float, Float)? = nil) -> (left: [(x: Float, y: Float)],
                                                         right: [(x: Float, y: Float)],
                                                         joinsBelow: Bool) {
        DrawList.selectionSlice(
            top: 0, height: 20, span: (span.0, span.1),
            above: above.map { (lo: $0.0, hi: $0.1) }, below: below.map { (lo: $0.0, hi: $0.1) },
            radius: 4
        )
    }

    func testLoneRowIsARoundedRect() {
        let s = slice((10, 50))
        XCTAssertEqual(s.left.first?.x ?? 0, 14, accuracy: 1e-4)   // corner pulled in
        XCTAssertEqual(s.left.last?.x ?? 0, 14, accuracy: 1e-4)
        XCTAssertEqual(s.right.first?.x ?? 0, 46, accuracy: 1e-4)
        XCTAssertEqual(s.left[s.left.count / 2].x, 10, accuracy: 1e-4)  // straight side
        XCTAssertFalse(s.joinsBelow)
        XCTAssertEqual(s.left.map(\.y), s.right.map(\.y))
        XCTAssertEqual(s.left.first?.y, 0)
        XCTAssertEqual(s.left.last?.y, 20)
    }

    /// The row above reaches further left: this row's top-left is the
    /// inside of a turn, and curves outward to meet it.
    func testInsideCornerFillsOutward() {
        let s = slice((10, 50), above: (0, 50))
        XCTAssertEqual(s.left.first?.x ?? 0, 6, accuracy: 1e-4)
        // Flush with the row above on the right: no corner there.
        XCTAssertEqual(s.right.first?.x ?? 0, 50, accuracy: 1e-4)
    }

    /// Both rows have a corner at a narrow step; each takes half of it.
    func testNarrowStepSharesTheDistance() {
        let row = slice((10, 50), above: (7, 50))
        XCTAssertEqual(row.left.first?.x ?? 0, 8.5, accuracy: 1e-4)
        let up = DrawList.selectionSlice(top: -20, height: 20, span: (lo: 7, hi: 50), above: nil,
                                         below: (lo: 10, hi: 50), radius: 4)
        XCTAssertTrue(up.joinsBelow)
        // The row above's bottom-left is an outer corner of the same 1.5 px.
        XCTAssertEqual(up.left.last?.x ?? 0, 8.5, accuracy: 1e-4)
    }

    /// Rows that do not overlap are separate shapes, each fully rounded.
    func testDisjointRowsDoNotJoin() {
        let s = slice((10, 20), above: (30, 60), below: (40, 60))
        XCTAssertFalse(s.joinsBelow)
        XCTAssertEqual(s.left.first?.x ?? 0, 14, accuracy: 1e-4)
        XCTAssertEqual(s.right.last?.x ?? 0, 16, accuracy: 1e-4)
    }

    /// A span narrower than two radii keeps its corners inside it.
    func testTinySpanStaysInside() {
        let s = slice((10, 13))
        for (l, r) in zip(s.left, s.right) {
            XCTAssertGreaterThanOrEqual(r.x, l.x - 1e-4)
        }
    }
}
