import CxxCanvas
import XCTest

@testable import LavaUI

/// Nothing lights up under a pointer that is carrying something. Hover tints
/// are the renderer's, so the only lever the client has is to leave them out
/// of the frames it draws while a drag gesture is running.
final class DragHoverTests: XCTestCase {
    private func hoverTints() throws -> [UInt32] {
        let editor = try XCTUnwrap(Editor.openClient(width: 200, height: 60))
        _ = FontStore.bootstrap(assetsRoot: LavaResources.root, pixelSize: 16, into: editor)
        let host = LayoutHost()
        host.setRoot(
            VStack(width: .pt(200), height: .pt(60), alignment: .start) {
                Text("row").hoverBackground(Color(r: 0.3, g: 0.3, b: 0.3))
            }
        )
        _ = host.calculateLayout(width: 200, height: 60)
        let root = try XCTUnwrap(host.rootNode)
        let list = DrawList(editor: editor)
        list.clear()
        list.emitTree(root, viewportW: 200, viewportH: 60)
        return (0..<list.commandCount).compactMap { list.emitted(at: $0) }
            .filter { $0.kind == .endNode }
            .map(\.color)
    }

    func testHoverTintsAreLeftOutWhileADragRuns() throws {
        XCTAssertTrue(try hoverTints().contains { $0 != 0 }, "a row that hovers, to begin with")

        let id = NodeID.generate()
        DragGestureRouter.register(id, DragGestureEntry(minimumDistance: 1) { _ in })
        defer { DragGestureRouter.unregisterAll(ids: [id]) }
        DragGestureRouter.press(source: id, x: 0, y: 0)
        XCTAssertTrue(DragGestureRouter.move(x: 20, y: 0, captured: false))
        XCTAssertEqual(try hoverTints().filter { $0 != 0 }, [])

        XCTAssertTrue(DragGestureRouter.release(x: 20, y: 0))
        XCTAssertTrue(try hoverTints().contains { $0 != 0 }, "and back once it ends")
    }

    func testHoverTintsAreLeftOutWhileAScrollbarThumbIsHeld() throws {
        ScrollbarDrag.begin(NodeID.generate(), axis: .vertical)
        XCTAssertEqual(try hoverTints().filter { $0 != 0 }, [])
        ScrollbarDrag.end()
        XCTAssertTrue(try hoverTints().contains { $0 != 0 })
    }
}
