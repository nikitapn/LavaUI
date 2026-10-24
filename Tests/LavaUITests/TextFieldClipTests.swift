import CxxCanvas
import XCTest

@testable import LavaUI

/// A single-line field's text stays inside the field.
///
/// Found in LavaExplorer: split a window into panes and the address bar gets
/// narrow, and the path in it drew over the "Hidden" button beside it. Rows
/// were already stopped at the bottom edge; nothing stopped them at the right.
///
/// The scissor is the text area, inside the field's padding, rather than the
/// field: a row slid left under the caret has a selection that starts before
/// the visible part, and clipped at the field it painted over the padding and
/// the focus ring.
final class TextFieldClipTests: XCTestCase {
    func testLongTextIsScissoredToTheField() throws {
        let editor = try XCTUnwrap(
            Editor.openClient(width: 400, height: 80),
            "client engine failed to open"
        )
        XCTAssertNotNil(
            FontStore.bootstrap(assetsRoot: LavaResources.root, pixelSize: 16, into: editor),
            "default face failed to load"
        )
        var text = "/tmp/a/very/long/path/that/cannot/possibly/fit/in/ninety/pixels"
        let host = LayoutHost()
        host.setRoot(
            HStack(width: .pt(400), height: .pt(80), alignment: .start) {
                TextField(
                    text: Binding(get: { text }, set: { text = $0 }),
                    placeholder: "Path"
                )
                .frame(width: .pt(90), height: .pt(28))
            }
        )
        _ = host.calculateLayout(width: 400, height: 80)
        let root = try XCTUnwrap(host.rootNode)
        let list = DrawList(editor: editor)
        list.clear()
        list.emitTree(root, viewportW: 400, viewportH: 80)

        let commands = (0..<list.commandCount).compactMap { list.emitted(at: $0) }
        // Inside the field and most of it: narrower than the field by its
        // padding, never by so much that the scissor is something else.
        func isFieldClip(_ c: (kind: DrawKind?, x: Float, y: Float, w: Float, h: Float,
                               aux: Float, param: UInt32, color: UInt32)) -> Bool {
            c.kind == .pushClip && abs(c.h - 28) < 0.5
                && c.x >= -0.5 && c.x + c.w <= 90.5 && c.w > 60
        }
        let clip = try XCTUnwrap(
            commands.first(where: isFieldClip), "no scissor inside the field"
        )
        XCTAssertLessThan(clip.w, 90, "the padding is outside the scissor")
        let clipIndex = try XCTUnwrap(commands.firstIndex(where: isFieldClip))
        let textIndex = try XCTUnwrap(commands.firstIndex { $0.kind == .text })
        XCTAssertLessThan(clipIndex, textIndex, "the text is drawn inside the scissor")
    }
}
