import CxxCanvas
import XCTest

@testable import LavaUI

/// A list row's hover chip is the renderer's, drawn inside the row the way
/// the row paints its selection — and a selected row states none, so the
/// selection never shows with a wash over it.
final class HoverInsetTests: XCTestCase {
    private struct Row: View {
        var selected: Bool
        var body: some View {
            Canvas(label: "row", width: .pct(100), height: .pt(24)) { _, _ in }
                .hoverBackground(selected ? .clear : Color(r: 0.3, g: 0.3, b: 0.3))
                .hoverInset(horizontal: 6, vertical: 1)
                .cornerRadius(5)
                .cursor(.pointer)
        }
    }

    private struct Node: Equatable {
        var id: UInt32
        var inset: Float
        var tint: UInt32
        var radius: Float
    }

    /// The row's scene node, as the renderer reads it: `BeginNode`'s id and
    /// packed inset, the matching `EndNode`'s tint and radius.
    private func emit(_ host: LayoutHost, editor: Editor) throws -> Node {
        _ = host.calculateLayout(width: 200, height: 24)
        let list = DrawList(editor: editor)
        list.clear()
        list.emitTree(try XCTUnwrap(host.rootNode), viewportW: 200, viewportH: 24)
        let commands = (0..<list.commandCount).compactMap { list.emitted(at: $0) }
        let begin = try XCTUnwrap(commands.first { $0.kind == .beginNode })
        let end = try XCTUnwrap(commands.first { $0.kind == .endNode })
        return Node(id: begin.param, inset: begin.aux, tint: end.color, radius: end.aux)
    }

    func testInsetTravelsInBeginNodeAndSelectionDropsTheTint() throws {
        let editor = try XCTUnwrap(Editor.openClient(width: 200, height: 24))
        let host = LayoutHost()

        host.setRoot(Row(selected: false))
        let hovering = try emit(host, editor: editor)
        let packed = UInt32(hovering.inset)
        XCTAssertEqual(Float(packed & 0x3ff) / 4, 6)
        XCTAssertEqual(Float(packed >> 10) / 4, 1)
        XCTAssertNotEqual(hovering.tint, 0)
        XCTAssertEqual(hovering.radius, 5)

        // Reconciled onto the same node: still the renderer's hover target,
        // so the pointer image and hover tracking carry on, but no tint.
        host.setRoot(Row(selected: true))
        let selected = try emit(host, editor: editor)
        XCTAssertEqual(selected.id, hovering.id)
        XCTAssertEqual(selected.tint, 0)

        host.setRoot(Row(selected: false))
        XCTAssertEqual(try emit(host, editor: editor), hovering)
    }

    func testPackingStaysExactAtItsLimits() {
        let packed = UInt32(DrawList.packHoverInset(HoverInset(horizontal: 255.75, vertical: 4095.75)))
        XCTAssertEqual(Float(packed & 0x3ff) / 4, 255.75)
        XCTAssertEqual(Float(packed >> 10) / 4, 4095.75)
        XCTAssertEqual(DrawList.packHoverInset(.zero), 0)
        XCTAssertEqual(DrawList.packHoverInset(HoverInset(horizontal: -3, vertical: -1)), 0)
    }
}
