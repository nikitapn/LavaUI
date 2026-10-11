import Foundation
import XCTest

@testable import LavaPDFCore

final class PDFDocumentTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lavapdf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func file(_ pages: [TestPDF.Page], title: String? = nil) throws -> String {
        let url = directory.appendingPathComponent("\(UUID().uuidString).pdf")
        try TestPDF.write(pages, title: title, to: url)
        return url.path
    }

    // ─── Opening ─────────────────────────────────────────────────────────

    func testOpensAndMeasuresEveryPage() throws {
        let path = try file([
            TestPDF.Page(width: 612, height: 792),
            TestPDF.Page(width: 842, height: 595),
        ], title: "Two pages")
        let document = try PDFDocument(path: path)
        XCTAssertEqual(document.pageCount, 2)
        XCTAssertEqual(document.pageSizes[0], PageSize(width: 612, height: 792))
        XCTAssertEqual(document.pageSizes[1], PageSize(width: 842, height: 595))
        XCTAssertEqual(document.title, "Two pages")
    }

    /// A page turned by its own /Rotate is measured the way it is seen.
    func testRotatedPageIsMeasuredTurned() throws {
        let document = try PDFDocument(path: file([TestPDF.Page(width: 612, height: 792, rotate: 90)]))
        XCTAssertEqual(document.pageSizes[0], PageSize(width: 792, height: 612))
    }

    func testMissingAndBrokenFilesSayWhich() throws {
        XCTAssertThrowsError(try PDFDocument(path: directory.appendingPathComponent("none.pdf").path)) {
            XCTAssertEqual($0 as? PDFOpenError, .notFound)
        }
        let junk = directory.appendingPathComponent("junk.pdf")
        try Data("this is not a pdf".utf8).write(to: junk)
        XCTAssertThrowsError(try PDFDocument(path: junk.path)) {
            XCTAssertEqual($0 as? PDFOpenError, .unreadable)
        }
    }

    // ─── Rendering ───────────────────────────────────────────────────────

    /// The square lands where the PDF put it, at the scale asked for, and the
    /// bytes are BGRX: black is black, paper is white and opaque.
    func testRenderPlacesContentAtScale() throws {
        // A 20pt square whose top-left is 100pt in and 100pt down from the
        // top of a 300×300 page — PDF measures from the bottom, hence 180.
        let path = try file([TestPDF.Page(width: 300, height: 300, square: (100, 180, 20))])
        let document = try PDFDocument(path: path)
        let pixels = try XCTUnwrap(document.render(page: 0, scale: 2, x: 0, y: 0, width: 600, height: 600))
        XCTAssertEqual(pixels.width, 600)
        XCTAssertEqual(pixels.stride, 2400)

        func pixel(_ x: Int, _ y: Int) -> [UInt8] {
            let i = y * pixels.stride + x * 4
            return Array(pixels.bytes[i..<(i + 4)])
        }
        XCTAssertEqual(pixel(220, 220), [0, 0, 0, 255], "inside the square, at 2× (200–240)")
        XCTAssertEqual(pixel(190, 220), [255, 255, 255, 255], "left of it")
        XCTAssertEqual(pixel(245, 220), [255, 255, 255, 255], "right of it")
    }

    /// A tile is a window onto the full render, not a squashed copy of it.
    func testRenderWindowMatchesTheWholePage() throws {
        let path = try file([TestPDF.Page(width: 300, height: 300, square: (100, 180, 20))])
        let document = try PDFDocument(path: path)
        let whole = try XCTUnwrap(document.render(page: 0, scale: 2, x: 0, y: 0, width: 600, height: 600))
        let tile = try XCTUnwrap(document.render(page: 0, scale: 2, x: 150, y: 150, width: 128, height: 128))
        for (tx, ty) in [(0, 0), (60, 60), (75, 80), (127, 127)] {
            let a = (ty + 150) * whole.stride + (tx + 150) * 4
            let b = ty * tile.stride + tx * 4
            XCTAssertEqual(Array(whole.bytes[a..<(a + 4)]), Array(tile.bytes[b..<(b + 4)]), "(\(tx), \(ty))")
        }
    }

    /// A window running off the page is paper past the edge, never whatever
    /// the buffer held.
    func testRenderPastTheEdgeIsPaper() throws {
        let document = try PDFDocument(path: file([TestPDF.Page(width: 100, height: 100)]))
        let pixels = try XCTUnwrap(document.render(page: 0, scale: 1, x: 50, y: 50, width: 100, height: 100))
        let corner = 99 * pixels.stride + 99 * 4
        XCTAssertEqual(Array(pixels.bytes[corner..<(corner + 4)]), [255, 255, 255, 255])
    }

    func testRenderRefusesPagesThatDoNotExist() throws {
        let document = try PDFDocument(path: file([TestPDF.Page()]))
        XCTAssertNil(document.render(page: 1, scale: 1, x: 0, y: 0, width: 10, height: 10))
        XCTAssertNil(document.render(page: -1, scale: 1, x: 0, y: 0, width: 10, height: 10))
    }

    // ─── Text ────────────────────────────────────────────────────────────

    func testTextComesBackWithSpacesAndLineBreaks() throws {
        let path = try file([TestPDF.Page(lines: [
            (72, 700, 24, "Hello world"),
            (72, 660, 24, "second line"),
        ])])
        let text = try PDFDocument(path: path).text(page: 0)
        XCTAssertEqual(text.string, "Hello world\nsecond line")
        XCTAssertEqual(text.characters.count, "Helloworldsecondline".count)
    }

    /// Text boxes are in the same space the page is rendered in — measured
    /// from the top, after the page's rotation — or a selection highlight is
    /// painted somewhere other than the words it selected.
    func testTextBoxesAgreeWithTheRender() throws {
        for rotate in [0, 90] {
            let path = try file([TestPDF.Page(
                width: 400, height: 300, rotate: rotate, lines: [(50, 200, 40, "Ink")]
            )])
            let document = try PDFDocument(path: path)
            let text = document.text(page: 0)
            let size = document.pageSizes[0]
            let box = try XCTUnwrap(text.characters.first?.box, "rotate \(rotate)")
            XCTAssertTrue(box.x >= 0 && box.maxX <= size.width && box.y >= 0 && box.maxY <= size.height,
                          "rotate \(rotate): \(box) outside \(size)")

            let pixels = try XCTUnwrap(document.render(
                page: 0, scale: 1, x: 0, y: 0, width: Int(size.width), height: Int(size.height)
            ))
            var inked = 0
            for y in Int(box.y)..<Int(box.maxY) {
                for x in Int(box.x)..<Int(box.maxX) where pixels.bytes[y * pixels.stride + x * 4] < 128 {
                    inked += 1
                }
            }
            XCTAssertGreaterThan(inked, 20, "rotate \(rotate): no ink inside the box of \"I\"")
        }
    }

    func testPageWithNoTextIsEmpty() throws {
        let document = try PDFDocument(path: file([TestPDF.Page(square: (10, 10, 10))]))
        XCTAssertTrue(document.text(page: 0).isEmpty)
        XCTAssertEqual(document.text(page: 0).string, "")
    }
}
