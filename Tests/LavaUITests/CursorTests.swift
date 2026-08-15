import XCTest

@testable import LavaUI

final class CursorTests: XCTestCase {
    /// The node the renderer would report for a label, found by walking the
    /// laid-out tree — the same tree `CursorBridge` resolves against.
    private func node(
        labelled label: String, in root: any AnyViewNode
    ) -> (any AnyViewNode)? {
        // Prefix: a text leaf labels itself with its own string (`Text "…"`).
        if root.label.hasPrefix(label) { return root }
        for child in root.childNodes {
            if let found = node(labelled: label, in: child) { return found }
        }
        return nil
    }

    private func shape(
        for label: String, in host: LayoutHost
    ) throws -> CursorShape? {
        let root = try XCTUnwrap(host.rootNode)
        let target = try XCTUnwrap(node(labelled: label, in: root))
        return try XCTUnwrap(CursorBridge.resolve(target.id, in: root))
    }

    func testInnermostStatedCursorWins() throws {
        let host = LayoutHost()
        host.setRoot(
            VStack {
                Text("field").cursor(.text)
            }
            .cursor(.pointer)
        )
        _ = host.calculateLayout(width: 200, height: 100)

        XCTAssertEqual(try shape(for: "Text", in: host), .text)
    }

    func testAViewWithNoCursorInheritsFromItsAncestor() throws {
        let host = LayoutHost()
        host.setRoot(
            VStack {
                Text("label")
            }
            .cursor(.pointer)
        )
        _ = host.calculateLayout(width: 200, height: 100)

        XCTAssertEqual(try shape(for: "Text", in: host), .pointer)
    }

    func testNoCursorAnywhereResolvesToNothingStated() throws {
        let host = LayoutHost()
        host.setRoot(VStack { Text("label") })
        _ = host.calculateLayout(width: 200, height: 100)

        XCTAssertNil(try shape(for: "Text", in: host))
    }

    func testANodeOutsideTheTreeIsNotFound() throws {
        let host = LayoutHost()
        host.setRoot(VStack { Text("label").cursor(.text) })
        _ = host.calculateLayout(width: 200, height: 100)

        let root = try XCTUnwrap(host.rootNode)
        XCTAssertNil(CursorBridge.resolve(NodeID.generate(), in: root))
    }

    /// The pointer image changes when the pointer *enters* a view, and only a
    /// hit-testable node is ever reported as entered.
    func testStatingACursorMakesTheNodeHitTestable() throws {
        let host = LayoutHost()
        host.setRoot(VStack { Text("plain") })
        _ = host.calculateLayout(width: 200, height: 100)
        var root = try XCTUnwrap(host.rootNode)
        var leaf = try XCTUnwrap(node(labelled: "Text", in: root) as? LeafNode)
        XCTAssertFalse(leaf.isRendererInteractive)

        host.setRoot(VStack { Text("plain").cursor(.text) })
        _ = host.calculateLayout(width: 200, height: 100)
        root = try XCTUnwrap(host.rootNode)
        leaf = try XCTUnwrap(node(labelled: "Text", in: root) as? LeafNode)
        XCTAssertTrue(leaf.isRendererInteractive)
    }

    func testRemovingTheModifierGivesThePointerBack() throws {
        let host = LayoutHost()
        host.setRoot(VStack { Text("plain").cursor(.text) })
        _ = host.calculateLayout(width: 200, height: 100)
        XCTAssertEqual(try shape(for: "Text", in: host), .text)

        host.setRoot(VStack { Text("plain").cursor(nil) })
        _ = host.calculateLayout(width: 200, height: 100)
        XCTAssertNil(try shape(for: "Text", in: host))
    }

    /// The two built-in controls that state one for themselves.
    func testTextControlsCarryAnIBeam() throws {
        let host = LayoutHost()
        host.setRoot(
            VStack {
                TextField(text: .constant("one"))
                EditorView(text: .constant("two"))
            }
        )
        _ = host.calculateLayout(width: 300, height: 200)

        XCTAssertEqual(try shape(for: "TextField", in: host), .text)
        XCTAssertEqual(try shape(for: "EditorView", in: host), .text)
    }

    /// An app can still say otherwise — the modifier is applied over the
    /// control's own setting, not under it.
    func testAnAppCanOverrideAControlsOwnCursor() throws {
        let host = LayoutHost()
        host.setRoot(VStack { TextField(text: .constant("one")).cursor(.pointer) })
        _ = host.calculateLayout(width: 300, height: 200)

        XCTAssertEqual(try shape(for: "TextField", in: host), .pointer)
    }

    /// The raw values cross a process boundary as `CursorShape` in the IDL,
    /// where the compositor maps them to theme names by ordinal.
    func testOrdinalsAreTheWireFormat() {
        XCTAssertEqual(CursorShape.arrow.rawValue, 0)
        XCTAssertEqual(CursorShape.text.rawValue, 1)
        XCTAssertEqual(CursorShape.pointer.rawValue, 2)
        XCTAssertEqual(CursorShape.crosshair.rawValue, 3)
        XCTAssertEqual(CursorShape.resizeLeftRight.rawValue, 4)
        XCTAssertEqual(CursorShape.resizeUpDown.rawValue, 5)
    }
}
