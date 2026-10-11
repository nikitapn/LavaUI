import Foundation
import XCTest

@testable import LavaPDFCore

/// Outline and links against real files, written by `TestPDF`.
final class OutlineAndLinkTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lavapdf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func open(
        _ pages: [TestPDF.Page], outline: [TestPDF.Entry] = [],
        names: [String: (page: Int, top: Double)] = [:]
    ) throws -> PDFDocument {
        let url = directory.appendingPathComponent("\(UUID().uuidString).pdf")
        try TestPDF.write(pages, outline: outline, names: names, to: url)
        return try PDFDocument(path: url.path)
    }

    func testOutlineComesBackFlatWithDepthsAndTargets() throws {
        let document = try open(
            [TestPDF.Page(), TestPDF.Page(), TestPDF.Page()],
            outline: [
                TestPDF.Entry(title: "One", depth: 0, target: .page(0, top: 792), open: true),
                TestPDF.Entry(title: "One point one", depth: 1, target: .page(1, top: 500)),
                TestPDF.Entry(title: "Two", depth: 0, target: .named("two")),
                TestPDF.Entry(title: "Elsewhere", depth: 0, target: .uri("https://example.com")),
            ],
            names: ["two": (2, 700)]
        )
        let outline = document.outline()
        XCTAssertEqual(outline.items.map(\.title), ["One", "One point one", "Two", "Elsewhere"])
        XCTAssertEqual(outline.items.map(\.depth), [0, 1, 0, 0])
        XCTAssertEqual(outline.items[0].startsOpen, true)
        // Destinations as points from the page's top: 792 - 500 = 292.
        XCTAssertEqual(outline.items[0].target, .page(0, x: 50, y: 0))
        XCTAssertEqual(outline.items[1].target, .page(1, x: 50, y: 292))
        XCTAssertEqual(outline.items[2].target, .page(2, x: 50, y: 92), "named, looked up")
        XCTAssertEqual(outline.items[3].target, .uri("https://example.com"))
    }

    func testNoOutlineIsEmpty() throws {
        XCTAssertTrue(try open([TestPDF.Page()]).outline().isEmpty)
    }

    /// The click area is in the page's points from its top-left, the space
    /// text boxes and tiles are in — upright and turned.
    func testLinkBoxesAreInPageSpace() throws {
        let document = try open([
            TestPDF.Page(width: 400, height: 300, links: [
                (50, 200, 100, 20, .page(1, top: 300)),
                (50, 100, 100, 20, .uri("https://example.com/a")),
            ]),
            TestPDF.Page(width: 400, height: 300),
        ])
        let links = document.links(page: 0)
        XCTAssertEqual(links.count, 2)
        // PDF y 200…220 from the bottom of a 300 page is 80…100 from the top.
        XCTAssertEqual(links[0].box, Box(x: 50, y: 80, width: 100, height: 20))
        XCTAssertEqual(links[0].target, .page(1, x: 50, y: 0))
        XCTAssertEqual(links[1].target, .uri("https://example.com/a"))
        XCTAssertEqual(links.link(atX: 60, y: 90)?.target, .page(1, x: 50, y: 0))
        XCTAssertNil(links.link(atX: 60, y: 150))
        XCTAssertTrue(document.links(page: 1).isEmpty)
    }

    func testLinkBoxOnATurnedPage() throws {
        // A 400×300 page turned 90° is shown 300 wide and 400 tall, and a
        // rectangle near its unrotated bottom-left lands near the shown
        // top-left. The size is checked against the page and the box against
        // where the render puts the square drawn under it.
        let document = try open([
            TestPDF.Page(width: 400, height: 300, rotate: 90,
                         square: (50, 50, 40), links: [(50, 50, 40, 40, .uri("https://x"))]),
        ])
        let size = document.pageSizes[0]
        XCTAssertEqual(size, PageSize(width: 300, height: 400))
        let box = try XCTUnwrap(document.links(page: 0).first?.box)
        XCTAssertEqual(box.width, 40, accuracy: 0.01)
        XCTAssertEqual(box.height, 40, accuracy: 0.01)

        let pixels = try XCTUnwrap(document.render(page: 0, scale: 1, x: 0, y: 0, width: 300, height: 400))
        let centre = (x: Int(box.x + box.width / 2), y: Int(box.y + box.height / 2))
        XCTAssertEqual(pixels.bytes[centre.y * pixels.stride + centre.x * 4], 0,
                       "the square drawn under the link is under its box: \(box)")
    }

    // ─── The pure halves ─────────────────────────────────────────────────

    private let tree = Outline(items: [
        .init(title: "1", depth: 0, target: .page(0, x: nil, y: nil)),
        .init(title: "1.1", depth: 1, target: .page(1, x: nil, y: 100)),
        .init(title: "1.1.1", depth: 2, target: .page(1, x: nil, y: 400)),
        .init(title: "1.2", depth: 1, target: .page(3, x: nil, y: 0)),
        .init(title: "2", depth: 0, target: .page(5, x: nil, y: 0)),
    ])

    func testVisibleRowsFollowWhatIsOpen() {
        XCTAssertEqual(tree.visible(expanded: []), [0, 4])
        XCTAssertEqual(tree.visible(expanded: [0]), [0, 1, 3, 4])
        XCTAssertEqual(tree.visible(expanded: [0, 1]), [0, 1, 2, 3, 4])
        XCTAssertEqual(tree.visible(expanded: [1]), [0, 4], "a closed parent hides an open child")
        XCTAssertEqual(tree.initiallyExpanded, [0], "short outline: the top level opens")
    }

    func testAncestors() {
        XCTAssertEqual(tree.ancestors(of: 2), [0, 1])
        XCTAssertEqual(tree.ancestors(of: 3), [0])
        XCTAssertEqual(tree.ancestors(of: 4), [])
    }

    func testCurrentSection() {
        XCTAssertEqual(tree.current(page: 0, y: 0), 0)
        XCTAssertEqual(tree.current(page: 1, y: 50), 0, "above 1.1's heading")
        XCTAssertEqual(tree.current(page: 1, y: 200), 1)
        XCTAssertEqual(tree.current(page: 2, y: 0), 2)
        XCTAssertEqual(tree.current(page: 9, y: 0), 4)
    }
}
