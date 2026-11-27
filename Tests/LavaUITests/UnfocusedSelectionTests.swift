import XCTest

@testable import LavaUI

/// What a text control's selection does when focus moves to another one:
/// a field drops it, an editor keeps it, and either can be told otherwise.
final class UnfocusedSelectionTests: XCTestCase {
    override func tearDown() {
        FocusManager.clear()
        super.tearDown()
    }

    private var first = "Work"
    private var second = "Game"
    private var source = "let a = 1\nlet b = 2\n"
    private let host = LayoutHost()

    private func leaves(_ root: (any AnyViewNode)?) -> [LeafNode] {
        guard let root else { return [] }
        var found: [LeafNode] = []
        if let leaf = root as? LeafNode, leaf.kind == .textField || leaf.kind == .editor {
            found.append(leaf)
        }
        for child in root.childNodes { found += leaves(child) }
        return found
    }

    private func mount(_ view: some View) -> [LeafNode] {
        host.setRoot(view)
        _ = host.calculateLayout(width: 400, height: 300)
        return leaves(host.rootNode)
    }

    private var firstBinding: Binding<String> { Binding(get: { self.first }, set: { self.first = $0 }) }
    private var secondBinding: Binding<String> { Binding(get: { self.second }, set: { self.second = $0 }) }

    private func select(_ leaf: LeafNode) {
        FocusManager.focus(leaf.id, onKey: { _ in false }, onChar: { _ in false })
        leaf.editing.selectAll()
        XCTAssertTrue(leaf.editing.hasSelection)
    }

    private func moveFocus(to leaf: LeafNode) {
        FocusManager.focus(leaf.id, onKey: { _ in false }, onChar: { _ in false })
    }

    func testAFieldDropsItsSelectionWhenFocusMovesOn() throws {
        let fields = mount(VStack {
            TextField(text: firstBinding)
            TextField(text: secondBinding)
        })
        XCTAssertEqual(fields.count, 2)
        select(fields[0])
        moveFocus(to: fields[1])
        XCTAssertFalse(fields[0].editing.hasSelection)
        // The caret stays where the selection's moving end was.
        XCTAssertEqual(fields[0].editing.focus, fields[0].editing.text.endIndex)
    }

    func testClearingFocusAltogetherDropsItToo() throws {
        let fields = mount(VStack { TextField(text: firstBinding) })
        select(fields[0])
        FocusManager.clear()
        XCTAssertFalse(fields[0].editing.hasSelection)
    }

    func testAFieldCanKeepItsSelection() throws {
        let fields = mount(VStack {
            TextField(text: firstBinding).unfocusedSelection(.kept)
            TextField(text: secondBinding)
        })
        select(fields[0])
        moveFocus(to: fields[1])
        XCTAssertTrue(fields[0].editing.hasSelection)
        XCTAssertEqual(fields[0].selectionColor(focused: false), fields[0].theme.selectionFill)
    }

    func testAnEditorKeepsItsSelectionDimmed() throws {
        let sourceBinding = Binding(get: { self.source }, set: { self.source = $0 })
        let controls = mount(VStack {
            EditorView(text: sourceBinding, visibleLines: 4)
            TextField(text: secondBinding)
        })
        let editor = try XCTUnwrap(controls.first { $0.kind == .editor })
        let field = try XCTUnwrap(controls.first { $0.kind == .textField })
        select(editor)
        moveFocus(to: field)
        XCTAssertTrue(editor.editing.hasSelection)
        XCTAssertEqual(editor.selectionColor(focused: true), editor.theme.selectionFill)
        XCTAssertNotEqual(editor.selectionColor(focused: false), editor.theme.selectionFill)
    }
}
