import CxxCanvas
import XCTest

@testable import LavaText
@testable import LavaUI

/// Windowed soft wrap — `LeafNode.planWrap` / `breakWrapWindow`.
///
/// Wrapping costs the whole buffer: every line has to be broken to know how
/// tall the document is. Doing that between a keystroke and the frame that
/// answers it is what made turning wrap on take four seconds on a 4 MB log.
/// So a pass breaks what the viewport can reach — exactly — and leaves the
/// rest provisional, one row a line, finishing it over later frames.
///
/// Two things therefore have to hold, and neither is obvious from the code:
/// what is on screen is never provisional, and the refinement lands on the
/// same table an eager pass would have built.
final class WrappedWindowTests: XCTestCase {
    private static let viewport: (w: Float, h: Float) = (300, 200)

    /// Long enough that a 300pt box breaks each line several times, and
    /// numerous enough to be well past the window either way.
    private static let text = (0..<1200)
        .map { "line \($0) " + String(repeating: "wrap ", count: 24) }
        .joined(separator: "\n")

    private var editor: Editor!
    private var host: LayoutHost!
    private var box = WrappedWindowTests.text
    private var savedBudget: Double = 0

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
        host = LayoutHost()
        box = Self.text
        savedBudget = LeafNode.wrapBudget
    }

    override func tearDown() {
        LeafNode.wrapBudget = savedBudget
        host = nil
        editor = nil
        super.tearDown()
    }

    private var binding: Binding<String> {
        Binding(get: { self.box }, set: { self.box = $0 })
    }

    /// One layout + one emit: one wrap pass.
    @discardableResult
    private func pass() throws -> LeafNode {
        host.setRoot(
            VStack(width: .pt(Self.viewport.w), height: .pt(Self.viewport.h)) {
                EditorView(text: binding, wraps: true, visibleLines: 8)
            }
        )
        _ = host.calculateLayout(width: Self.viewport.w, height: Self.viewport.h)
        let root = try XCTUnwrap(host.rootNode)
        let list = DrawList(editor: editor)
        list.clear()
        list.emitTree(root, viewportW: Self.viewport.w, viewportH: Self.viewport.h)

        func walk(_ node: any AnyViewNode) -> LeafNode? {
            if let leaf = node as? LeafNode, leaf.kind == .editor { return leaf }
            for child in node.childNodes {
                if let hit = walk(child) { return hit }
            }
            return nil
        }
        return try XCTUnwrap(walk(root))
    }

    /// The table an eager pass would build, computed here rather than by the
    /// code under test — otherwise "converges" would only mean "agrees with
    /// itself".
    private func eagerRows(_ leaf: LeafNode, font: UIFont) -> [Range<Int>] {
        let inner = max(8, Self.viewport.w - leaf.gutterWidth - leaf.textInset * 2)
        var rows: [Range<Int>] = []
        var base = 0
        for line in leaf.editing.text.split(separator: "\n", omittingEmptySubsequences: false) {
            let s = String(line)
            let broken = SoftWrap.rows(
                text: s, advances: font.shapedRun(s).characterAdvances, maxWidth: inner
            )
            for r in broken {
                rows.append((base + r.lowerBound)..<(base + r.upperBound))
            }
            base += s.count + 1
        }
        return rows
    }

    /// Drives passes until nothing is provisional, or gives up loudly.
    @discardableResult
    private func settleWrap(limit: Int = 400) throws -> LeafNode {
        var leaf = try pass()
        var passes = 1
        while leaf.wrapUnmeasured > 0 {
            XCTAssertLessThan(passes, limit, "the refinement never finished")
            if passes >= limit { break }
            leaf = try pass()
            passes += 1
        }
        return leaf
    }

    // MARK: The window

    func testAPassLeavesMostOfTheBufferUnbroken() throws {
        LeafNode.wrapBudget = 0
        let leaf = try pass()
        XCTAssertGreaterThan(
            leaf.wrapUnmeasured, 0,
            "the whole buffer was broken in one pass; the window is not doing anything"
        )
        XCTAssertLessThan(
            leaf.wrapUnmeasured, leaf.wrapCacheRows.count,
            "nothing at all was broken"
        )
    }

    /// The rows the viewport can reach must be real breaks, not the whole
    /// line standing in for itself — a provisional row would draw straight
    /// out of the box.
    func testEveryVisibleRowIsARealBreak() throws {
        LeafNode.wrapBudget = 0
        let leaf = try pass()
        let font = try XCTUnwrap(leaf.font ?? FontStore.default)
        let exact = Set(eagerRows(leaf, font: font))

        let rows = leaf.editing.layout.rows
        let lineHeight = font.lineHeight
        let first = max(0, Int(leaf.scrollY / lineHeight))
        let last = min(rows.count - 1, Int((leaf.scrollY + leaf.viewportHeight) / lineHeight) + 1)
        XCTAssertGreaterThan(last, first, "nothing was visible to check")
        for row in first...last {
            XCTAssertTrue(
                exact.contains(rows[row]),
                "visible row \(row) \(rows[row]) is not a break an eager pass would make"
            )
        }
    }

    /// And scrolling somewhere new must bring that window into focus too,
    /// not just the one the editor happened to mount at.
    func testScrollingBringsANewWindowIntoFocus() throws {
        LeafNode.wrapBudget = 0
        var leaf = try pass()
        let font = try XCTUnwrap(leaf.font ?? FontStore.default)
        let lineHeight = font.lineHeight

        leaf.scrollY = Float(leaf.editing.layout.count / 2) * lineHeight
        leaf = try pass()

        let exact = Set(eagerRows(leaf, font: font))
        let rows = leaf.editing.layout.rows
        let first = max(0, Int(leaf.scrollY / lineHeight))
        let last = min(rows.count - 1, Int((leaf.scrollY + leaf.viewportHeight) / lineHeight) + 1)
        for row in first...last {
            XCTAssertTrue(
                exact.contains(rows[row]),
                "row \(row) under the new scroll position was never broken"
            )
        }
    }

    // MARK: The refinement

    func testRefinementConvergesOnTheEagerTable() throws {
        let leaf = try settleWrap()
        let font = try XCTUnwrap(leaf.font ?? FontStore.default)
        XCTAssertEqual(leaf.wrapUnmeasured, 0)
        XCTAssertEqual(
            leaf.editing.layout.rows, eagerRows(leaf, font: font),
            "the settled table is not the one an eager wrap would have built"
        )
    }

    /// Row and line have to keep agreeing once every line is broken, or the
    /// gutter numbers the wraps.
    func testTheSettledTableStillMapsRowsToLines() throws {
        let leaf = try settleWrap()
        XCTAssertEqual(leaf.logicalLineCount, 1200)
        let rows = leaf.editing.layout.rows
        XCTAssertEqual(leaf.rowLogicalLine.count, rows.count)
        let numbered = (0..<rows.count).filter { leaf.isLineStart(ofRow: $0) }
        XCTAssertEqual(numbered.count, 1200, "one number per logical line")
    }

    /// Rows above the viewport multiply as they are broken. Without an anchor
    /// the text creeps upward under the reader for as long as that runs.
    func testTheLineAtTheTopDoesNotDriftWhileRefining() throws {
        LeafNode.wrapBudget = 0
        var leaf = try pass()
        let font = try XCTUnwrap(leaf.font ?? FontStore.default)
        let lineHeight = font.lineHeight

        leaf.scrollY = Float(leaf.editing.layout.count / 3) * lineHeight
        leaf = try pass()
        let topLine = leaf.logicalLine(ofRow: Int(leaf.scrollY / lineHeight))

        LeafNode.wrapBudget = 0.004
        var passes = 0
        while leaf.wrapUnmeasured > 0, passes < 400 {
            leaf = try pass()
            passes += 1
            XCTAssertEqual(
                leaf.logicalLine(ofRow: Int(leaf.scrollY / lineHeight)), topLine,
                "the top line moved on refinement pass \(passes)"
            )
        }
        XCTAssertEqual(leaf.wrapUnmeasured, 0)
    }

    // MARK: Edits on top of a half-wrapped plan

    /// An edit re-plans, and the plan has to carry over what was already
    /// broken rather than starting again — and still land on the right table.
    func testAnEditOnAHalfWrappedPlanStillConverges() throws {
        LeafNode.wrapBudget = 0
        _ = try pass()
        LeafNode.wrapBudget = 0.004
        _ = try pass()

        box.insert(contentsOf: "a new first line\n", at: box.startIndex)
        let leaf = try settleWrap()
        let font = try XCTUnwrap(leaf.font ?? FontStore.default)
        XCTAssertEqual(leaf.logicalLineCount, 1201)
        XCTAssertEqual(leaf.editing.layout.rows, eagerRows(leaf, font: font))
    }

    /// A width change invalidates every break, so the plan starts over — and
    /// must not leave a line claiming the rows it had at the old width.
    func testAWidthChangeReplansFromNothing() throws {
        let wide = try settleWrap()
        let wideRows = wide.editing.layout.count

        host.setRoot(
            VStack(width: .pt(180), height: .pt(Self.viewport.h)) {
                EditorView(text: binding, wraps: true, visibleLines: 8)
            }
        )
        _ = host.calculateLayout(width: 180, height: Self.viewport.h)
        let root = try XCTUnwrap(host.rootNode)
        let list = DrawList(editor: editor)
        list.clear()
        list.emitTree(root, viewportW: 180, viewportH: Self.viewport.h)

        func walk(_ node: any AnyViewNode) -> LeafNode? {
            if let leaf = node as? LeafNode, leaf.kind == .editor { return leaf }
            for child in node.childNodes {
                if let hit = walk(child) { return hit }
            }
            return nil
        }
        var leaf = try XCTUnwrap(walk(root))
        XCTAssertGreaterThan(leaf.wrapUnmeasured, 0, "a narrower box has to re-break everything")
        var passes = 0
        while leaf.wrapUnmeasured > 0, passes < 400 {
            _ = host.calculateLayout(width: 180, height: Self.viewport.h)
            list.clear()
            list.emitTree(root, viewportW: 180, viewportH: Self.viewport.h)
            leaf = try XCTUnwrap(walk(root))
            passes += 1
        }
        XCTAssertGreaterThan(
            leaf.editing.layout.count, wideRows,
            "a narrower box has to produce more rows"
        )
    }
}
