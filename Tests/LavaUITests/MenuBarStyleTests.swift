import XCTest

@testable import LavaUI
import LavaMenu

/// Compact panel chrome vs the in-window default, and a dropdown that
/// hugs a single short item instead of opening a 160pt slab.
final class MenuBarStyleTests: XCTestCase {
    func testWindowMenuHasNoGapBeforeApplicationContent() throws {
        let model = MenuModel(menus: [
            MenuNode(id: MenuID("app"), title: "App", items: [])
        ])
        let host = LayoutHost()
        host.setRoot(
            MenuChromeRoot(
                model: model,
                onActivate: { _ in },
                content: Text("application content")
            )
        )

        let frames = host.calculateLayout(width: 400, height: 200)
        let content = try XCTUnwrap(
            frames.first { $0.label == "Text \"application content\"" }
        )
        XCTAssertEqual(content.y, MenuHost.barHeight, accuracy: 0.01)
    }

    func testPanelStyleHasNoStripFillAndHugsContent() {
        let panel = MenuBarStyle.panel(theme: .dark)
        XCTAssertNil(panel.stripFill)
        XCTAssertNil(panel.stripHeight)
        XCTAssertEqual(panel.dropdownMinWidth, 0)
        XCTAssertLessThan(panel.itemSpacing, Theme.dark.stackSpacing)

        let window = MenuBarStyle.standard(theme: .dark)
        XCTAssertNotNil(window.stripFill)
        XCTAssertEqual(window.stripHeight, MenuHost.barHeight)
        XCTAssertGreaterThan(window.dropdownMinWidth, 0)
        XCTAssertEqual(window.itemHover, Theme.dark.selectionFill)
    }

    func testPanelDropdownFollowsTheThemeRatherThanAHardcodedWash() {
        let dark = MenuBarStyle.panel(theme: .dark)
        XCTAssertEqual(dark.dropdownBackground.r, Theme.dark.panel.r, accuracy: 0.001)
        XCTAssertEqual(dark.dropdownBackground.g, Theme.dark.panel.g, accuracy: 0.001)
        XCTAssertEqual(dark.dropdownBackground.b, Theme.dark.panel.b, accuracy: 0.001)
        XCTAssertGreaterThan(dark.dropdownBackground.a, 0.95)
        XCTAssertEqual(dark.itemHover, Theme.dark.selectionFill)
        XCTAssertGreaterThan(dark.dropdownCornerRadius, 2)
        XCTAssertNil(dark.dropdownBlur)

        let nebula = MenuBarStyle.panel(theme: .nebula)
        XCTAssertEqual(nebula.dropdownBackground.r, Theme.nebula.panel.r, accuracy: 0.001)
        XCTAssertEqual(nebula.itemHover, Theme.nebula.selectionFill)
    }

    func testPanelStyleAsksForFrostWhenTheBridgeIsLive() {
        BackdropBridge.frostOverlay = { _, _, _, _, _, _ in }
        defer { BackdropBridge.frostOverlay = nil }
        let panel = MenuBarStyle.panel(theme: .dark)
        XCTAssertEqual(panel.dropdownBlur, 12)
        XCTAssertGreaterThan(panel.dropdownBackground.a, 0.7)
    }

    func testCompactDropdownIsShorterThanTheOldDefault() {
        let item = MenuItemModel(id: MenuID("one"), title: "Settings…")
        let host = LayoutHost()
        host.setRoot(
            MenuDropdownPanel(
                entries: [.item(item)],
                onActivate: { _ in },
                style: .panel(theme: .dark)
            )
        )
        let frames = host.calculateLayout(width: 400, height: 200)
        let texts = frames.filter { $0.label.hasPrefix("Text") }
        XCTAssertFalse(texts.isEmpty, frames.map(\.description).joined(separator: "\n"))
        // Was padding 4 + theme spacing 8 + minWidth 160. A single
        // short row should now sit well under 30pt tall and not
        // stretch to the host.
        for row in texts {
            XCTAssertLessThan(row.h, 30, "row height \(row.h) \(row.description)")
            XCTAssertLessThan(row.w, 160, "row width \(row.w) \(row.description)")
        }
    }
}
