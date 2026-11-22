import XCTest
@testable import LavaText

final class RowGapsTests: XCTestCase {
    // Rows 0 1 [gap 2] 2 3 [gap 1] 4, and 3 after the last (row 5).
    private let gaps = RowGaps([(row: 2, count: 2), (row: 4, count: 1), (row: 5, count: 3), (row: 9, count: 0)])

    func testSlots() {
        XCTAssertEqual((0...5).map(gaps.slot(ofRow:)), [0, 1, 4, 5, 7, 11])
        XCTAssertEqual(gaps.total, 6)
        XCTAssertEqual(gaps.before(row: 3), 2)
    }

    func testRowAtSlotRoundTripsAndLandsBelowAGap() {
        let expected: [(Int, Bool)] = [
            (0, false), (1, false), (2, true), (2, true), (2, false), (3, false),
            (4, true), (4, false), (5, true), (5, true), (5, true), (5, false),
        ]
        for (slot, want) in expected.enumerated() {
            let got = gaps.row(atSlot: slot)
            XCTAssertEqual(got.row, want.0, "slot \(slot)")
            XCTAssertEqual(got.isGap, want.1, "slot \(slot)")
        }
        for row in 0...4 { XCTAssertEqual(gaps.row(atSlot: gaps.slot(ofRow: row)).row, row) }
    }

    func testMergesAndSorts() {
        let merged = RowGaps([(row: 4, count: 1), (row: 1, count: 2), (row: 4, count: 2)])
        XCTAssertEqual(merged.entries.map(\.row), [1, 4])
        XCTAssertEqual(merged.entries.map(\.count), [2, 3])
    }

    func testEmptyIsIdentity() {
        let none = RowGaps()
        XCTAssertEqual(none.slot(ofRow: 7), 7)
        XCTAssertEqual(none.row(atSlot: 7).row, 7)
        XCTAssertTrue(none.entries(above: 0...10).isEmpty)
    }

    func testEntriesAbove() {
        XCTAssertEqual(gaps.entries(above: 3...5).map(\.row), [4, 5])
        XCTAssertEqual(gaps.entries(above: 0...2).map(\.row), [2])
    }
}
