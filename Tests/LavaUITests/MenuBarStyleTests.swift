import XCTest

@testable import LavaUI
import LavaMenu

/// Compact panel chrome vs the in-window default, and a dropdown that
/// hugs a single short item instead of opening a 160pt slab.
final class MenuBarStyleTests: XCTestCase {
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
