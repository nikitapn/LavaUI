import XCTest

@testable import LavaText

/// Vertical navigation, with the desired-column cases first — that is the bug
/// the plan singled out, and it is invisible until someone navigates ragged
/// text, so it deserves the most coverage.
final class MultilineTests: XCTestCase {

    private func lineCol(_ s: TextEditingState) -> (Int, Int) {
        (s.lineIndex(of: s.focus), s.column(of: s.focus))
    }

    private func cursor(_ s: inout TextEditingState, line: Int, column: Int) {
        s.setCursor(s.index(line: line, column: column))
    }

    // MARK: Line structure

    func testLineIndexAndColumn() {
        var s = TextEditingState("one\ntwo\nthree")
        cursor(&s, line: 1, column: 2)
        XCTAssertEqual(lineCol(s).0, 1)
        XCTAssertEqual(lineCol(s).1, 2)
    }

    func testTrailingNewlineYieldsAFinalEmptyLine() {
        let s = TextEditingState("a\n")
        XCTAssertEqual(s.lines.count, 2, "the caret can sit after the newline")
    }

    func testIndexAtColumnClampsToLineLength() {
        let s = TextEditingState("long line\nab")
        let i = s.index(line: 1, column: 99)
        XCTAssertEqual(s.column(of: i), 2, "clamped to the short line")
    }

    // MARK: Desired column — the classic trap

    /// Down through a short line and back up must return to the original
    /// column, not the short line's end.
    func testDesiredColumnSurvivesAShortLine() {
        var s = TextEditingState("abcdefgh\nxy\nabcdefgh")
        cursor(&s, line: 0, column: 6)

        s.moveDown()
        XCTAssertEqual(lineCol(s).0, 1)
        XCTAssertEqual(lineCol(s).1, 2, "clamped to the short line while passing through")

        s.moveDown()
        XCTAssertEqual(lineCol(s).1, 6, "original column restored on the long line")
    }

    func testDesiredColumnSurvivesGoingBackUp() {
        var s = TextEditingState("abcdefgh\nxy\nabcdefgh")
        cursor(&s, line: 2, column: 7)
        s.moveUp()
        XCTAssertEqual(lineCol(s).1, 2)
        s.moveUp()
        XCTAssertEqual(lineCol(s).1, 7, "column remembered across the short line")
    }

    /// Any horizontal movement is the user choosing a new column.
    func testHorizontalMovementClearsDesiredColumn() {
        var s = TextEditingState("abcdefgh\nxy\nabcdefgh")
        cursor(&s, line: 0, column: 6)
        s.moveDown()            // column clamps to 2
        s.moveLeft()            // now at column 1, and the memory is dropped
        s.moveDown()
        XCTAssertEqual(lineCol(s).1, 1, "new column sticks after a horizontal move")
    }

    func testEditingClearsDesiredColumn() {
        var s = TextEditingState("abcdefgh\nxy\nabcdefgh")
        cursor(&s, line: 0, column: 6)
        s.moveDown()
        s.insert("Z")           // line 1 becomes "xyZ", caret at column 3
        s.moveDown()
        XCTAssertEqual(lineCol(s).1, 3, "the edit set a new column")
    }

    // MARK: Edges

    func testUpOnFirstLineGoesToBufferStart() {
        var s = TextEditingState("abc\ndef")
        cursor(&s, line: 0, column: 2)
        s.moveUp()
        XCTAssertEqual(s.focus, s.text.startIndex)
    }

    func testDownOnLastLineGoesToBufferEnd() {
        var s = TextEditingState("abc\ndef")
        cursor(&s, line: 1, column: 1)
        s.moveDown()
        XCTAssertEqual(s.focus, s.text.endIndex)
    }

    func testVerticalMovementCanExtendSelection() {
        var s = TextEditingState("abcd\nefgh")
        cursor(&s, line: 0, column: 2)
        s.moveDown(extending: true)
        XCTAssertEqual(s.selectedText, "cd\nef")
    }

    // MARK: Home / End are per line

    func testHomeAndEndActOnTheCurrentLine() {
        var s = TextEditingState("one\ntwo three\nfour")
        cursor(&s, line: 1, column: 4)

        s.moveToLineStart()
        XCTAssertEqual(lineCol(s).0, 1)
        XCTAssertEqual(lineCol(s).1, 0)

        s.moveToLineEnd()
        XCTAssertEqual(lineCol(s).0, 1)
        XCTAssertEqual(lineCol(s).1, 9, "end of 'two three', not of the buffer")
    }

    // MARK: Editing across lines

    func testNewlineInsertionSplitsALine() {
        var s = TextEditingState("abcd")
        cursor(&s, line: 0, column: 2)
        s.insert("\n")
        XCTAssertEqual(s.text, "ab\ncd")
        XCTAssertEqual(lineCol(s).0, 1)
        XCTAssertEqual(lineCol(s).1, 0)
    }

    func testBackspaceAtLineStartJoinsWithThePreviousLine() {
        var s = TextEditingState("ab\ncd")
        cursor(&s, line: 1, column: 0)
        s.deleteBackward()
        XCTAssertEqual(s.text, "abcd")
        XCTAssertEqual(lineCol(s).0, 0)
        XCTAssertEqual(lineCol(s).1, 2)
    }

    func testUndoRestoresALineSplit() {
        var s = TextEditingState("abcd")
        cursor(&s, line: 0, column: 2)
        s.insert("\n")
        s.undo()
        XCTAssertEqual(s.text, "abcd", "multi-line edits inherit undo for free")
    }
}
