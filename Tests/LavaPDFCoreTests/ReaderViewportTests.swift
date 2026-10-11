import XCTest

@testable import LavaPDFCore

final class ReaderViewportTests: XCTestCase {
    /// Two 600×800 pages, 10 apart, 20 of margin: a column 640 wide and
    /// 20 + 800 + 10 + 800 + 20 = 1650 tall.
    private let layout = PageLayout(
        pageSizes: [PageSize(width: 600, height: 800), PageSize(width: 600, height: 800)],
        gap: 10, margin: 20
    )

    func testNarrowColumnIsCentredAndDoesNotScrollSideways() {
        let viewport = ReaderViewport(zoom: 1, scrollX: 300, scrollY: 0)
        XCTAssertEqual(viewport.originX(layout, boxWidth: 1000), 180)
        XCTAssertEqual(viewport.clamped(layout, boxWidth: 1000, boxHeight: 500).scrollX, 0)
    }

    func testScrollIsClampedToTheColumn() {
        let tall = ReaderViewport(zoom: 1, scrollX: 0, scrollY: 5000)
            .clamped(layout, boxWidth: 640, boxHeight: 500)
        XCTAssertEqual(tall.scrollY, 1650 - 500)
        XCTAssertEqual(ReaderViewport(zoom: 1, scrollY: -40).clamped(layout, boxWidth: 640, boxHeight: 500).scrollY, 0)
        XCTAssertEqual(ReaderViewport(zoom: 1, scrollY: 300).clamped(layout, boxWidth: 640, boxHeight: 4000).scrollY, 0,
                       "a column shorter than the window does not scroll")
    }

    /// The point under the pointer stays under it, which is the whole of
    /// what makes a wheel zoom feel anchored.
    func testZoomKeepsTheAnchorStill() {
        let before = ReaderViewport(zoom: 1, scrollX: 0, scrollY: 400)
        let anchor = (x: 200.0, y: 150.0)
        let point = before.documentPoint(layout, boxWidth: 640, x: anchor.x, y: anchor.y)
        let after = before.zoomed(to: 2, anchorX: anchor.x, anchorY: anchor.y, layout, boxWidth: 640, boxHeight: 500)
        let again = after.documentPoint(layout, boxWidth: 640, x: anchor.x, y: anchor.y)
        XCTAssertEqual(after.zoom, 2)
        XCTAssertEqual(again.x, point.x, accuracy: 1e-9)
        XCTAssertEqual(again.y, point.y, accuracy: 1e-9)
    }

    func testVisibleRectAndCurrentPage() {
        let viewport = ReaderViewport(zoom: 2, scrollX: 0, scrollY: 1700)
        let visible = viewport.visible(layout, boxWidth: 1280, boxHeight: 600)
        XCTAssertEqual(visible, Box(x: 0, y: 850, width: 640, height: 300))
        XCTAssertEqual(viewport.currentPage(layout, boxWidth: 1280, boxHeight: 600), 1, "middle at y=1000")
        XCTAssertEqual(ReaderViewport(zoom: 1).currentPage(layout, boxWidth: 640, boxHeight: 600), 0)
    }

    func testFits() {
        XCTAssertEqual(ReaderViewport.fitWidth(layout, boxWidth: 1280), 2)
        // Height-bound: 800 + 2·20 into 420.
        XCTAssertEqual(ReaderViewport.fitPage(layout, boxWidth: 1280, boxHeight: 420), 0.5)
    }

    func testLadderSteps() {
        let actual = ReaderViewport.actualSize
        XCTAssertEqual(ReaderViewport.stepped(actual, by: 1), 1.1 * actual, accuracy: 1e-9)
        XCTAssertEqual(ReaderViewport.stepped(actual, by: -1), 0.9 * actual, accuracy: 1e-9)
        // From between two rungs, the next one in that direction.
        XCTAssertEqual(ReaderViewport.stepped(1.05 * actual, by: 1), 1.1 * actual, accuracy: 1e-9)
        XCTAssertEqual(ReaderViewport.stepped(100, by: 1), 10 * actual, accuracy: 1e-9, "pinned at the top")
        XCTAssertEqual(ReaderViewport(zoom: actual).percent, 100)
    }

    func testShowingAndRevealing() {
        let start = ReaderViewport(zoom: 1)
        XCTAssertEqual(start.showing(page: 1, layout, boxWidth: 640, boxHeight: 500).scrollY, 830 - 12)
        // A match below the window comes up to just inside the bottom.
        let match = Box(x: 50, y: 900, width: 40, height: 10)
        XCTAssertEqual(start.revealing(match, margin: 20, layout, boxWidth: 640, boxHeight: 500).scrollY, 910 + 20 - 500)
        // One already on screen moves nothing.
        let near = Box(x: 50, y: 100, width: 40, height: 10)
        XCTAssertEqual(start.revealing(near, layout, boxWidth: 640, boxHeight: 500), start)
    }
}
