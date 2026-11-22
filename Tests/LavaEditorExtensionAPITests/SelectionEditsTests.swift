import LavaEditorExtensionAPI
import XCTest

final class SelectionEditsTests: XCTestCase {
    // "a😀bc" starts at byte 10 of the containing document.
    let selection = SelectionSnapshot(documentId: 1, revision: 2, startByte: 10, endByte: 17, text: "a😀bc")

    func testBatchUsesOriginalDocumentOffsets() {
        let edits = [
            SelectionEdit(startByte: 10, endByte: 11, text: ""),
            SelectionEdit(startByte: 15, endByte: 15, text: "λ"),
            SelectionEdit(startByte: 16, endByte: 17, text: "!"),
        ]
        XCTAssertEqual(selection.applying(edits, limit: 8), "😀λb!")
        XCTAssertNil(selection.applying(edits, limit: 7))
    }

    func testRejectsWholeBatchForInvalidLaterRange() {
        let first = SelectionEdit(startByte: 10, endByte: 11, text: "A")
        for (start, end): (UInt64, UInt64) in [(10, 11), (12, 15), (11, 14), (16, 15), (17, 18), (0, 1)] {
            let invalid = SelectionEdit(startByte: start, endByte: end, text: "x")
            XCTAssertNil(selection.applying([first, invalid], limit: 1024))
        }
    }

    func testEmptyReplacementAtSizeLimit() {
        let edit = SelectionEdit(startByte: 10, endByte: 17, text: "")
        XCTAssertEqual(selection.applying([edit], limit: 0), "")
    }
}
