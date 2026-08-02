import XCTest

@testable import LavaText

/// Editing logic is pure, so it is tested without a window, a font, or a GPU.
/// The grapheme cases are the point: they are what a byte- or character-index
/// implementation gets wrong, and they are invisible until a user pastes an
/// emoji into a field.
final class TextEditingStateTests: XCTestCase {

    private func offset(_ s: TextEditingState) -> Int {
        s.text.distance(from: s.text.startIndex, to: s.focus)
    }

    // MARK: Movement

    func testMoveRightAndLeftByCharacter() {
        var s = TextEditingState("abc")
        s.moveRight(); XCTAssertEqual(offset(s), 1)
        s.moveRight(); XCTAssertEqual(offset(s), 2)
        s.moveLeft();  XCTAssertEqual(offset(s), 1)
    }

    func testMovementClampsAtBothEnds() {
        var s = TextEditingState("ab")
        s.moveLeft()
        XCTAssertEqual(offset(s), 0, "left at start must not underflow")
        s.moveToEnd()
        s.moveRight()
        XCTAssertEqual(offset(s), 2, "right at end must not overflow")
    }

    /// One arrow press crosses a whole emoji ZWJ sequence, not a code unit.
    func testArrowKeyCrossesGraphemeCluster() {
        let family = "👨‍👩‍👧"  // several scalars, one Character
        var s = TextEditingState("a\(family)b")
        s.moveRight()
        s.moveRight()
        XCTAssertEqual(offset(s), 2)
        XCTAssertEqual(String(s.text[s.text.startIndex..<s.focus]), "a\(family)")
    }

    func testCombiningAccentIsOneCharacter() {
        var s = TextEditingState("e\u{0301}x")  // "é" as e + combining acute
        s.moveRight()
        XCTAssertEqual(offset(s), 1)
        s.deleteBackward()
        XCTAssertEqual(s.text, "x", "backspace must remove the whole grapheme")
    }

    // MARK: Selection

    func testPlainArrowCollapsesSelectionWithoutMoving() {
        var s = TextEditingState("abcdef")
        s.moveRight(); s.moveRight()
        s.moveRight(extending: true); s.moveRight(extending: true)
        XCTAssertEqual(s.selectedText, "cd")

        s.moveLeft()
        XCTAssertFalse(s.hasSelection)
        XCTAssertEqual(offset(s), 2, "collapses to selection start, does not step past it")
    }

    func testSelectionIsDocumentOrderedWhenDraggedBackwards() {
        var s = TextEditingState("abcdef")
        s.moveToEnd()
        s.moveLeft(extending: true)
        s.moveLeft(extending: true)
        XCTAssertEqual(s.selectedText, "ef", "backwards drag still yields ordered range")
    }

    func testDeleteReplacesSelection() {
        var s = TextEditingState("hello world")
        s.selectAll()
        s.deleteBackward()
        XCTAssertEqual(s.text, "")
        XCTAssertFalse(s.hasSelection)
    }

    // MARK: Insertion

    func testInsertAtCaret() {
        var s = TextEditingState("ac")
        s.moveRight()
        s.insert("b")
        XCTAssertEqual(s.text, "abc")
        XCTAssertEqual(offset(s), 2, "caret lands after inserted text")
    }

    func testInsertOverSelectionReplacesIt() {
        var s = TextEditingState("hello")
        s.selectAll()
        s.insert("bye")
        XCTAssertEqual(s.text, "bye")
        XCTAssertEqual(offset(s), 3)
    }

    func testInsertMultiByteKeepsCaretOnBoundary() {
        var s = TextEditingState("ab")
        s.moveRight()
        s.insert("é")
        XCTAssertEqual(s.text, "aéb")
        XCTAssertEqual(offset(s), 2, "caret counted in characters, not bytes")
    }

    // MARK: Deletion

    func testDeleteForwardAtEndIsNoop() {
        var s = TextEditingState("ab")
        s.moveToEnd()
        s.deleteForward()
        XCTAssertEqual(s.text, "ab")
    }

    func testDeleteBackwardAtStartIsNoop() {
        var s = TextEditingState("ab")
        s.deleteBackward()
        XCTAssertEqual(s.text, "ab")
    }

    /// Stale visual rows after a length-changing edit used to survive and make
    /// UI code (`rowTexts` / `scrollToCaretX`) walk past `endIndex`.
    func testReplaceInvalidatesVisualRows() {
        var s = TextEditingState("hello world")
        s.setVisualRows([0..<5, 6..<11])
        XCTAssertNotNil(s.visualRows)

        s.selectAll()
        s.deleteBackward()
        XCTAssertEqual(s.text, "")
        XCTAssertNil(s.visualRows, "must fall back to live .logical(text)")
        // layout still answers without trapping
        XCTAssertEqual(s.layout.count, 1)
        XCTAssertEqual(s.layout.rows[0], 0..<0)
    }

    func testDeleteSelectionInvalidatesVisualRowsAndLayoutFitsText() {
        var s = TextEditingState("line one\nline two\nline three")
        s.setVisualRows(VisualLayout.logicalRows(s.text))
        XCTAssertEqual(s.layout.count, 3)

        // Select "line two\n"
        s.setCursor(s.index(atOffset: 9))
        s.setCursor(s.index(atOffset: 18), extending: true)
        s.deleteBackward()

        XCTAssertNil(s.visualRows)
        let live = s.layout
        let end = s.text.count
        for row in live.rows {
            XCTAssertLessThanOrEqual(row.upperBound, end)
            XCTAssertGreaterThanOrEqual(row.lowerBound, 0)
        }
    }

    func testUndoAlsoInvalidatesVisualRows() {
        var s = TextEditingState("abc")
        s.setVisualRows([0..<3])
        s.moveToEnd()
        s.insert("d")
        XCTAssertNil(s.visualRows)
        s.setVisualRows([0..<4])
        XCTAssertTrue(s.undo())
        XCTAssertNil(s.visualRows)
        XCTAssertEqual(s.text, "abc")
    }

    // MARK: Word movement

    func testWordRightStopsAtWordEnds() {
        var s = TextEditingState("foo bar baz")
        s.moveWordRight(); XCTAssertEqual(offset(s), 3)
        s.moveWordRight(); XCTAssertEqual(offset(s), 7)
    }

    func testWordLeftSkipsSeparators() {
        var s = TextEditingState("foo bar")
        s.moveToEnd()
        s.moveWordLeft()
        XCTAssertEqual(offset(s), 4, "start of 'bar'")
        s.moveWordLeft()
        XCTAssertEqual(offset(s), 0, "crosses the space to start of 'foo'")
    }

    func testIdentifierCharactersCountAsOneWord() {
        var s = TextEditingState("snake_case_1 next")
        s.moveWordRight()
        XCTAssertEqual(offset(s), 12, "underscores and digits do not split the word")
    }

    func testDeleteWordBackward() {
        var s = TextEditingState("foo bar")
        s.moveToEnd()
        s.deleteWordBackward()
        XCTAssertEqual(s.text, "foo ")
    }

    // MARK: External replacement

    func testSetTextResetsCursorToEndByDefault() {
        var s = TextEditingState("old")
        s.setText("brand new")
        XCTAssertEqual(s.text, "brand new")
        XCTAssertEqual(offset(s), 9)
    }

    func testSetTextKeepingCursorClampsWhenShorter() {
        var s = TextEditingState("aaaaaa")
        s.moveToEnd()
        s.setText("ab", keepingCursor: true)
        XCTAssertEqual(offset(s), 2, "cursor clamped into the shorter buffer")
    }
}

// MARK: - Word selection (double-click)

extension TextEditingStateTests {
    private func index(_ s: TextEditingState, _ n: Int) -> String.Index {
        s.text.index(s.text.startIndex, offsetBy: n)
    }

    func testSelectWordFromInsideWord() {
        var s = TextEditingState("foo bar baz")
        s.selectWord(at: index(s, 5))  // inside "bar"
        XCTAssertEqual(s.selectedText, "bar")
    }

    func testSelectWordAtWordStart() {
        var s = TextEditingState("foo bar")
        s.selectWord(at: index(s, 4))
        XCTAssertEqual(s.selectedText, "bar")
    }

    /// Double-clicking a gap selects the gap, not a neighbouring word — the
    /// selection must never silently jump somewhere the user didn't click.
    func testSelectWordOnSeparatorRunSelectsTheRun() {
        var s = TextEditingState("foo   bar")
        s.selectWord(at: index(s, 4))
        XCTAssertEqual(s.selectedText, "   ")
    }

    func testSelectWordKeepsIdentifiersWhole() {
        var s = TextEditingState("call snake_case_1 now")
        s.selectWord(at: index(s, 8))
        XCTAssertEqual(s.selectedText, "snake_case_1")
    }

    func testSelectWordAtEndOfBuffer() {
        var s = TextEditingState("foo bar")
        s.selectWord(at: s.text.endIndex)
        XCTAssertEqual(s.selectedText, "bar", "end index has no char under it; look left")
    }

    func testSelectWordOnEmptyBufferIsEmpty() {
        var s = TextEditingState("")
        s.selectWord(at: s.text.startIndex)
        XCTAssertFalse(s.hasSelection)
    }
}
