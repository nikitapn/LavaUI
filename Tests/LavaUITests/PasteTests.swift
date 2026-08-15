import XCTest

@testable import LavaUI

/// Pasting into the text controls, driven the way a key press reaches them:
/// clipboard → `FocusManager` → the shared `handleKey` both controls use.
final class PasteTests: XCTestCase {
    override func tearDown() {
        ClipboardBridge.reader = nil
        ClipboardBridge.writer = nil
        super.tearDown()
    }

    private func node(
        labelled label: String, in root: any AnyViewNode
    ) -> (any AnyViewNode)? {
        if root.label.hasPrefix(label) { return root }
        for child in root.childNodes {
            if let found = node(labelled: label, in: child) { return found }
        }
        return nil
    }

    /// Mounts `view`, focuses its leaf, and pastes `clipboard` into it.
    private func paste<V: View>(
        _ clipboard: String, into view: V, labelled label: String,
        binding: Binding<String>
    ) throws -> String {
        ClipboardBridge.reader = { clipboard }
        let host = LayoutHost()
        host.setRoot(view)
        _ = host.calculateLayout(width: 400, height: 200)

        let root = try XCTUnwrap(host.rootNode)
        let leaf = try XCTUnwrap(node(labelled: label, in: root) as? LeafNode)
        leaf.focusSelf(binding: binding, onSubmit: nil)
        let handled = FocusManager.handle(
            KeyEvent(key: KeyCode.v, mods: KeyMods.control)
        )
        XCTAssertTrue(handled, "Ctrl+V should be consumed by the focused control")
        return leaf.editing.text
    }

    func testEditorKeepsPastedLineBreaks() throws {
        var text = ""
        let binding = Binding(get: { text }, set: { text = $0 })
        let pasted = try paste(
            "one\ntwo\nthree",
            into: EditorView(text: binding), labelled: "EditorView",
            binding: binding
        )

        XCTAssertEqual(pasted, "one\ntwo\nthree")
        // Through the binding as well, not just inside the control.
        XCTAssertEqual(text, "one\ntwo\nthree")
    }

    func testMultilineFieldKeepsPastedLineBreaks() throws {
        var text = ""
        let binding = Binding(get: { text }, set: { text = $0 })
        let pasted = try paste(
            "one\ntwo",
            into: TextField(text: binding, multiline: true),
            labelled: "TextField", binding: binding
        )

        XCTAssertEqual(pasted, "one\ntwo")
    }

    /// A single-line field has nowhere to put a break, so it becomes a space
    /// rather than a character that moves the caret somewhere invisible.
    func testSingleLineFieldFlattensPastedLineBreaks() throws {
        var text = ""
        let binding = Binding(get: { text }, set: { text = $0 })
        let pasted = try paste(
            "one\ntwo",
            into: TextField(text: binding), labelled: "TextField",
            binding: binding
        )

        XCTAssertEqual(pasted, "one two")
    }

    /// CRLF is what a browser or a Windows tool leaves on the clipboard, and a
    /// surviving CR costs the editor its ASCII soft-wrap fast path.
    func testCarriageReturnsAreNormalised() throws {
        var text = ""
        let binding = Binding(get: { text }, set: { text = $0 })
        let pasted = try paste(
            "one\r\ntwo\rthree",
            into: EditorView(text: binding), labelled: "EditorView",
            binding: binding
        )

        XCTAssertEqual(pasted, "one\ntwo\nthree")
        XCTAssertFalse(pasted.contains("\r"))
    }

    func testSingleLineFieldDropsCarriageReturnsToo() throws {
        var text = ""
        let binding = Binding(get: { text }, set: { text = $0 })
        let pasted = try paste(
            "one\r\ntwo",
            into: TextField(text: binding), labelled: "TextField",
            binding: binding
        )

        XCTAssertEqual(pasted, "one two")
    }

    /// One edit, so one undo step — not one per pasted line.
    func testAPasteUndoesInOneStep() throws {
        var text = ""
        let binding = Binding(get: { text }, set: { text = $0 })
        ClipboardBridge.reader = { "one\ntwo\nthree" }
        let host = LayoutHost()
        host.setRoot(EditorView(text: binding))
        _ = host.calculateLayout(width: 400, height: 200)

        let root = try XCTUnwrap(host.rootNode)
        let leaf = try XCTUnwrap(node(labelled: "EditorView", in: root) as? LeafNode)
        leaf.focusSelf(binding: binding, onSubmit: nil)
        _ = FocusManager.handle(KeyEvent(key: KeyCode.v, mods: KeyMods.control))
        XCTAssertEqual(leaf.editing.text, "one\ntwo\nthree")

        _ = FocusManager.handle(KeyEvent(key: KeyCode.z, mods: KeyMods.control))
        XCTAssertEqual(leaf.editing.text, "")
    }

    /// The caret lands after the pasted text, so typing continues where the
    /// paste ended rather than at the top of it.
    func testCaretFollowsThePaste() throws {
        var text = ""
        let binding = Binding(get: { text }, set: { text = $0 })
        ClipboardBridge.reader = { "one\ntwo" }
        let host = LayoutHost()
        host.setRoot(EditorView(text: binding))
        _ = host.calculateLayout(width: 400, height: 200)

        let root = try XCTUnwrap(host.rootNode)
        let leaf = try XCTUnwrap(node(labelled: "EditorView", in: root) as? LeafNode)
        leaf.focusSelf(binding: binding, onSubmit: nil)
        _ = FocusManager.handle(KeyEvent(key: KeyCode.v, mods: KeyMods.control))

        XCTAssertEqual(
            leaf.editing.offset(of: leaf.editing.focus), "one\ntwo".utf8.count
        )
    }
}
