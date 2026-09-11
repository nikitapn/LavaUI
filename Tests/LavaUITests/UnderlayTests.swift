import CxxCanvas
import XCTest

@testable import LavaUI

/// `.underlay { }` paints under its base, at the base's size, and costs the
/// base nothing in layout.
final class UnderlayTests: XCTestCase {
    private typealias Emitted = (kind: DrawKind?, x: Float, y: Float, w: Float, h: Float)

    /// Read back inside, while the editor is alive: a `DrawList` writes into
    /// its editor's buffers, and they go with it.
    private func emit(_ view: some View, width: Float = 300, height: Float = 100)
        throws -> [Emitted]
    {
        let editor = try XCTUnwrap(
            Editor.openClient(width: width, height: height),
            "client engine failed to open"
        )
        XCTAssertNotNil(
            FontStore.bootstrap(assetsRoot: LavaResources.root, pixelSize: 16, into: editor)
        )
        let host = LayoutHost()
        host.setRoot(
            HStack(width: .pt(width), height: .pt(height), alignment: .start) { view }
        )
        _ = host.calculateLayout(width: width, height: height)
        let root = try XCTUnwrap(host.rootNode)
        let list = DrawList(editor: editor)
        list.clear()
        list.emitTree(root, viewportW: width, viewportH: height)
        return (0..<list.commandCount).compactMap { index in
            list.emitted(at: index).map { ($0.kind, $0.x, $0.y, $0.w, $0.h) }
        }
    }

    func testTheLayerPaintsFirstAtTheBasesSize() throws {
        let marker = Color(r: 1, g: 0, b: 0, a: 1)
        let commands = try emit(
            Text("tab")
                .frame(width: .pt(120), height: .pt(30))
                .underlay {
                    Canvas(width: .pct(100), height: .pct(100)) { list, frame in
                        list.rect(x: frame.x, y: frame.y, w: frame.w, h: frame.h, color: marker)
                    }
                }
        )
        let layer = try XCTUnwrap(
            commands.firstIndex { $0.kind == .rect && abs($0.w - 120) < 0.5 },
            "no layer-sized fill in \(commands)"
        )
        let text = try XCTUnwrap(commands.firstIndex { $0.kind == .text })
        XCTAssertEqual(commands[layer].h, 30, accuracy: 0.5)
        XCTAssertLessThan(layer, text, "the layer is under the content, so it is emitted first")
    }

    func testTheBaseMeasuresAsItDidWithoutALayer() throws {
        let host = LayoutHost()
        host.setRoot(
            HStack(width: .pt(300), height: .pt(100), alignment: .start, spacing: 0) {
                Text("a").frame(width: .pt(50), height: .pt(20))
                    .underlay {
                        // Bigger than the base on purpose: an in-flow child
                        // this size would push the sibling along.
                        Canvas(width: .pt(200), height: .pt(80)) { _, _ in }
                    }
                Text("b").frame(width: .pt(50), height: .pt(20))
            }
        )
        let frames = host.calculateLayout(width: 300, height: 100)
        let texts = frames.filter { abs($0.w - 50) < 0.5 && abs($0.h - 20) < 0.5 }
        let sibling = try XCTUnwrap(texts.max { $0.x < $1.x })
        XCTAssertEqual(sibling.x, 50, accuracy: 0.5)
    }
}
