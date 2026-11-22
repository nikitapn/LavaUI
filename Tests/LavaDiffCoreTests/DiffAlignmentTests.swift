import XCTest
@testable import LavaDiffCore

final class DiffAlignmentTests: XCTestCase {
    func testInsertionLeavesRoomOnTheOldSide() {
        let alignment = DiffAlignment(TextDiff(old: "a\nb\nc\n", new: "a\nb\nnew\nc\n"))
        XCTAssertEqual(alignment.old.gaps, [.init(line: 2, rows: 1)])
        XCTAssertEqual(alignment.new.gaps, [])
        XCTAssertEqual(alignment.new.changed, [2..<3])
        XCTAssertEqual(alignment.old.changed, [2..<2])
    }

    func testDeletionAtTheEndLeavesRoomBelowTheLastLine() {
        let alignment = DiffAlignment(TextDiff(old: "a\nb\nc\nd\n", new: "a\nb\n"))
        XCTAssertEqual(alignment.new.gaps, [.init(line: 2, rows: 2)])
    }

    func testChangedWordsAreOffsetsIntoTheWholeText() {
        let old = "keep\nlet count = 1\n"
        let new = "keep\nlet amount = 1\n"
        let alignment = DiffAlignment(TextDiff(old: old, new: new))
        XCTAssertEqual(alignment.old.words.map { slice(old, $0) }, ["count"])
        XCTAssertEqual(alignment.new.words.map { slice(new, $0) }, ["amount"])
    }

    func testUnevenReplacementPadsTheShorterSide() {
        let alignment = DiffAlignment(TextDiff(old: "x\none\ny\n", new: "x\n1\n2\n3\ny\n"))
        XCTAssertEqual(alignment.old.gaps, [.init(line: 2, rows: 2)])
        XCTAssertEqual(alignment.new.changed, [1..<4])
    }

    private func slice(_ text: String, _ range: Range<Int>) -> String {
        let a = text.index(text.startIndex, offsetBy: range.lowerBound)
        return String(text[a..<text.index(a, offsetBy: range.count)])
    }
}
