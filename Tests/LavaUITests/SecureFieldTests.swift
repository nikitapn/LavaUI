import XCTest

@testable import LavaUI

/// `TextField(secure:)`: dots on screen, the real text in the binding, and
/// every edit — typing, deleting either way, replacing a selection, pasting —
/// landing at the right place in the text nobody can see.
final class SecureFieldTests: XCTestCase {
    override func tearDown() {
        ClipboardBridge.reader = nil
        ClipboardBridge.writer = nil
        FocusManager.clear()
        super.tearDown()
    }

    private var text = ""

    /// The leaf comes back to be held: its key handlers hold it weakly, as
    /// they do in an app, where the tree is what keeps it alive.
    private func field(_ initial: String = "") throws -> LeafNode {
        text = initial
        let binding = Binding(get: { self.text }, set: { self.text = $0 })
        let host = LayoutHost()
        host.setRoot(TextField(text: binding, secure: true))
        _ = host.calculateLayout(width: 400, height: 200)
        let leaf = try XCTUnwrap(find(host.rootNode))
        leaf.focusSelf(binding: binding, onSubmit: nil)
        return leaf
    }

    private func find(_ root: (any AnyViewNode)?) -> LeafNode? {
        guard let root else { return nil }
        if let leaf = root as? LeafNode, leaf.kind == .textField { return leaf }
        for child in root.childNodes {
            if let found = find(child) { return found }
        }
        return nil
    }

    private func type(_ string: String) {
        for character in string { _ = FocusManager.handle(character: character) }
    }

    private func key(_ key: Int32, _ mods: Int32 = 0) {
        _ = FocusManager.handle(KeyEvent(key: key, mods: mods))
    }

    func testTypingShowsDotsAndBindsTheText() throws {
        let leaf = try field()
        type("pässwörd")
        XCTAssertEqual(text, "pässwörd")
        XCTAssertEqual(leaf.editing.text, String(repeating: "\u{2022}", count: 8))
        XCTAssertFalse(leaf.text.contains("p"), "what is drawn and measured is the dots")
    }

    func testEditsInTheMiddleLandWhereTheCaretIs() throws {
        let leaf = try field()
        type("abcdef")
        key(KeyCode.left); key(KeyCode.left)        // ab cd|ef
        key(KeyCode.backspace)                      // abc|ef
        XCTAssertEqual(text, "abcef")
        key(KeyCode.delete)                         // abc|f
        XCTAssertEqual(text, "abcf")
        type("XY")                                  // abcXY|f
        XCTAssertEqual(text, "abcXYf")
        key(KeyCode.home)
        type("0")
        XCTAssertEqual(text, "0abcXYf")
        XCTAssertEqual(leaf.editing.text.count, 7)
    }

    func testTypingOverASelectionReplacesIt() throws {
        let leaf = try field("secret")
        key(KeyCode.end)
        key(KeyCode.left, KeyMods.shift); key(KeyCode.left, KeyMods.shift)
        type("Z")
        XCTAssertEqual(text, "secrZ")
        XCTAssertEqual(leaf.editing.text.count, 5)
        key(KeyCode.a, KeyMods.control)
        key(KeyCode.backspace)
        XCTAssertEqual(text, "")
    }

    func testPasteGoesInAndNothingComesOut() throws {
        var written: String?
        ClipboardBridge.writer = { written = $0 }
        ClipboardBridge.reader = { "hunter2" }
        let leaf = try field("x")
        key(KeyCode.end)
        key(KeyCode.v, KeyMods.control)
        XCTAssertEqual(text, "xhunter2")
        key(KeyCode.a, KeyMods.control)
        key(KeyCode.c, KeyMods.control)
        key(KeyCode.x, KeyMods.control)
        XCTAssertNil(written, "neither copy nor cut reaches the clipboard")
        XCTAssertEqual(text, "xhunter2", "and cut removes nothing")
        key(KeyCode.z, KeyMods.control)
        XCTAssertEqual(text, "xhunter2", "undo is refused")
        XCTAssertEqual(leaf.editing.text.count, 8)
    }

    func testTypingTheMaskCharacterDoesNotDesync() throws {
        let leaf = try field("ab")
        key(KeyCode.end)
        type("\u{2022}")
        XCTAssertEqual(text, "ab")
        XCTAssertEqual(leaf.editing.text.count, 2)
        type("c")
        XCTAssertEqual(text, "abc")
    }
}
