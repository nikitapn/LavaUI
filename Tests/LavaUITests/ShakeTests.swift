import XCTest

@testable import LavaUI

final class ShakeTests: XCTestCase {
    func testAlternatesAcrossCenterAndSettles() {
        let offsets = (0...5).map { ShakeNode<Int>.offset(at: Double($0) / 5) }
        XCTAssertEqual(offsets, [0, -1, 1, -1, 1, 0])
        XCTAssertEqual(ShakeNode<Int>.offset(at: 2), 0)
    }

    func testKeepsChildAndMovesItsPaintAndHitTargetTogether() throws {
        let host = LayoutHost()
        let editor = try XCTUnwrap(Editor.openClient(width: 100, height: 80))
        let list = DrawList(editor: editor, sink: CapturedFrameSink())
        func install(trigger: Int) {
            host.setRoot(
                HStack(alignment: .start) {
                    HStack(width: .pt(20), height: .pt(20), onClick: {}) {
                        Spacer()
                    }
                    .background(.red)
                    .shake(trigger: trigger)
                }
            )
            _ = host.calculateLayout(width: 100, height: 80)
        }

        install(trigger: 0)
        let shake = try XCTUnwrap(host.rootNode?.childNodes.first as? ShakeNode<Int>)
        let mountedChild = shake.contentNode.id
        XCTAssertEqual(shake.visualOffsetX, 0)
        shake.visualOffsetX = 6
        install(trigger: 0)
        XCTAssertEqual(shake.visualOffsetX, 6)
        XCTAssertNil(host.hitTestClick(x: 3, y: 10))
        XCTAssertNotNil(host.hitTestClick(x: 23, y: 10))

        list.clear()
        list.emitTree(try XCTUnwrap(host.rootNode), viewportW: 100, viewportH: 80)
        let commands = (0..<list.commandCount).compactMap { list.emitted(at: $0) }
        XCTAssertEqual(commands.first { $0.kind == .rect && $0.color == Color.red.rgba8 }?.x, 6)

        install(trigger: 1)
        defer { AnimationDriver.unregister(shake.id) }
        XCTAssertEqual(shake.visualOffsetX, 0)
        XCTAssertEqual(shake.contentNode.id, mountedChild)
        XCTAssertNotNil(host.hitTestClick(x: 3, y: 10))
    }
}
