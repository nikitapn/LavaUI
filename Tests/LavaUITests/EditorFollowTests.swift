import CxxCanvas
import XCTest

@testable import LavaText
@testable import LavaUI

/// Ctrl+hover and Ctrl+click in a code editor: the word under the pointer is
/// underlined while Control is held, and a Ctrl+click follows it instead of
/// moving the caret.
final class EditorFollowTests: XCTestCase {
    private var editor: Editor!
    private var box = "let alpha = beta\nx"

    override func setUpWithError() throws {
        try super.setUpWithError()
        editor = try XCTUnwrap(Editor.openClient(width: 400, height: 200))
        XCTAssertNotNil(FontStore.bootstrap(assetsRoot: LavaResources.root, pixelSize: 16, into: editor))
        HeldModifiers.clear()
        // Another test's press can still hold the pointer; links stand down
        // while something has it, by design.
        PointerCapture.release()
    }

    override func tearDown() {
        HeldModifiers.clear()
        editor = nil
        super.tearDown()
    }

    private func editorLeaf(_ node: (any AnyViewNode)?) -> LeafNode? {
        guard let node else { return nil }
        if let leaf = node as? LeafNode, leaf.onFollow != nil { return leaf }
        for child in node.childNodes { if let found = editorLeaf(child) { return found } }
        return nil
    }

    func testControlUnderlinesTheWordAndAClickFollowsIt() throws {
        var followed: [Int] = []
        let host = LayoutHost()
        let binding = Binding(get: { self.box }, set: { self.box = $0 })
        host.setRoot(
            VStack(width: .pt(400), height: .pt(200)) {
                EditorView(text: binding, visibleLines: 4, onFollow: { followed.append($0) })
                    .flexGrow(1)
            }
        )
        _ = host.calculateLayout(width: 400, height: 200)
        let leaf = try XCTUnwrap(editorLeaf(host.rootNode))
        let font = try XCTUnwrap(leaf.font ?? FontStore.default)
        let run = font.shapedRun("let alpha = beta")
        let line = "let alpha = beta"
        // Box-local coordinates, gutter included, as the hover walk and a
        // click report them: the middle of a character's glyph on row 0.
        func point(atColumn column: Int) -> (x: Float, y: Float) {
            let a = run.caretX(for: line.index(line.startIndex, offsetBy: column))
            let b = run.caretX(for: line.index(line.startIndex, offsetBy: column + 1))
            return (leaf.gutterWidth + leaf.textInset + (a + b) / 2, leaf.textInset + font.lineHeight / 2)
        }

        let alpha = point(atColumn: 6)
        leaf.updateLink(localX: alpha.x, localY: alpha.y)
        XCTAssertNil(leaf.linkRange, "no link without Control")

        HeldModifiers.noteKey(KeyCode.leftControl, isPress: true, mods: 0)
        leaf.updateLink(localX: alpha.x, localY: alpha.y)
        XCTAssertEqual(leaf.linkRange, 4..<9)
        XCTAssertEqual(leaf.pointerCursor, .pointer)

        let equals = point(atColumn: 10)
        leaf.updateLink(localX: equals.x, localY: equals.y)
        XCTAssertNil(leaf.linkRange, "punctuation is not a link")
        leaf.updateLink(localX: 390, localY: alpha.y)
        XCTAssertNil(leaf.linkRange, "nothing past the end of the line, though the caret would land beside a word")
        XCTAssertNil(leaf.pointerCursor)

        let caretBefore = leaf.editing.focus
        let beta = point(atColumn: 13)
        leaf.onClickLocal?(beta.x, beta.y, 0, 0, KeyMods.control, 0)
        XCTAssertEqual(followed, [13])
        XCTAssertEqual(leaf.editing.focus, caretBefore, "a Ctrl+click follows; it does not move the caret")

        HeldModifiers.noteKey(KeyCode.leftControl, isPress: false, mods: KeyMods.control)
        XCTAssertFalse(HeldModifiers.control, "Control's own key decides, not the bits it reports")
        leaf.updateLink(localX: alpha.x, localY: alpha.y)
        XCTAssertNil(leaf.linkRange)

        leaf.onClickLocal?(beta.x, beta.y, 0, 0, 0, 0)
        PointerCapture.release()
        XCTAssertEqual(followed, [13], "a plain click places the caret")
        XCTAssertNotEqual(leaf.editing.focus, caretBefore)
    }

    func testControlStateFromKeysPressesAndLeaving() {
        XCTAssertTrue(HeldModifiers.noteKey(KeyCode.rightControl, isPress: true, mods: 0))
        XCTAssertFalse(HeldModifiers.noteKey(65, isPress: true, mods: KeyMods.control), "unchanged")
        XCTAssertTrue(HeldModifiers.notePress(mods: 0), "a press reports the truth after a release elsewhere")
        XCTAssertTrue(HeldModifiers.noteKey(65, isPress: true, mods: KeyMods.control))
        XCTAssertTrue(HeldModifiers.clear())
        XCTAssertFalse(HeldModifiers.control)
    }
}
