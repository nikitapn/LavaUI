import XCTest
@testable import LavaDiffCore

final class SideBySideTests: XCTestCase {
    func testChangedLinesPairAndTheRestArePadded() {
        let rows = SideBySide.rows(
            hunks: [DiffHunk(old: 1..<4, new: 1..<2)], oldCount: 5, newCount: 3, context: nil
        )
        XCTAssertEqual(rows.map(\.kind), [.context, .changed, .removed, .removed, .context])
        XCTAssertEqual(rows.map(\.old), [0, 1, 2, 3, 4])
        XCTAssertEqual(rows.map(\.new), [0, 1, nil, nil, 2])
        XCTAssertEqual(rows.map(\.hunk), [nil, 0, 0, 0, nil])
    }

    func testLongUnchangedRunsFold() {
        // One change at line 50 of 100.
        let rows = SideBySide.rows(
            hunks: [DiffHunk(old: 50..<51, new: 50..<51)], oldCount: 100, newCount: 100, context: 3
        )
        // Fold, 3 context, the change, 3 context, fold.
        XCTAssertEqual(rows.count, 9)
        XCTAssertEqual(rows[0].kind, .folded(count: 47))
        XCTAssertEqual(rows[0].old, 0)
        XCTAssertEqual(rows[4].kind, .changed)
        XCTAssertEqual(rows[8].kind, .folded(count: 46))
        XCTAssertEqual(rows[8].old, 54)

        let opened = SideBySide.unfold(rows[8])
        XCTAssertEqual(opened.count, 46)
        XCTAssertEqual(opened.first?.old, 54)
        XCTAssertEqual(opened.last?.new, 99)
    }

    func testShortRunsBetweenHunksStayOpen() {
        let rows = SideBySide.rows(
            hunks: [DiffHunk(old: 2..<3, new: 2..<3), DiffHunk(old: 10..<11, new: 10..<11)],
            oldCount: 12, newCount: 12, context: 3
        )
        // Seven lines between the two changes: hiding one would save nothing.
        XCTAssertFalse(rows.contains { if case .folded = $0.kind { return true } else { return false } })
    }

    func testNoChangesFoldsToOneRow() {
        let rows = SideBySide.rows(hunks: [], oldCount: 40, newCount: 40, context: 3)
        XCTAssertEqual(rows, [DiffRow(kind: .folded(count: 40), old: 0, new: 0)])
    }

    func testIntralineHighlightsTheWord() {
        let ranges = Intraline.ranges(old: "let count = 1", new: "let amount = 1")
        XCTAssertEqual(ranges?.old, [4..<9])
        XCTAssertEqual(ranges?.new, [4..<10])
    }

    func testIntralineBridgesASpaceBetweenChangedWords() {
        let ranges = Intraline.ranges(old: "return a b;", new: "return x y;")
        XCTAssertEqual(ranges?.old, [7..<10])
        XCTAssertEqual(ranges?.new, [7..<10])
    }

    func testIntralineGivesUpOnUnrelatedLines() {
        XCTAssertNil(Intraline.ranges(old: "import Foundation", new: "    return value * 2"))
    }

    func testIntralineCountsCharactersNotBytes() {
        let ranges = Intraline.ranges(old: "név = «a»", new: "név = «b»")
        XCTAssertEqual(ranges?.old, [7..<8])
    }
}
