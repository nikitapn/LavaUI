import LavaEditorExtensionAPI
import XCTest

final class CommandContextTests: XCTestCase {
    private func context(_ text: String, selection: Range<Int>) -> CommandContext {
        CommandContext(hasDocument: true, documentId: 1, revision: 3, path: "/tmp/a.txt", language: "plain",
                       projectRoot: "", text: text,
                       selectionStartByte: UInt64(selection.lowerBound),
                       selectionEndByte: UInt64(selection.upperBound),
                       caretByte: UInt64(selection.upperBound))
    }

    func testSelectedTextIsByBytes() {
        let c = context("é one two", selection: 3..<6)
        XCTAssertEqual(c.selectedText, "one")
        XCTAssertNil(context("abc", selection: 1..<1).selectedText)
    }

    func testSelectedLinesCoverWholeLinesWithTheirNewline() {
        let text = "zeta\nalpha\nmid\nlast"
        // Inside "alpha" only: that line, newline included.
        XCTAssertEqual(context(text, selection: 6..<7).selectedLines, 5..<11)
        // From inside "alpha" to inside "mid".
        XCTAssertEqual(context(text, selection: 7..<12).selectedLines, 5..<15)
        // Ending at the start of "mid" does not take "mid".
        XCTAssertEqual(context(text, selection: 5..<11).selectedLines, 5..<11)
        // The last line has no newline to take.
        XCTAssertEqual(context(text, selection: 16..<16).selectedLines, 15..<19)
    }

    func testApplyingEditsAnywhereInTheDocument() {
        let c = context("one\ntwo\n", selection: 0..<0)
        XCTAssertEqual(c.applying([SelectionEdit(startByte: 0, endByte: 3, text: "1"),
                                   SelectionEdit(startByte: 8, endByte: 8, text: "three\n")]),
                       "1\ntwo\nthree\n")
        XCTAssertNil(c.applying([SelectionEdit(startByte: 4, endByte: 9, text: "")]))
    }
}
