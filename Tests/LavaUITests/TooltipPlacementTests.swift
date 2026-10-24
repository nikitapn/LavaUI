import XCTest

@testable import LavaUI

/// Where a tooltip lands: the side asked for, the other one when there is no
/// room, and always inside the window — which is all a tooltip has, since it
/// is drawn into the window it belongs to.
final class TooltipPlacementTests: XCTestCase {
    private func origin(
        _ placement: TooltipPlacement, anchor: (Float, Float, Float, Float),
        viewport: (Float, Float) = (800, 600)
    ) -> (x: Float, y: Float) {
        DrawList.tooltipOrigin(
            placement: placement, w: 100, h: 26, gap: 6,
            anchorX: anchor.0, anchorY: anchor.1, anchorW: anchor.2, anchorH: anchor.3,
            viewportW: viewport.0, viewportH: viewport.1
        )
    }

    func testBelowCentresUnderTheViewAndFlipsAboveAtTheBottom() {
        let below = origin(.below, anchor: (100, 100, 40, 20))
        XCTAssertEqual(below.x, 70)
        XCTAssertEqual(below.y, 126)
        let flipped = origin(.below, anchor: (100, 560, 40, 20))
        XCTAssertEqual(flipped.y, 560 - 6 - 26)
    }

    func testAboveFlipsBelowAtTheTop() {
        XCTAssertEqual(origin(.above, anchor: (100, 100, 40, 20)).y, 100 - 6 - 26)
        XCTAssertEqual(origin(.above, anchor: (100, 10, 40, 20)).y, 36)
    }

    /// The panel: a 32pt strip is the whole window, an icon near its right
    /// end. Below and above both run out of it, and used to land the label
    /// on top of the icons; to the side it sits level with the icon.
    func testLeadingFitsInAStripWhereBelowCannot() {
        let strip: (Float, Float) = (1280, 32)
        let icon: (Float, Float, Float, Float) = (1100, -2, 28, 36)
        let side = origin(.leading, anchor: icon, viewport: strip)
        XCTAssertEqual(side.x, 1100 - 6 - 100)
        // Level with the icon is 3; the 4pt margin from the window's edge
        // takes it to 4, and it still ends inside the strip.
        XCTAssertEqual(side.y, 4)
        XCTAssertLessThanOrEqual(side.y + 26, 32)
        // Clear of the icon: it ends before the icon starts.
        XCTAssertLessThanOrEqual(side.x + 100, 1100)
        // Below in the same strip is clamped back over the icon.
        let below = origin(.below, anchor: icon, viewport: strip)
        XCTAssertGreaterThan(below.x + 100, 1100)
    }

    func testLeadingAndTrailingFlipAtTheEdges() {
        XCTAssertEqual(origin(.leading, anchor: (20, 100, 40, 20)).x, 20 + 40 + 6)
        XCTAssertEqual(origin(.trailing, anchor: (100, 100, 40, 20)).x, 146)
        XCTAssertEqual(origin(.trailing, anchor: (740, 100, 40, 20)).x, 740 - 6 - 100)
    }

    func testRestatingATooltipTakesItsPlacementWithIt() {
        var inner = ViewStyle()
        inner.tooltip = "inner"
        inner.tooltipPlacement = .leading
        var outer = ViewStyle()
        outer.tooltip = "outer"
        outer.tooltipPlacement = nil
        let merged = outer.merged(over: inner)
        XCTAssertEqual(merged.tooltip, "outer")
        XCTAssertNil(merged.tooltipPlacement)
        var plain = ViewStyle()
        plain.cornerRadius = 4
        XCTAssertEqual(plain.merged(over: inner).tooltipPlacement, .leading)
    }
}
