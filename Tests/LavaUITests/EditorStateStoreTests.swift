import CxxCanvas
import XCTest

@testable import LavaUI

/// `EditorStateStore`: undo history, caret and selection kept per document,
/// across switching an editor between documents and across a remount.
final class EditorStateStoreTests: XCTestCase {
    private var editor: Editor!
    private var host: LayoutHost!

    override func setUpWithError() throws {
        try super.setUpWithError()
        editor = try XCTUnwrap(Editor.openClient(width: 600, height: 400), "client engine failed to open")
        XCTAssertNotNil(FontStore.bootstrap(assetsRoot: LavaResources.root, pixelSize: 16, into: editor))
        host = LayoutHost()
    }

    override func tearDown() {
        host = nil
        editor = nil
        super.tearDown()
    }

    private func settle(_ view: some View) {
        host.setRoot(view)
        _ = host.calculateLayout(width: 600, height: 400)
        guard let root = host.rootNode else { return }
        let list = DrawList(editor: editor)
        list.clear()
        list.emitTree(root, viewportW: 600, viewportH: 400)
    }

    private func leaf() throws -> LeafNode {
        func walk(_ node: any AnyViewNode) -> LeafNode? {
            if let leaf = node as? LeafNode, leaf.kind == .editor { return leaf }
            for child in node.childNodes {
                if let hit = walk(child) { return hit }
            }
            return nil
        }
        return try XCTUnwrap(walk(try XCTUnwrap(host.rootNode)))
    }

    func testHistorySurvivesSwitchingDocumentsAndRemounting() throws {
        let store = EditorStateStore()
        let controller = EditorController()
        var texts = ["alpha\n", "beta\n"]
        func editor(_ id: Int) -> EditorView {
            EditorView(
                text: Binding(get: { texts[id] }, set: { texts[id] = $0 }),
                controller: controller, stateStore: store, stateKey: id
            )
        }

        settle(editor(0))
        XCTAssertTrue(controller.insert("ONE ", replacing: 0..<0))
        XCTAssertEqual(texts[0], "ONE alpha\n")
        XCTAssertTrue(try leaf().editing.canUndo)

        // Another document in the same editor: its own, empty history.
        settle(editor(1))
        XCTAssertEqual(try leaf().editing.text, "beta\n")
        XCTAssertFalse(try leaf().editing.canUndo)
        XCTAssertTrue(store.canUndo(0), "switching away threw document 0's history out")

        // Back, and through a different tree, so the editor is a new node.
        settle(VStack { editor(0) })
        let back = try leaf()
        XCTAssertEqual(back.editing.text, "ONE alpha\n")
        XCTAssertTrue(back.editing.canUndo)
        XCTAssertTrue(back.editing.undo())
        XCTAssertEqual(back.editing.text, "alpha\n")
    }

    func testStateWhoseTextChangedElsewhereStartsOver() throws {
        let store = EditorStateStore()
        let controller = EditorController()
        var text = "one\n"
        let binding = Binding(get: { text }, set: { text = $0 })
        settle(EditorView(text: binding, controller: controller, stateStore: store, stateKey: 7))
        XCTAssertTrue(controller.insert("x", replacing: 0..<0))

        // Reloaded from disk while away: the history describes a buffer that
        // is gone, so it is not offered.
        settle(EditorView(text: .constant("other\n"), stateStore: store, stateKey: 8))
        text = "reloaded\n"
        settle(VStack { EditorView(text: binding, controller: controller, stateStore: store, stateKey: 7) })
        XCTAssertEqual(try leaf().editing.text, "reloaded\n")
        XCTAssertFalse(try leaf().editing.canUndo)
    }

    func testRetainForgetsClosedDocuments() {
        let store = EditorStateStore()
        let slot = store.slot(for: 1)
        slot.state = TextEditingState("a")
        slot.isFilled = true
        slot.state.insert("b")
        XCTAssertTrue(store.canUndo(1))
        store.retain([AnyHashable(2)])
        XCTAssertFalse(store.canUndo(1))
    }
}
