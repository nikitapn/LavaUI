import XCTest

@testable import LavaText

/// Undo is where "edits as operations" pays off, and where coalescing rules
/// are easy to get subtly wrong. Coalescing here is time-free on purpose, so
/// every one of these is deterministic — no sleeps, no flakiness.
final class UndoTests: XCTestCase {

    private func offset(_ s: TextEditingState) -> Int {
        s.text.distance(from: s.text.startIndex, to: s.focus)
    }

    private func type(_ s: inout TextEditingState, _ string: String) {
        for ch in string { s.insert(String(ch)) }
    }

    // MARK: Basics

    func testUndoRestoresText() {
        var s = TextEditingState("hello")
        s.moveToEnd()
        s.insert("!")
        XCTAssertEqual(s.text, "hello!")
        XCTAssertTrue(s.undo())
        XCTAssertEqual(s.text, "hello")
    }

    func testRedoReappliesText() {
        var s = TextEditingState("hello")
        s.moveToEnd()
        s.insert("!")
        s.undo()
        XCTAssertTrue(s.redo())
        XCTAssertEqual(s.text, "hello!")
    }

    func testUndoOnEmptyHistoryReportsFailure() {
        var s = TextEditingState("x")
        XCTAssertFalse(s.undo())
        XCTAssertFalse(s.canUndo)
    }

    /// Undo must put the caret back where it was, not merely fix the text.
    func testUndoRestoresCursor() {
        var s = TextEditingState("abcdef")
        s.moveToEnd()
        s.moveLeft(extending: true)
        s.moveLeft(extending: true)   // "ef" selected
        s.insert("Z")
        XCTAssertEqual(s.text, "abcdZ")

        s.undo()
        XCTAssertEqual(s.text, "abcdef")
        XCTAssertEqual(s.selectedText, "ef", "selection restored, not just text")
    }

    // MARK: Coalescing

    func testTypingAWordUndoesAsOneStep() {
        var s = TextEditingState("")
        type(&s, "hello")
        XCTAssertEqual(s.text, "hello")
        s.undo()
        XCTAssertEqual(s.text, "", "five keystrokes are one user action")
    }

    func testWhitespaceBreaksTheUndoRun() {
        var s = TextEditingState("")
        type(&s, "hello world")
        s.undo()
        XCTAssertEqual(s.text, "hello ", "break falls after the space")
        s.undo()
        XCTAssertEqual(s.text, "")
    }

    func testNonAdjacentInsertionsDoNotCoalesce() {
        var s = TextEditingState("ab")
        s.moveToEnd()
        s.insert("X")          // "abX"
        s.moveToStart()
        s.insert("Y")          // "YabX"
        XCTAssertEqual(s.text, "YabX")
        s.undo()
        XCTAssertEqual(s.text, "abX", "a caret jump ends the run")
    }

    func testConsecutiveBackspacesUndoAsOneStep() {
        var s = TextEditingState("hello")
        s.moveToEnd()
        s.deleteBackward()
        s.deleteBackward()
        s.deleteBackward()
        XCTAssertEqual(s.text, "he")
        s.undo()
        XCTAssertEqual(s.text, "hello", "a backspace run is one action")
    }

    func testInsertionAfterDeletionDoesNotCoalesce() {
        var s = TextEditingState("abc")
        s.moveToEnd()
        s.deleteBackward()     // "ab"
        s.insert("Z")          // "abZ"
        s.undo()
        XCTAssertEqual(s.text, "ab", "direction change ends the run")
    }

    // MARK: Redo invalidation

    func testNewEditClearsRedoBranch() {
        var s = TextEditingState("")
        type(&s, "abc")
        s.undo()
        XCTAssertTrue(s.canRedo)

        s.insert("Z")
        XCTAssertFalse(s.canRedo, "the future that redo described no longer exists")
    }

    // MARK: Multi-step and graphemes

    func testUndoWalksBackThroughSeveralSteps() {
        var s = TextEditingState("")
        type(&s, "one ")
        type(&s, "two ")
        type(&s, "three")
        s.undo(); XCTAssertEqual(s.text, "one two ")
        s.undo(); XCTAssertEqual(s.text, "one ")
        s.undo(); XCTAssertEqual(s.text, "")
    }

    /// Offsets are character counts, so a multi-byte grapheme must not shift
    /// the recorded position of a later edit.
    func testUndoAcrossMultiByteCharacters() {
        var s = TextEditingState("héllo")
        s.moveToEnd()
        s.insert("!")
        s.undo()
        XCTAssertEqual(s.text, "héllo")
        XCTAssertEqual(offset(s), 5)
    }

    func testUndoOfEmojiDeletionRestoresWholeCluster() {
        let family = "👨‍👩‍👧"
        var s = TextEditingState("a\(family)b")
        s.moveToEnd()
        s.deleteBackward()   // "b"
        s.deleteBackward()   // the whole family cluster
        XCTAssertEqual(s.text, "a")
        s.undo()
        XCTAssertEqual(s.text, "a\(family)b")
    }

    // MARK: External replacement

    func testSetTextClearsHistory() {
        var s = TextEditingState("abc")
        s.moveToEnd()
        s.insert("d")
        XCTAssertTrue(s.canUndo)

        s.setText("something else")
        XCTAssertFalse(
            s.canUndo,
            "history from a buffer that was replaced wholesale is meaningless"
        )
    }
}
