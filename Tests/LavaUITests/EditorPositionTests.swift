import CxxCanvas
import XCTest

@testable import LavaUI

/// `EditorController.position()` / `restore(_:)` — what a document switcher
/// needs to make coming back to a log feel like coming back to it.
final class EditorPositionTests: XCTestCase {
    private static let viewport: (w: Float, h: Float) = (600, 400)

    private var editor: Editor!
    private var host: LayoutHost!

    private static let longText = (1...400).map { "line \($0)" }.joined(separator: "\n")
    private static let shortText = "one\ntwo\nthree"

    override func setUpWithError() throws {
        try super.setUpWithError()
        editor = try XCTUnwrap(
            Editor.openClient(width: Self.viewport.w, height: Self.viewport.h),
            "client engine failed to open"
        )
        XCTAssertNotNil(
            FontStore.bootstrap(assetsRoot: LavaResources.root, pixelSize: 16, into: editor),
            "default face failed to load"
        )
        host = LayoutHost()
    }

    override func tearDown() {
        host = nil
        editor = nil
        super.tearDown()
    }

    private func settle(text: Binding<String>, controller: EditorController) {
        host.setRoot(EditorView(text: text, visibleLines: 10, controller: controller))
        _ = host.calculateLayout(width: Self.viewport.w, height: Self.viewport.h)
        guard let root = host.rootNode else { return }
        let list = DrawList(editor: editor)
        list.clear()
        list.emitTree(root, viewportW: Self.viewport.w, viewportH: Self.viewport.h)
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

    func testPositionReportsWhereTheEditorIs() throws {
        var text = Self.longText
        let controller = EditorController()
        settle(text: Binding(get: { text }, set: { text = $0 }), controller: controller)

        controller.reveal(line: 200)
        let position = try XCTUnwrap(controller.position())

        XCTAssertGreaterThan(position.scrollY, 0, "revealing line 200 scrolled nothing")
        // `reveal` selects the line, so the two ends straddle it.
        XCTAssertLessThan(position.anchor, position.focus)
        let line = try leaf().editing.layout.rows[199]
        XCTAssertEqual(position.anchor, line.lowerBound)
    }

    func testRestoreSurvivesTheBufferBeingSwappedOut() throws {
        var text = Self.longText
        let binding = Binding(get: { text }, set: { text = $0 })
        let controller = EditorController()
        settle(text: binding, controller: controller)

        controller.reveal(line: 200)
        let saved = try XCTUnwrap(controller.position())

        // Away: a different document in the same editor.
        text = Self.shortText
        settle(text: binding, controller: controller)
        XCTAssertEqual(try leaf().scrollY, 0, "a short buffer cannot be scrolled")

        // And back. The restore is queued now and applied by the reconcile
        // that puts the long text back — never before it.
        text = Self.longText
        controller.restore(saved)
        settle(text: binding, controller: controller)

        let restored = try XCTUnwrap(controller.position())
        XCTAssertEqual(restored.scrollY, saved.scrollY, accuracy: 0.5)
        XCTAssertEqual(restored.anchor, saved.anchor)
        XCTAssertEqual(restored.focus, saved.focus)
    }

    /// The buffer a position is restored into is not always the one it came
    /// from — a log gets truncated and rotated between sessions.
    func testRestoreClampsToTheBufferItLandsIn() throws {
        var text = Self.shortText
        let controller = EditorController()
        controller.restore(EditorPosition(scrollX: 0, scrollY: 9_000, anchor: 5_000, focus: 6_000))
        settle(text: Binding(get: { text }, set: { text = $0 }), controller: controller)

        let position = try XCTUnwrap(controller.position())
        XCTAssertEqual(position.anchor, Self.shortText.count)
        XCTAssertEqual(position.focus, Self.shortText.count)
        XCTAssertEqual(position.scrollY, 0, accuracy: 0.01)
    }

    /// A restore queued before the editor exists is held, not dropped — the
    /// same contract `reveal(line:)` has, and what a workspace opened into a
    /// collapsed pane depends on.
    func testRestoreQueuedBeforeMountIsApplledOnMount() throws {
        var text = Self.longText
        let controller = EditorController()
        controller.restore(EditorPosition(scrollX: 0, scrollY: 120, anchor: 30, focus: 30))
        XCTAssertNil(controller.position(), "nothing is mounted yet")

        settle(text: Binding(get: { text }, set: { text = $0 }), controller: controller)
        let position = try XCTUnwrap(controller.position())
        XCTAssertEqual(position.scrollY, 120, accuracy: 0.5)
        XCTAssertEqual(position.focus, 30)
    }
}
