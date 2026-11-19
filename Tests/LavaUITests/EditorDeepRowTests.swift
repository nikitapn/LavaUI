import CxxCanvas
import XCTest

@testable import LavaText
@testable import LavaUI

/// Rows far down a long document. A row's place is a document coordinate —
/// row × line height — and past 2^24 a `Float` holds only even numbers, which
/// a log of half a million lines at 31 px reaches. Placed from the document's
/// top, every odd product rounded a pixel up or down on its own, and the
/// spacing went 30, 32, 32, 30 down the screen.
final class EditorDeepRowTests: XCTestCase {
    private static let viewport: (w: Float, h: Float) = (400, 300)
    private static let text = (0..<800_000).map { "row \($0)" }.joined(separator: "\n")

    private var editor: Editor!
    private var box = EditorDeepRowTests.text

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
    }

    override func tearDown() {
        editor = nil
        super.tearDown()
    }

    func testRowsDeepInALongDocumentAreEvenlySpaced() throws {
        let controller = EditorController()
        let host = LayoutHost()
        let binding = Binding(get: { self.box }, set: { self.box = $0 })
        func pass() throws -> DrawList {
            host.setRoot(
                VStack(width: .pt(Self.viewport.w), height: .pt(Self.viewport.h)) {
                    EditorView(text: binding, visibleLines: 12, controller: controller)
                        .flexGrow(1)
                }
            )
            _ = host.calculateLayout(width: Self.viewport.w, height: Self.viewport.h)
            let list = DrawList(editor: editor)
            list.clear()
            list.emitTree(
                try XCTUnwrap(host.rootNode),
                viewportW: Self.viewport.w, viewportH: Self.viewport.h
            )
            return list
        }
        _ = try pass()
        // Past 2^24 / lineHeight — 730k rows at 23 px.
        controller.reveal(line: 760_001)
        let list = try pass()

        let lineHeight = try XCTUnwrap(FontStore.default).lineHeight
        XCTAssertGreaterThan(
            Float(760_001) * lineHeight, 16_777_216, "not deep enough to lose precision"
        )
        let tops = Set(
            (0..<list.commandCount).compactMap { list.emitted(at: $0) }
                .filter { $0.kind == .text }
                .map(\.y)
        ).sorted()
        XCTAssertGreaterThan(tops.count, 5)
        for (a, b) in zip(tops, tops.dropFirst()) {
            XCTAssertEqual(b - a, lineHeight, accuracy: 0.01, "rows at \(a) and \(b)")
        }
    }

    /// The same depth with wrap on, while the background refinement runs.
    /// Every frame of it holds the line at the top still — reads the top row
    /// and how far into it the view is, breaks rows above, and puts the
    /// offset back. Past 2^24 px the offset could not hold the fraction, and
    /// the text stepped up and down by a few pixels (half a line, at the
    /// size of a 200 MB log) on every frame until the refinement finished.
    func testAWrappedDocumentHoldsStillWhileTheRefinementRuns() throws {
        let saved = LeafNode.wrapBudget
        LeafNode.wrapBudget = 0.002
        defer { LeafNode.wrapBudget = saved }
        // Lines of every length, as in a real log, so the estimate for the
        // unbroken ones is wrong and breaking them moves the rows above the
        // view — which is what the offset then has to make up for. Past 2^24
        // px at 23 px a row, where a Float's step is 2.
        box = (0..<400_000)
            .map { "line \($0) " + String(repeating: "word ", count: ($0 &* 7919) % 31) }
            .joined(separator: "\n")
        let controller = EditorController()
        let host = LayoutHost()
        let binding = Binding(get: { self.box }, set: { self.box = $0 })
        func pass() throws -> LeafNode {
            host.setRoot(
                VStack(width: .pt(Self.viewport.w), height: .pt(Self.viewport.h)) {
                    EditorView(text: binding, wraps: true, visibleLines: 12, controller: controller)
                        .flexGrow(1)
                }
            )
            _ = host.calculateLayout(width: Self.viewport.w, height: Self.viewport.h)
            let root = try XCTUnwrap(host.rootNode)
            let list = DrawList(editor: editor)
            list.clear()
            list.emitTree(root, viewportW: Self.viewport.w, viewportH: Self.viewport.h)
            func walk(_ node: any AnyViewNode) -> LeafNode? {
                if let leaf = node as? LeafNode, leaf.kind == .editor { return leaf }
                for child in node.childNodes { if let hit = walk(child) { return hit } }
                return nil
            }
            return try XCTUnwrap(walk(root))
        }
        let lineHeight = try XCTUnwrap(FontStore.default).lineHeight
        // Where `offset`'s row is below the top of the view.
        func screenY(_ leaf: LeafNode, _ offset: Int) -> Double {
            Double(leaf.editing.layout.rowIndex(ofOffset: offset)) * Double(lineHeight)
                - Double(leaf.scrollY)
        }

        _ = try pass()
        controller.reveal(line: 390_000)
        var leaf = try pass()
        XCTAssertGreaterThan(
            Double(leaf.editing.layout.count) * Double(lineHeight), 16_777_216,
            "not deep enough to lose precision"
        )
        // Mid-row, so the fraction is something a Float has to hold.
        leaf.scrollY += 7
        leaf = try pass()
        let top = leaf.editing.layout.rows[
            Int((Double(leaf.scrollY) / Double(lineHeight)).rounded(.down))
        ].lowerBound
        let held = screenY(leaf, top)

        for frame in 0..<12 {
            XCTAssertGreaterThan(leaf.wrapUnmeasured, 0, "the refinement finished before frame \(frame)")
            leaf = try pass()
            XCTAssertEqual(screenY(leaf, top), held, accuracy: 0.01, "frame \(frame)")
        }
    }

    /// LavaEditor saves the position after every emit, scroll-only redraws
    /// included. With the caret at the top and the view at the end, reading
    /// it walked from the first visible row to the caret, and the next emit
    /// walked back: two passes over the buffer per scroll frame, which is a
    /// 200 MB log scrolling at a few frames a second until a click near the
    /// view put the caret there. Reading the position must leave the leaf's
    /// index anchor where the emitter put it.
    func testReadingThePositionDoesNotWalkToAFarCaret() throws {
        box = (0..<200_000).map { "row \($0)" }.joined(separator: "\n")
        let controller = EditorController()
        let host = LayoutHost()
        let binding = Binding(get: { self.box }, set: { self.box = $0 })
        func pass() throws -> LeafNode {
            host.setRoot(
                VStack(width: .pt(Self.viewport.w), height: .pt(Self.viewport.h)) {
                    EditorView(text: binding, visibleLines: 12, controller: controller)
                        .flexGrow(1)
                }
            )
            _ = host.calculateLayout(width: Self.viewport.w, height: Self.viewport.h)
            let root = try XCTUnwrap(host.rootNode)
            let list = DrawList(editor: editor)
            list.clear()
            list.emitTree(root, viewportW: Self.viewport.w, viewportH: Self.viewport.h)
            func walk(_ node: any AnyViewNode) -> LeafNode? {
                if let leaf = node as? LeafNode, leaf.kind == .editor { return leaf }
                for child in node.childNodes { if let hit = walk(child) { return hit } }
                return nil
            }
            return try XCTUnwrap(walk(root))
        }
        let lineHeight = try XCTUnwrap(FontStore.default).lineHeight

        for selection in [nil, (anchor: 3, focus: 9), (anchor: 9, focus: 3)] {
            var leaf = try pass()
            leaf.editing.setCursor(leaf.textIndex(atOffset: selection?.anchor ?? 0))
            if let selection {
                leaf.editing.setCursor(leaf.textIndex(atOffset: selection.focus), extending: true)
            }
            // The first read pays for the caret once; what is measured is
            // every read after it, which is every scroll frame.
            _ = controller.position()
            leaf.scrollY = leaf.maxScrollY(lineHeight: lineHeight)
            leaf = try pass()
            for _ in 0..<3 {
                // Where the emitter left it: the first visible row, which a
                // scroll moves along with the view.
                let viewAnchor = try XCTUnwrap(leaf.indexAnchor).offset
                XCTAssertGreaterThan(viewAnchor, box.utf8.count / 2, "the emitter did not anchor at the view")
                let position = try XCTUnwrap(controller.position())
                XCTAssertEqual(position.anchor, selection?.anchor ?? 0)
                XCTAssertEqual(position.focus, selection?.focus ?? 0)
                XCTAssertEqual(try XCTUnwrap(leaf.indexAnchor).offset, viewAnchor, "\(String(describing: selection))")
                leaf.scrollBy(-lineHeight * 3, lineHeight: lineHeight)
                leaf = try pass()
            }
        }
    }
}
