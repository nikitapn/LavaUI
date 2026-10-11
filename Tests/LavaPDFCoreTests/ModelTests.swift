import XCTest

@testable import LavaPDFCore

/// The pure halves: text geometry, layout and tiles, with no PDF behind them.
final class PageTextTests: XCTestCase {
    /// "ab cd" on one line, "ef" on the next. Each character a 10×12 box.
    private func sample() -> PageText {
        func c(_ s: String, _ x: Double, _ y: Double, end: Bool = false, space: Bool = false) -> PageCharacter {
            PageCharacter(unit: s.utf16.first!, box: Box(x: x, y: y, width: 10, height: 12),
                          endsWord: end, spaceAfter: space)
        }
        return PageText(characters: [
            c("a", 0, 0), c("b", 10, 0, end: true, space: true),
            c("c", 30, 0), c("d", 40, 0, end: true, space: true),
            c("e", 0, 20), c("f", 10, 20, end: true),
        ])
    }

    func testStringHasSeparators() {
        XCTAssertEqual(sample().string, "ab cd\nef")
    }

    /// A running header: two words on one line, far apart, and no space
    /// between them as far as the PDF says. They must not run together.
    func testFarApartWordsOnOneLineGetASpace() {
        let text = PageText(characters: [
            PageCharacter(unit: 0x61, box: Box(x: 0, y: 0, width: 10, height: 12), endsWord: true),
            PageCharacter(unit: 0x62, box: Box(x: 300, y: 0, width: 10, height: 12), endsWord: true),
            // Kerned tight against the one before: still one word's worth of
            // nothing, so nothing is inserted.
            PageCharacter(unit: 0x63, box: Box(x: 311, y: 0, width: 10, height: 12), endsWord: true),
        ])
        XCTAssertEqual(text.string, "a bc")
    }

    func testIndexUnderThePointer() {
        let text = sample()
        XCTAssertEqual(text.index(nearestX: 15, y: 5), 1, "inside b")
        XCTAssertEqual(text.index(nearestX: 25, y: 5), 1, "the gap: nearest on the line")
        // Far past the end of line 1, but scaleKey with it: the line's last
        // character, not "f", which is nearer as the crow flies.
        XCTAssertEqual(text.index(nearestX: 200, y: 5), 3)
        XCTAssertEqual(text.index(nearestX: 5, y: 100), 4, "below everything")
        XCTAssertNil(PageText(characters: []).index(nearestX: 0, y: 0))
    }

    func testSelectionPaintsOneBarPerLine() {
        let boxes = sample().boxes(for: 1...4)
        XCTAssertEqual(boxes, [
            Box(x: 10, y: 0, width: 40, height: 12),
            Box(x: 0, y: 20, width: 10, height: 12),
        ])
    }

    func testCopyIncludesSeparatorsBetweenButNotAfter() {
        let text = sample()
        XCTAssertEqual(text.text(in: 1...4), "b cd\ne")
        XCTAssertEqual(text.text(in: 0...1), "ab")
        XCTAssertEqual(text.text(in: 3...99), "d\nef", "clamped to the page")
    }

    func testWordForADoubleClick() {
        let text = sample()
        XCTAssertEqual(text.word(containing: 2), 2...3)
        XCTAssertEqual(text.word(containing: 5), 4...5)
        XCTAssertNil(text.word(containing: 6))
    }

    func testFindAcrossCaseAndLineBreaks() {
        let text = sample()
        XCTAssertEqual(text.find("CD"), [2...3])
        // "d" ends line one and "e" starts line two; the line break is a
        // space as far as a search is concerned.
        XCTAssertEqual(text.find("d e"), [3...4])
        XCTAssertEqual(text.find("zz"), [])
        XCTAssertEqual(text.find(" "), [], "a match of separators only selects nothing")
    }

    func testFindIgnoresAccents() {
        let text = PageText(characters: "café".utf16.enumerated().map {
            PageCharacter(unit: $0.element, box: Box(x: Double($0.offset) * 10, y: 0, width: 10, height: 12))
        })
        XCTAssertEqual(text.find("cafe"), [0...3])
    }
}

final class PageLayoutTests: XCTestCase {
    private let layout = PageLayout(
        pageSizes: [
            PageSize(width: 600, height: 800),
            PageSize(width: 800, height: 600),
            PageSize(width: 600, height: 800),
        ],
        gap: 10, margin: 20
    )

    func testPagesStackAndCentreOnTheWidest() {
        XCTAssertEqual(layout.frames[0], Box(x: 120, y: 20, width: 600, height: 800))
        XCTAssertEqual(layout.frames[1], Box(x: 20, y: 830, width: 800, height: 600))
        XCTAssertEqual(layout.frames[2].y, 1440)
        XCTAssertEqual(layout.width, 840)
        XCTAssertEqual(layout.height, 1440 + 800 + 20)
    }

    func testVisiblePages() {
        XCTAssertEqual(layout.pages(intersecting: Box(x: 0, y: 0, width: 840, height: 100)), 0..<1)
        XCTAssertEqual(layout.pages(intersecting: Box(x: 0, y: 700, width: 840, height: 200)), 0..<2)
        // Entirely in the gap between pages one and two.
        XCTAssertEqual(layout.pages(intersecting: Box(x: 0, y: 1431, width: 840, height: 8)), 2..<2)
        XCTAssertEqual(layout.pages(intersecting: Box(x: 0, y: 5000, width: 840, height: 100)), 3..<3)
    }

    func testPageUnderAPoint() {
        XCTAssertEqual(layout.page(atX: 400, y: 400), 0)
        XCTAssertNil(layout.page(atX: 50, y: 400), "margin beside a narrow page")
        XCTAssertNil(layout.page(atX: 400, y: 825), "the gap")
        XCTAssertEqual(layout.page(atX: 50, y: 1000), 1)
    }
}

final class TileGridTests: XCTestCase {
    /// Exact to 1/1024, so a tile is drawn 1:1 at the zoom it was asked for.
    func testScaleKeysAreExact() {
        XCTAssertEqual(TileGrid.scaleKey(forScale: 1), 1024)
        XCTAssertEqual(TileGrid.scaleKey(forScale: 1.5875), 1626)
        XCTAssertEqual(TileGrid.scale(ofKey: 2048), 2)
        XCTAssertEqual(TileGrid.scaleKey(forScale: 1e9), TileGrid.scaleKeys.upperBound)
        XCTAssertEqual(TileGrid.scaleKey(forScale: 0), 1024, "nonsense renders at 1×")
    }

    /// A preview is about a quarter of the scale, and nearby zooms share one.
    func testPreviewsAreCoarseAndShared() {
        let at150 = TileGrid.previewKey(for: TileGrid.scaleKey(forScale: 1.50))
        let at152 = TileGrid.previewKey(for: TileGrid.scaleKey(forScale: 1.52))
        XCTAssertEqual(at150, at152)
        let scale = TileGrid.scale(ofKey: at150)
        XCTAssertTrue(scale <= 1.5 / 4 && scale > 1.5 / 4 / 2.0.squareRoot(), "\(scale)")
    }

    func testTilesCoverTheVisiblePartNearestFirst() {
        // 1024×1024 points at 1× is 2×2 tiles of 512.
        let size = PageSize(width: 1024, height: 1024)
        let all = TileGrid.tiles(page: 0, size: size, scaleKey: 1024, visible: Box(x: 0, y: 0, width: 1024, height: 1024))
        XCTAssertEqual(Set(all.map { [$0.column, $0.row] }), [[0, 0], [1, 0], [0, 1], [1, 1]])

        let corner = TileGrid.tiles(page: 0, size: size, scaleKey: 1024, visible: Box(x: 600, y: 600, width: 100, height: 100))
        XCTAssertEqual(corner, [TileKey(page: 0, scaleKey: 1024, column: 1, row: 1)])

        // A strip across the middle row band, centred right of middle: the
        // right tile comes first.
        let strip = TileGrid.tiles(page: 3, size: size, scaleKey: 1024, visible: Box(x: 400, y: 0, width: 400, height: 100))
        XCTAssertEqual(strip.map(\.column), [1, 0])
        XCTAssertTrue(strip.allSatisfy { $0.page == 3 && $0.row == 0 })

        XCTAssertEqual(TileGrid.tiles(page: 0, size: size, scaleKey: 1024, visible: Box(x: 2000, y: 0, width: 10, height: 10)), [])
    }

    func testEdgeTilesStopAtThePage() {
        // 700 points at 1× is one full tile and one of 188.
        let size = PageSize(width: 700, height: 700)
        let edge = TileKey(page: 0, scaleKey: 1024, column: 1, row: 1)
        let rect = TileGrid.pixelRect(of: edge, size: size)
        XCTAssertEqual(rect.x, 512)
        XCTAssertEqual(rect.width, 188)
        XCTAssertEqual(rect.height, 188)
        XCTAssertEqual(TileGrid.pointRect(of: edge, size: size), Box(x: 512, y: 512, width: 188, height: 188))

        // At scaleKey 2 (2×) the same corner of the page is a different tile.
        let sharp = TileKey(page: 0, scaleKey: 2048, column: 2, row: 2)
        XCTAssertEqual(TileGrid.pointRect(of: sharp, size: size), Box(x: 512, y: 512, width: 188, height: 188))
    }

    func testBatchesRenderEachPageOnce() {
        // 1024² points at 1×: 2×2 tiles. Three of them asked for, page 0;
        // one of page 1.
        let size = PageSize(width: 1024, height: 1024)
        let keys = [
            TileKey(page: 1, scaleKey: 1024, column: 0, row: 0),
            TileKey(page: 0, scaleKey: 1024, column: 1, row: 1),
            TileKey(page: 0, scaleKey: 1024, column: 0, row: 0),
            TileKey(page: 0, scaleKey: 1024, column: 1, row: 0),
        ]
        let batches = TileGrid.batches(for: keys, sizes: { _ in size })
        XCTAssertEqual(batches.count, 2)
        XCTAssertEqual(batches[0].page, 1, "the first tile asked for leads")
        XCTAssertEqual(batches[1].page, 0)
        XCTAssertEqual(batches[1].tiles.count, 3)
        XCTAssertEqual([batches[1].x, batches[1].y, batches[1].width, batches[1].height], [0, 0, 1024, 1024])
    }

    func testBatchesSplitIntoBandsUnderTheBudget() {
        // Four rows of four tiles, with room for two rows per band.
        let size = PageSize(width: 2048, height: 2048)
        let keys = (0..<4).flatMap { row in (0..<4).map { TileKey(page: 0, scaleKey: 1024, column: $0, row: row) } }
        let batches = TileGrid.batches(for: keys, sizes: { _ in size }, maxPixels: 2048 * 1024)
        XCTAssertEqual(batches.map(\.y), [0, 1024])
        XCTAssertTrue(batches.allSatisfy { $0.width * $0.height <= 2048 * 1024 && $0.tiles.count == 8 })
    }

    func testBatchesDoNotRenderAGapBetweenRows() {
        let size = PageSize(width: 512, height: 2048)
        let keys = [TileKey(page: 0, scaleKey: 1024, column: 0, row: 0), TileKey(page: 0, scaleKey: 1024, column: 0, row: 3)]
        let batches = TileGrid.batches(for: keys, sizes: { _ in size })
        XCTAssertEqual(batches.map(\.y), [0, 1536])
        XCTAssertEqual(batches.map(\.height), [512, 512])
    }

    func testEdgeBatchStopsAtThePage() {
        let size = PageSize(width: 700, height: 300)
        let keys = [TileKey(page: 0, scaleKey: 1024, column: 0, row: 0), TileKey(page: 0, scaleKey: 1024, column: 1, row: 0)]
        let batch = TileGrid.batches(for: keys, sizes: { _ in size })[0]
        XCTAssertEqual([batch.width, batch.height], [700, 300])
    }
}
