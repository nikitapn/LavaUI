import XCTest
import CxxCanvas
@testable import LavaUI

final class WindowControlsTests: XCTestCase {
    private func host(_ kind: WindowControlKind, beforeClose: @escaping () -> Void) throws -> LayoutHost {
        let host = LayoutHost()
        host.setRoot(VStack(width: .pt(100), height: .pt(50), alignment: .start, spacing: 0) {
            WindowControls([kind], beforeClose: beforeClose)
        })
        _ = host.calculateLayout(width: 100, height: 50)
        let editor = try XCTUnwrap(Editor.openClient(width: 100, height: 50))
        let list = DrawList(editor: editor)
        list.emitTree(try XCTUnwrap(host.rootNode), viewportW: 100, viewportH: 50)
        return host
    }

    func testCleanupRunsOnAcceptedCloseRelease() throws {
        var calls = 0
        let host = try host(.close) { calls += 1 }
        let press = try XCTUnwrap(host.hitTestClick(x: 6, y: 6))
        press()
        XCTAssertEqual(calls, 0, "pressing alone must not discard application state")
        PointerCapture.move(x: 6, y: 6)
        PointerCapture.release()
        XCTAssertEqual(calls, 1)
    }

    func testDraggingOffCloseDoesNotRunCleanup() throws {
        var calls = 0
        let host = try host(.close) { calls += 1 }
        let press = try XCTUnwrap(host.hitTestClick(x: 6, y: 6))
        press()
        PointerCapture.move(x: 90, y: 40)
        PointerCapture.release()
        XCTAssertEqual(calls, 0)
    }

    func testMinimizeDoesNotRunCloseCleanup() throws {
        var calls = 0
        let host = try host(.minimize) { calls += 1 }
        let press = try XCTUnwrap(host.hitTestClick(x: 6, y: 6))
        press()
        PointerCapture.move(x: 6, y: 6)
        PointerCapture.release()
        XCTAssertEqual(calls, 0)
    }
}
