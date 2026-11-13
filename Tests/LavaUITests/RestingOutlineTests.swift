import CxxCanvas
import XCTest

@testable import LavaUI

/// An unfocused field draws a one-pixel edge in `theme.border` — in the dark
/// palette its fill is within a hundredth of the window's background, and
/// without it a field could not be seen until it was clicked. The theme can
/// turn that off, one field can, and a field that turned its focus ring off
/// is taken to want no chrome unless it asks.
final class RestingOutlineTests: XCTestCase {
    private var editor: Editor!

    override func setUpWithError() throws {
        editor = try XCTUnwrap(
            Editor.openClient(width: 200, height: 60), "client engine failed to open"
        )
        XCTAssertNotNil(
            FontStore.bootstrap(assetsRoot: LavaResources.root, pixelSize: 16, into: editor),
            "default face failed to load"
        )
    }

    /// How many shapes in `theme.border` one unfocused field emits.
    private func edges(theme: Theme = .dark, _ field: TextField) throws -> Int {
        let host = LayoutHost()
        host.setRoot(
            HStack(width: .pt(200), height: .pt(60), alignment: .start) {
                field.frame(width: .pt(120), height: .pt(28))
            }
            .theme(theme)
        )
        _ = host.calculateLayout(width: 200, height: 60)
        let root = try XCTUnwrap(host.rootNode)
        let list = DrawList(editor: editor)
        list.clear()
        list.emitTree(root, viewportW: 200, viewportH: 60)
        let border = theme.border.rgba8
        return (0..<list.commandCount).compactMap { list.emitted(at: $0) }
            .filter { ($0.kind == .roundedRect || $0.kind == .rect) && $0.color == border }
            .count
    }

    private func field(focusRing: FocusRingStyle? = nil, restingOutline: Bool? = nil) -> TextField {
        TextField(
            text: .constant(""), placeholder: "Find",
            focusRing: focusRing, restingOutline: restingOutline
        )
    }

    func testAFieldHasAnEdgeByDefault() throws {
        XCTAssertEqual(try edges(field()), 1)
    }

    func testOneFieldCanTurnItOff() throws {
        XCTAssertEqual(try edges(field(restingOutline: false)), 0)
    }

    func testAThemeCanTurnItOffAndOneFieldBackOn() throws {
        var theme = Theme.dark
        theme.restingOutline = false
        XCTAssertEqual(try edges(theme: theme, field()), 0)
        XCTAssertEqual(try edges(theme: theme, field(restingOutline: true)), 1)
    }

    func testAFieldWithNoFocusRingIsBareUnlessItAsks() throws {
        XCTAssertEqual(try edges(field(focusRing: FocusRingStyle.none)), 0)
        XCTAssertEqual(try edges(field(focusRing: FocusRingStyle.none, restingOutline: true)), 1)
    }
}
