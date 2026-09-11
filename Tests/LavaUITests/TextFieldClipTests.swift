import CxxCanvas
import XCTest

@testable import LavaUI

/// A single-line field's text stays inside the field.
///
/// Found in LavaExplorer: split a window into panes and the address bar gets
/// narrow, and the path in it drew over the "Hidden" button beside it. Rows
/// were already stopped at the bottom edge; nothing stopped them at the right.
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
        let clip = try XCTUnwrap(
            commands.first { $0.kind == .pushClip && abs($0.w - 90) < 0.5 },
            "no scissor the width of the field"
        )
        XCTAssertEqual(clip.h, 28, accuracy: 0.5)
        let clipIndex = try XCTUnwrap(commands.firstIndex { $0.kind == .pushClip && abs($0.w - 90) < 0.5 })
        let textIndex = try XCTUnwrap(commands.firstIndex { $0.kind == .text })
        XCTAssertLessThan(clipIndex, textIndex, "the text is drawn inside the scissor")
    }
}
