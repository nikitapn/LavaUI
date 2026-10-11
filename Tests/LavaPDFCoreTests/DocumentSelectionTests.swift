import XCTest

@testable import LavaPDFCore

final class DocumentSelectionTests: XCTestCase {
    private func p(_ page: Int, _ index: Int) -> TextPosition { TextPosition(page: page, index: index) }

    func testOnePage() {
        let selection = DocumentSelection(anchor: p(2, 10), head: p(2, 4))
        XCTAssertEqual(selection.range(onPage: 2, count: 50), 4...10, "a backwards drag")
        XCTAssertNil(selection.range(onPage: 1, count: 50))
        XCTAssertNil(selection.range(onPage: 3, count: 50))
    }

    /// The pages between the ends are whole, the ends are partial, in either
    /// direction of drag.
    func testAcrossPages() {
        for selection in [DocumentSelection(anchor: p(1, 30), head: p(3, 5)),
                          DocumentSelection(anchor: p(3, 5), head: p(1, 30))] {
            XCTAssertEqual(selection.pages, 1...3)
            XCTAssertEqual(selection.range(onPage: 1, count: 40), 30...39)
            XCTAssertEqual(selection.range(onPage: 2, count: 12), 0...11)
            XCTAssertEqual(selection.range(onPage: 3, count: 20), 0...5)
        }
    }

    func testEndOfPageAndEmptyPages() {
        let all = DocumentSelection.all(pageCount: 4)
        XCTAssertEqual(all.range(onPage: 3, count: 7), 0...6, "end means the end, whatever the length")
        XCTAssertNil(all.range(onPage: 2, count: 0), "a scanned page has nothing to select")
        // An anchor past the end of a short page still starts at its last
        // character rather than selecting nothing there.
        let past = DocumentSelection(anchor: p(0, 99), head: p(1, 2))
        XCTAssertEqual(past.range(onPage: 0, count: 10), 9...9)
    }

    func testNearestPage() {
        let layout = PageLayout(
            pageSizes: [PageSize(width: 100, height: 100), PageSize(width: 100, height: 100)],
            gap: 20, margin: 10
        )
        // Pages at 10…110 and 130…230.
        XCTAssertEqual(layout.nearestPage(toY: 50), 0)
        XCTAssertEqual(layout.nearestPage(toY: 115), 0, "the gap, nearer the first")
        XCTAssertEqual(layout.nearestPage(toY: 125), 1, "the gap, nearer the second")
        XCTAssertEqual(layout.nearestPage(toY: -500), 0, "above the column")
        XCTAssertEqual(layout.nearestPage(toY: 9000), 1, "below it")
        XCTAssertEqual(layout.nearestPage(toY: -90000), 0, "far above it")
        XCTAssertNil(PageLayout(pageSizes: []).nearestPage(toY: 0))
    }
}
