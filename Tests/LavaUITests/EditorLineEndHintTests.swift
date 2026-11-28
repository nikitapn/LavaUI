import CxxCanvas
import XCTest

@testable import LavaUI

final class EditorLineEndHintTests: XCTestCase {
    func testDrawsAfterLastWrappedRowAndOnlyReportsThePaintedHint() throws {
        let editor = try XCTUnwrap(Editor.openClient(width: 240, height: 300))
        let font = try XCTUnwrap(FontStore.bootstrap(assetsRoot: LavaResources.root, pixelSize: 16, into: editor))
        let controller = EditorController()
        let anchor = EditorLineEndHintAnchor()
        var hovered: [Bool] = []
        let title = String(repeating: "Long subject ", count: 8)
        let hint = EditorLineEndHint(anchor: anchor, text: { $0 == 0 ? title : nil },
                                     onHover: { hovered.append($0) })
        let source = String(repeating: "x", count: 30) + "\nsecond"
        let host = LayoutHost()
        host.setRoot(VStack(width: .pt(240), height: .pt(300), padding: 0) {
            EditorView(text: .constant(source), font: font, showLineNumbers: false,
                       wraps: true, controller: controller, lineEndHint: hint)
                .flexGrow(1)
        })
        _ = host.calculateLayout(width: 240, height: 300)
        let root = try XCTUnwrap(host.rootNode)
        let list = DrawList(editor: editor)
        list.clear()
        list.emitTree(root, viewportW: 240, viewportH: 300)
        let frame = try XCTUnwrap(anchor.frame)
        XCTAssertEqual(anchor.line, 0)
        XCTAssertGreaterThan(frame.minY, CGFloat(font.lineHeight), "the line wraps past the first row")
        XCTAssertLessThan(frame.width, CGFloat(font.shapedRun(title).width))
        XCTAssertLessThan(frame.maxX, 240)

        _ = host.hitTestHover(x: Float(frame.midX), y: Float(frame.midY))
        _ = host.hitTestHover(x: Float(frame.midX), y: Float(frame.midY))
        _ = host.hitTestHover(x: 4, y: Float(frame.midY))
        XCTAssertEqual(hovered, [true, false])

        XCTAssertTrue(controller.reveal(range: 31..<31))
        list.clear()
        list.emitTree(root, viewportW: 240, viewportH: 300)
        XCTAssertNil(anchor.frame, "the new line has no hint")
    }
}
