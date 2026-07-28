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
