import CYoga
import CxxCanvas
import LavaMenu
import XCTest

@testable import LavaUI

/// A menu longer than the room under its title.
///
/// The case this exists for is an applet menu on a desktop panel — thirty
/// wireless networks dropping out of a 32pt strip — where the list used to be
/// laid out at its full natural height, clamped back over the panel it came
/// from, and spilled off the bottom of the surface with no way to reach the
/// end of itself.
///
/// Driven like `ComboBoxTests`: an overlay is measured and placed during
/// emit, not during layout, so every test here lays out, emits, and only then
/// asks where anything is.
final class MenuScrollTests: XCTestCase {
    private static let viewport: (w: Float, h: Float) = (400, 300)

    private var editor: Editor!
    private var host: LayoutHost!
    private var open: MenuID?
    private var activated: [MenuID] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        editor = try XCTUnwrap(
            Editor.openClient(width: Self.viewport.w, height: Self.viewport.h),
            "client engine failed to open"
        )
        XCTAssertNotNil(
            FontStore.bootstrap(
                assetsRoot: LavaResources.root, pixelSize: 16, into: editor
            ),
            "default face failed to load"
        )
        host = LayoutHost()
        open = MenuID("m")
        activated = []
    }

    override func tearDown() {
        host = nil
        editor = nil
        super.tearDown()
    }

    // MARK: - Driving

    private func menu(rows: Int) -> MenuModel {
        let items: [MenuEntry] = (0..<rows).map {
            .item(MenuItemModel(id: MenuID("i\($0)"), title: "row \($0)"))
        }
        return MenuModel(
            menus: [MenuNode(id: MenuID("m"), title: "File", items: items)]
        )
    }

    /// One frame: layout, then emit, which is what places the dropdown. The
    /// strip is pinned to the top by a spacer below it, the way
    /// `MenuChromeRoot` pins it above app content.
    private func settle(rows: Int) {
        let model = menu(rows: rows)
        host.setRoot(
            VStack(flexGrow: 1, padding: 0, spacing: 0) {
                MenuBarStrip(
                    model: model,
                    openMenuID: Binding(
                        get: { [weak self] in self?.open },
                        set: { [weak self] in self?.open = $0 }
                    ),
                    onActivate: { [weak self] in self?.activated.append($0) },
                    style: .standard()
                )
                Spacer()
            }
        )
        _ = host.calculateLayout(width: Self.viewport.w, height: Self.viewport.h)
        guard let root = host.rootNode else { return }
        let list = DrawList(editor: editor)
        list.clear()
        list.emitTree(root, viewportW: Self.viewport.w, viewportH: Self.viewport.h)
    }

    private func dropdown() throws -> OverlayAttachment {
        let root = try XCTUnwrap(host.rootNode)
        return try XCTUnwrap(
            OverlayScan.presented(in: root).first, "no menu is open"
        )
    }

    private func scroller() throws -> ScrollNode {
        var found: ScrollNode?
        func walk(_ node: any AnyViewNode) {
            if let scroll = node as? ScrollNode, found == nil { found = scroll }
            for child in node.childNodes { walk(child) }
        }
        walk(try XCTUnwrap(dropdown().root))
        return try XCTUnwrap(found, "the dropdown is not a scroll container")
    }

    /// Window-space frame of the first text leaf reading `string`, in the
    /// dropdown, wherever the scroll offset has put it — on screen or not.
    private func rowFrame(_ string: String) throws
        -> (x: Float, y: Float, w: Float, h: Float)?
    {
        let attachment = try dropdown()
        let root = try XCTUnwrap(attachment.root)
        return locate(root, string, attachment.origin.x, attachment.origin.y)
    }

    /// The same, but only when the row is inside the panel — which is the
    /// only place the renderer's scissor lets it be seen.
    private func visibleRow(_ string: String) throws
        -> (x: Float, y: Float, w: Float, h: Float)?
    {
        guard let frame = try rowFrame(string) else { return nil }
        let panel = try dropdown()
        guard frame.y >= panel.origin.y - 1,
              frame.y + frame.h <= panel.origin.y + panel.size.h + 1
        else { return nil }
        return frame
    }

    /// Window-space frame of a text leaf in the main tree (a strip title).
    private func stripFrame(_ string: String) throws
        -> (x: Float, y: Float, w: Float, h: Float)?
    {
        locate(try XCTUnwrap(host.rootNode), string, 0, 0)
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
        let shift = (node as? YogaBoxNode)?.childOffset ?? (x: 0, y: 0)
        for child in node.childNodes {
            if let hit = locate(child, string, x - shift.x, y - shift.y) {
                return hit
            }
        }
        return nil
    }

    // MARK: - Tests

    func testAShortMenuStillSizesToItsContent() throws {
        settle(rows: 3)
        let panel = try dropdown()
        let scroll = try scroller()

        XCTAssertLessThan(panel.size.h, Self.viewport.h / 2, "3 rows filled the window")
        XCTAssertEqual(
            scroll.contentLength, scroll.viewportLength, accuracy: 1,
            "a menu that fits has nothing to scroll"
        )
        XCTAssertEqual(scroll.maxOffset, 0)

        // The scroll container sits between the panel and the rows, so it is
        // the thing that has to stretch: a row narrower than the popup would
        // light up only part way across on hover.
        XCTAssertEqual(
            YGNodeLayoutGetWidth(try XCTUnwrap(scroll.yoga)),
            panel.size.w - MenuBarStyle.standard().dropdownPadding * 2,
            accuracy: 0.5,
            "the rows do not fill the menu"
        )
    }

    func testALongMenuStopsAtTheRoomBelowItsTitleInsteadOfCoveringIt() throws {
        settle(rows: 60)
        let panel = try dropdown()

        // The strip is the first thing in the window, so the room below it is
        // everything under it — and the popup must claim no more than that.
        let title = try XCTUnwrap(try stripFrame("File"), "no menu bar")
        XCTAssertGreaterThanOrEqual(
            panel.origin.y, title.y + title.h,
            "the dropdown was pushed back over the menu bar"
        )
        XCTAssertLessThanOrEqual(
            panel.origin.y + panel.size.h, Self.viewport.h + 1,
            "the dropdown runs off the bottom of the window"
        )
    }

    func testALongMenuHasSomethingLeftToScroll() throws {
        settle(rows: 60)
        let scroll = try scroller()

        XCTAssertGreaterThan(
            scroll.contentLength, scroll.viewportLength,
            "the list was squashed to fit rather than left scrollable"
        )
        XCTAssertGreaterThan(scroll.maxOffset, 0)
    }

    func testTheLastRowIsReachableByScrolling() throws {
        settle(rows: 60)
        let scroll = try scroller()

        XCTAssertNil(try visibleRow("row 59"), "the end is visible without scrolling")

        scroll.adoptRendererOffset(x: 0, y: scroll.maxOffset)
        settle(rows: 60)

        let last = try XCTUnwrap(
            try visibleRow("row 59"), "the end never came into view"
        )
        let action = try XCTUnwrap(
            host.hitTestClick(x: last.x + last.w / 2, y: last.y + last.h / 2),
            "the last row is not clickable"
        )
        action()
        XCTAssertEqual(activated, [MenuID("i59")])
    }

    /// The reason the walks clip at a scroll container. A row scrolled off the
    /// top of the list keeps its layout rect, and that rect lands on the menu
    /// bar above the popup — where a click belongs to the title, not to an
    /// item nobody can see.
    func testARowScrolledOutOfSightDoesNotTakeTheClick() throws {
        settle(rows: 60)
        let scroll = try scroller()

        // Just far enough that the first row rides up onto the menu bar,
        // which is the only place a scrolled-away row can still be pointed
        // at: the rest of the list leaves the window entirely. Derived from
        // where the two actually are rather than guessed, so a change to the
        // row metrics does not quietly aim the probe somewhere harmless.
        let title = try XCTUnwrap(try stripFrame("File"))
        let resting = try XCTUnwrap(try rowFrame("row 0"))
        let travel = (resting.y + resting.h / 2) - (title.y + title.h / 2)
        XCTAssertGreaterThan(travel, 0)
        scroll.adoptRendererOffset(x: 0, y: travel)
        settle(rows: 60)

        XCTAssertNil(try visibleRow("row 0"), "row 0 is still on screen")
        let hidden = try XCTUnwrap(try rowFrame("row 0"))
        let x = hidden.x + hidden.w / 2
        let y = hidden.y + hidden.h / 2
        XCTAssertLessThan(y, title.y + title.h, "the probe is not over the bar")

        if let action = host.hitTestClick(x: x, y: y) { action() }
        XCTAssertEqual(activated, [], "a row that is off screen was activated")
        XCTAssertNil(open, "the click belonged to the title, which closes")
    }
}
