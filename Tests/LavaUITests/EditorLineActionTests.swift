import LavaText
import XCTest
@testable import LavaUI

final class EditorLineActionTests: XCTestCase {
    func testHintRowsShareDocumentAndPointerGeometry() {
        let leaf = LeafNode(kind: .editor, label: "Editor", width: .pt(300), height: .pt(80))
        leaf.editing = TextEditingState("a\nb\nc\nd")
        leaf.seedLogicalRows()
        let hint = EditorLineAction(gutterPlay: false, hint: "Run") {}
        let button = EditorLineAction(gutterPlay: true, hint: "") {}
        leaf.lineActions = [0: [hint], 1: [button], 2: [hint, hint]]
        // hint, a, b, hint, c, d. Multiple labels share a single hint row.
        XCTAssertEqual((0...4).map { leaf.documentY(ofRow: $0, lineHeight: 10) }, [10, 20, 40, 50, 60])
        XCTAssertEqual((0..<6).map { leaf.row(atDocumentY: Double($0 * 10 + 5), lineHeight: 10) }, [0, 0, 1, 2, 2, 3])
        leaf.scrollY = 30
        XCTAssertEqual(leaf.row(atScreenY: 2, lineHeight: 10), 2)
        XCTAssertEqual(leaf.screenY(ofRow: 2, lineHeight: 10), 10)
        leaf.lineActions = [:]
        XCTAssertEqual(leaf.documentY(ofRow: 4, lineHeight: 10), 40)
        XCTAssertEqual(leaf.actionGutterWidth, 0)
    }
}
