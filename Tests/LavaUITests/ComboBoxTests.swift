import CYoga
import CxxCanvas
import XCTest

@testable import LavaUI

/// `ComboBox` — driven the way a pointer drives it.
///
/// The dropdown is an overlay, and an overlay is not part of the layout pass:
/// it is measured and placed during emit, which is why every test here lays
/// out, emits once, and only then hit-tests. Asserting on the node tree alone
/// would pass for a menu that is never actually placed anywhere clickable.
final class ComboBoxTests: XCTestCase {
    private static let viewport: (w: Float, h: Float) = (400, 300)

    private var editor: Editor!
    private var host: LayoutHost!

    override func setUpWithError() throws {
        try super.setUpWithError()
        editor = try XCTUnwrap(
            Editor.openClient(width: Self.viewport.w, height: Self.viewport.h),
            "client engine failed to open"
        )
        XCTAssertNotNil(
            FontStore.bootstrap(assetsRoot: LavaResources.root, pixelSize: 16, into: editor),
            "default face failed to load"
        )
        host = LayoutHost()
    }

    override func tearDown() {
        host = nil
        editor = nil
        super.tearDown()
    }

    // MARK: - Driving

    /// Lays out and places overlays, exactly as a frame does.
    private func settle<V: View>(_ view: V) {
        host.setRoot(view)
        _ = host.calculateLayout(width: Self.viewport.w, height: Self.viewport.h)
        guard let root = host.rootNode else { return }
        let list = DrawList(editor: editor)
        list.clear()
        list.emitTree(root, viewportW: Self.viewport.w, viewportH: Self.viewport.h)
    }

    /// Window-space frame of the first text leaf reading `string`, wherever it
    /// is — main tree or an open overlay.
    private func find(_ string: String) -> (x: Float, y: Float, w: Float, h: Float)? {
        guard let root = host.rootNode else { return nil }
        if let hit = locate(root, string, 0, 0) { return hit }
        for attachment in OverlayScan.presented(in: root) {
            guard let overlayRoot = attachment.root else { continue }
            if let hit = locate(
                overlayRoot, string, attachment.origin.x, attachment.origin.y
            ) {
                return hit
            }
        }
        return nil
    }

    private func locate(
        _ node: any AnyViewNode, _ string: String, _ ox: Float, _ oy: Float
    ) -> (x: Float, y: Float, w: Float, h: Float)? {
        var x = ox
        var y = oy
        if let yoga = node.yoga {
            x += YGNodeLayoutGetLeft(yoga)
            y += YGNodeLayoutGetTop(yoga)
            if let leaf = node as? LeafNode, leaf.kind == .text, leaf.text == string {
                return (x, y, YGNodeLayoutGetWidth(yoga), YGNodeLayoutGetHeight(yoga))
            }
        }
        for child in node.childNodes {
            if let hit = locate(child, string, x, y) { return hit }
        }
        return nil
    }

    private func click(_ string: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let frame = try XCTUnwrap(find(string), "no \"\(string)\" on screen", file: file, line: line)
        let action = try XCTUnwrap(
            host.hitTestClick(x: frame.x + frame.w / 2, y: frame.y + frame.h / 2),
            "\"\(string)\" is not clickable", file: file, line: line
        )
        action()
    }

    private func items(_ titles: [String]) -> [ComboBoxItem<Int>] {
        titles.enumerated().map { ComboBoxItem($0.element, tag: $0.offset) }
    }

    // MARK: - Tests

    func testClosedFieldShowsTheSelectionAndNothingElse() {
        var choice = 1
        settle(
            ComboBox(
                selection: Binding(get: { choice }, set: { choice = $0 }),
                items: items(["alpha", "beta", "gamma"])
            )
        )

        XCTAssertNotNil(find("beta"))
        // The list subtree stays mounted while closed — it just is not placed,
        // so none of it is anywhere a click could land.
        XCTAssertNil(find("alpha"))
        XCTAssertNil(find("gamma"))
    }

    func testPlaceholderStandsInForATagThatIsNotInTheList() {
        var choice = 9
        settle(
            ComboBox(
                selection: Binding(get: { choice }, set: { choice = $0 }),
                items: items(["alpha", "beta"]),
                placeholder: "nothing open"
            )
        )

        XCTAssertNotNil(find("nothing open"))
    }

    func testPickingARowWritesTheBindingAndClosesTheList() throws {
        var choice = 0
        func rebuild() {
            settle(
                ComboBox(
                    selection: Binding(get: { choice }, set: { choice = $0 }),
                    items: items(["alpha", "beta", "gamma"])
                )
            )
        }

        rebuild()
        try click("alpha")          // the field
        rebuild()
        XCTAssertNotNil(find("gamma"), "the list did not open")

        try click("gamma")
        XCTAssertEqual(choice, 2)
        rebuild()
        XCTAssertNotNil(find("gamma"), "the field shows the new choice")
        XCTAssertNil(find("beta"), "and the list closed behind it")
    }

    func testTheOpenListDropsBelowTheField() throws {
        var choice = 0
        func rebuild() {
            settle(
                ComboBox(
                    selection: Binding(get: { choice }, set: { choice = $0 }),
                    items: items(["alpha", "beta", "gamma"])
                )
            )
        }

        rebuild()
        let field = try XCTUnwrap(find("alpha"))
        try click("alpha")
        rebuild()

        let row = try XCTUnwrap(find("gamma"))
        XCTAssertGreaterThan(row.y, field.y + field.h)
    }

    func testTheSelectedRowIsTicked() throws {
        var choice = 0
        func rebuild() {
            settle(
                ComboBox(
                    selection: Binding(get: { choice }, set: { choice = $0 }),
                    items: items(["alpha", "beta", "gamma"])
                )
            )
        }

        rebuild()
        try click("alpha")
        rebuild()

        let tick = try XCTUnwrap(find("✓"), "no row is marked as current")
        // The second "alpha" is the row; the first is the closed field, which
        // sits in the main tree above the list.
        let row = try XCTUnwrap(allFrames("alpha").last)
        XCTAssertEqual(tick.y, row.y, accuracy: 2, "the tick is on another row")
    }

    /// Re-picking the current row must not write the binding: a switcher's
    /// setter has side effects — saving a scroll offset, reading a file — and
    /// this would run them for a switch that did not happen.
    func testPickingTheCurrentRowDoesNotWriteTheBinding() throws {
        var choice = 0
        var writes = 0
        func rebuild() {
            settle(
                ComboBox(
                    selection: Binding(get: { choice }, set: { choice = $0; writes += 1 }),
                    items: items(["alpha", "beta"])
                )
            )
        }

        rebuild()
        try click("alpha")
        rebuild()
        // Two "alpha"s exist now, the field and its row; the row is the one
        // under the tick, and `click` takes the first — the field. Clicking
        // the field again would only close the list, so aim at the row.
        let rows = allFrames("alpha")
        XCTAssertEqual(rows.count, 2)
        let row = rows[1]
        let action = try XCTUnwrap(
            host.hitTestClick(x: row.x + row.w / 2, y: row.y + row.h / 2)
        )
        action()

        XCTAssertEqual(writes, 0)
        XCTAssertEqual(choice, 0)
    }

    func testDetailTellsTwoIdenticallyNamedRowsApart() throws {
        var choice = 0
        func rebuild() {
            settle(
                ComboBox(
                    selection: Binding(get: { choice }, set: { choice = $0 }),
                    items: [
                        ComboBoxItem("app.log", tag: 0, detail: "/var/log"),
                        ComboBoxItem("app.log", tag: 1, detail: "/tmp/run-2"),
                    ]
                )
            )
        }

        rebuild()
        try click("app.log")
        rebuild()

        XCTAssertNotNil(find("/var/log"))
        XCTAssertNotNil(find("/tmp/run-2"))
    }

    func testTagsNeedNotBeIndices() throws {
        var choice = "b"
        func rebuild() {
            settle(
                ComboBox(
                    selection: Binding(get: { choice }, set: { choice = $0 }),
                    items: [
                        ComboBoxItem("Alpha", tag: "a"),
                        ComboBoxItem("Beta", tag: "b"),
                    ]
                )
            )
        }

        rebuild()
        try click("Beta")           // the field
        rebuild()
        try click("Alpha")
        XCTAssertEqual(choice, "a")
    }

    /// Every window-space frame reading `string`, in tree order: main tree
    /// first, then any open overlay.
    private func allFrames(_ string: String) -> [(x: Float, y: Float, w: Float, h: Float)] {
        guard let root = host.rootNode else { return [] }
        var out: [(x: Float, y: Float, w: Float, h: Float)] = []
        collect(root, string, 0, 0, &out)
        for attachment in OverlayScan.presented(in: root) {
            guard let overlayRoot = attachment.root else { continue }
            collect(overlayRoot, string, attachment.origin.x, attachment.origin.y, &out)
        }
        return out
    }

    private func collect(
        _ node: any AnyViewNode, _ string: String, _ ox: Float, _ oy: Float,
        _ out: inout [(x: Float, y: Float, w: Float, h: Float)]
    ) {
        var x = ox
        var y = oy
        if let yoga = node.yoga {
            x += YGNodeLayoutGetLeft(yoga)
            y += YGNodeLayoutGetTop(yoga)
            if let leaf = node as? LeafNode, leaf.kind == .text, leaf.text == string {
                out.append((x, y, YGNodeLayoutGetWidth(yoga), YGNodeLayoutGetHeight(yoga)))
            }
        }
        for child in node.childNodes {
            collect(child, string, x, y, &out)
        }
    }
}
