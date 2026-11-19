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

    /// Caret-follow must use wrapped rows immediately after Enter, not the
    /// temporary one-row-per-line table installed by the edit.
    func testNewlineInTheMiddleKeepsTheViewportStill() throws {
        let leaf = try settleWrap()
        try insertNewlineWithoutJump(leaf)
    }

    func testNewlineInAHalfWrappedDocumentKeepsTheViewportStill() throws {
        LeafNode.wrapBudget = 0
        let leaf = try pass()
        let font = try XCTUnwrap(leaf.font ?? FontStore.default)
        leaf.scrollY = Float(leaf.editing.layout.count / 2) * font.lineHeight
        _ = try pass()
        XCTAssertGreaterThan(leaf.wrapUnmeasured, 0)
        try insertNewlineWithoutJump(leaf)
    }

    private func insertNewlineWithoutJump(_ leaf: LeafNode) throws {
        let font = try XCTUnwrap(leaf.font ?? FontStore.default)
        let line = leaf.wrapUnmeasured == 0 ? 600
            : leaf.logicalLine(ofRow: Int(leaf.scrollY / font.lineHeight)) + 1
        let row = leaf.firstRow(ofLine: line)
        leaf.scrollY = Float(row - 2) * font.lineHeight + 0.25 * font.lineHeight
        leaf.editing.setCursor(leaf.editing.index(line: line, column: 0))
        leaf.focusSelf(binding: binding, onSubmit: nil)
        defer { FocusManager.resignFocus(leaf.id) }
        let before = leaf.scrollY
        let top = topLine(leaf, font: font)
        let wrapsBefore = PerfCounters.lineWraps

        XCTAssertTrue(FocusManager.handle(KeyEvent(key: KeyCode.enter, mods: 0)))
        XCTAssertEqual(leaf.scrollY, before, accuracy: 0.01,
                       "Enter followed a logical line instead of a wrapped row")
        _ = try pass()
        XCTAssertEqual(leaf.scrollY, before, accuracy: 0.01)
        XCTAssertEqual(topLine(leaf, font: font), top)
        XCTAssertLessThanOrEqual(PerfCounters.lineWraps - wrapsBefore, 4,
                                "the edit should only wrap the changed lines")
        let caret = leaf.editing.layout.rowIndex(ofOffset: leaf.editing.offset(of: leaf.editing.focus))
        XCTAssertGreaterThanOrEqual(Float(caret) * font.lineHeight, leaf.scrollY)
        XCTAssertLessThanOrEqual(Float(caret + 1) * font.lineHeight,
                                leaf.scrollY + leaf.viewportHeight - leaf.textInset * 2)
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

    // MARK: Resizing a wrapped, scrolled viewport

    /// One pass at `width`, the way a window being resized delivers it.
    @discardableResult
    private func pass(width: Float) throws -> LeafNode {
        host.setRoot(
            VStack(width: .pt(width), height: .pt(Self.viewport.h)) {
                EditorView(text: binding, wraps: true, visibleLines: 8)
            }
        )
        _ = host.calculateLayout(width: width, height: Self.viewport.h)
        let root = try XCTUnwrap(host.rootNode)
        let list = DrawList(editor: editor)
        list.clear()
        list.emitTree(root, viewportW: width, viewportH: Self.viewport.h)

        func walk(_ node: any AnyViewNode) -> LeafNode? {
            if let leaf = node as? LeafNode, leaf.kind == .editor { return leaf }
            for child in node.childNodes {
                if let hit = walk(child) { return hit }
            }
            return nil
        }
        return try XCTUnwrap(walk(root))
    }

    /// Where a character is, in pixels below the top of the view.
    private func screenY(of offset: Int, in leaf: LeafNode, lineHeight: Float) -> Float {
        Float(leaf.editing.layout.rowIndex(ofOffset: offset)) * lineHeight - leaf.scrollY
    }

    /// Dragging a window edge is a width change per pointer move, and every
    /// paragraph on screen grows or shrinks with it. What the reader is
    /// looking at has to stay where it is while that happens: with the caret
    /// off screen, the text in the middle of the view. Holding the *top*
    /// instead kept the line numbers still and slid what was being read off
    /// the bottom of the window as it narrowed; holding the top *line* snapped
    /// the text back and forth by the height of a paragraph at every step.
    func testResizingKeepsTheMiddleOfTheViewInPlace() throws {
        let leaf = try settleWrap()
        let lineHeight = try XCTUnwrap(FontStore.default).lineHeight
        leaf.scrollY = Float(leaf.editing.layout.count / 2) * lineHeight
        _ = try pass(width: Self.viewport.w)  // the caret (offset 0) is far above

        let visible = leaf.viewportHeight - leaf.textInset * 2
        let middleRow = Int((leaf.scrollY + visible / 2) / lineHeight)
        let held = leaf.editing.layout.rows[middleRow].lowerBound
        let heldY = screenY(of: held, in: leaf, lineHeight: lineHeight)

        for width: Float in [296, 290, 281, 270, 258, 246, 262, 279, 291] {
            let now = try pass(width: width)
            XCTAssertEqual(
                screenY(of: held, in: now, lineHeight: lineHeight), heldY, accuracy: lineHeight * 0.5,
                "at \(width)pt the text that was in the middle moved"
            )
        }
        // Back where it started: not a pixel of drift for the round trip.
        let back = try pass(width: Self.viewport.w)
        XCTAssertEqual(screenY(of: held, in: back, lineHeight: lineHeight), heldY, accuracy: 0.01)
    }

    /// With the caret on screen, the caret is what stays put: it is where the
    /// reader is looking, and the text being typed must not move under it.
    func testResizingKeepsAVisibleCaretInPlace() throws {
        let leaf = try settleWrap()
        let lineHeight = try XCTUnwrap(FontStore.default).lineHeight
        leaf.scrollY = Float(leaf.editing.layout.count / 3) * lineHeight
        _ = try pass(width: Self.viewport.w)
        // Two rows from the bottom of the view, so it is the caret and not
        // the middle that is being held.
        let visible = leaf.viewportHeight - leaf.textInset * 2
        let row = Int((leaf.scrollY + visible) / lineHeight) - 2
        let caret = leaf.editing.layout.rows[row].lowerBound + 3
        leaf.editing.setCursor(leaf.textIndex(atOffset: caret))
        let caretY = screenY(of: caret, in: leaf, lineHeight: lineHeight)

        for width: Float in [280, 250, 230, 260, 300] {
            let now = try pass(width: width)
            XCTAssertEqual(screenY(of: caret, in: now, lineHeight: lineHeight), caretY,
                           accuracy: lineHeight * 0.5, "at \(width)pt the caret moved")
            // And the caret is drawn there: the row it is cached on follows
            // the new table, not the one it was cached against.
            XCTAssertEqual(now.focusRow(), now.editing.layout.rowIndex(ofOffset: caret),
                           "at \(width)pt the caret row is stale")
        }
    }

    /// The text one frame draws: every text command's position and glyph
    /// count (`w` carries the count for text), in order.
    ///
    /// Laid out the way LavaEditor lays it out — growing to fill a box whose
    /// size is fixed — because then Yoga never calls the measure function,
    /// and the emitter's re-wrap is the only one there is. An editor that
    /// sizes itself is re-wrapped by the measure pass first, which hid the
    /// bug below from every test that built one.
    private func drawnText(width: Float) throws -> [[Float]] {
        host.setRoot(
            VStack(width: .pt(width), height: .pt(Self.viewport.h)) {
                EditorView(text: binding, wraps: true, visibleLines: 8).flexGrow(1)
            }
        )
        _ = host.calculateLayout(width: width, height: Self.viewport.h)
        let root = try XCTUnwrap(host.rootNode)
        let list = DrawList(editor: editor)
        list.clear()
        list.emitTree(root, viewportW: width, viewportH: Self.viewport.h)
        return (0..<list.commandCount).compactMap { list.emitted(at: $0) }
            .filter { $0.kind == .text }
            .map { [$0.x, $0.y, $0.w] }
    }

    /// The frame in which the width changes has to draw what the next frame
    /// at that width draws. It did not: the emitter copied the editing state
    /// before re-wrapping, so that one frame drew the *previous* width's rows
    /// at the scroll offset worked out for the new one — while the gutter,
    /// which reads the leaf's own tables, drew the new. A window drag is
    /// nothing but such frames, so the text flickered to the wrong place for
    /// as long as the edge moved and came back the moment it stopped.
    func testTheFrameThatChangesWidthDrawsTheNewRows() throws {
        let leaf = try settleWrap()
        let lineHeight = try XCTUnwrap(FontStore.default).lineHeight
        leaf.scrollY = Float(leaf.editing.layout.count / 2) * lineHeight
        _ = try drawnText(width: Self.viewport.w)

        for width: Float in [290, 270, 250, 275] {
            let changing = try drawnText(width: width)
            let settled = try drawnText(width: width)
            XCTAssertFalse(changing.isEmpty)
            XCTAssertEqual(changing, settled,
                           "at \(width)pt the resizing frame drew different text than the settled one")
        }
    }

    /// The anchor a drag holds is let go of the moment the reader scrolls, or
    /// the next resize would yank the view back to where the *previous* drag
    /// began.
    func testAScrollBetweenResizesIsWhatTheNextResizeHolds() throws {
        let leaf = try settleWrap()
        let lineHeight = try XCTUnwrap(FontStore.default).lineHeight
        leaf.scrollY = Float(leaf.editing.layout.count / 3) * lineHeight
        _ = try pass(width: 280)

        // Scrolled elsewhere, then resized again.
        let scrolled = try pass(width: 280)
        scrolled.scrollY = Float(scrolled.editing.layout.count * 2 / 3) * lineHeight
        let visible = scrolled.viewportHeight - scrolled.textInset * 2
        let middleRow = Int((scrolled.scrollY + visible / 2) / lineHeight)
        let target = scrolled.editing.layout.rows[middleRow].lowerBound
        let targetY = screenY(of: target, in: scrolled, lineHeight: lineHeight)

        let after = try pass(width: 300)
        XCTAssertEqual(screenY(of: target, in: after, lineHeight: lineHeight), targetY,
                       accuracy: lineHeight * 0.5,
                       "the resize should hold where the reader scrolled to, not the old anchor")
    }

    // MARK: Toggling the mode under a scrolled viewport

    /// One pass at `wraps`, re-rooting the tree the way a toggle does.
    @discardableResult
    private func pass(wraps: Bool) throws -> LeafNode {
        host.setRoot(
            VStack(width: .pt(Self.viewport.w), height: .pt(Self.viewport.h)) {
                EditorView(text: binding, wraps: wraps, visibleLines: 8)
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

    private func topLine(_ leaf: LeafNode, font: UIFont) -> Int {
        leaf.logicalLine(ofRow: max(0, Int(leaf.scrollY / font.lineHeight)))
    }

    /// `scrollY` is pixels over *row* indices, and a row is not a fixed thing.
    /// Turning wrapping off, row 6,000 stops being the six-thousandth wrapped
    /// row and becomes line 6,000 — four times further down the file, and on
    /// a long one the clamp turns that into the end of it. The reader was
    /// looking at a *line*, and that is what has to survive.
    func testTurningWrapOffKeepsTheLineAtTheTop() throws {
        var leaf = try settleWrap()
        let font = try XCTUnwrap(leaf.font ?? FontStore.default)

        // Somewhere well into the file, where wrapped rows and lines have
        // diverged enough for the bug to be unmissable.
        leaf.scrollY = Float(leaf.editing.layout.count / 2) * font.lineHeight
        leaf = try pass(wraps: true)
        let before = topLine(leaf, font: font)
        XCTAssertGreaterThan(before, 100, "not deep enough into the file to be a test")

        leaf = try pass(wraps: false)
        XCTAssertEqual(topLine(leaf, font: font), before, "wrap off moved the reader")
    }

    func testTurningWrapOnKeepsTheLineAtTheTop() throws {
        var leaf = try pass(wraps: false)
        let font = try XCTUnwrap(leaf.font ?? FontStore.default)

        leaf.scrollY = Float(600) * font.lineHeight
        leaf = try pass(wraps: false)
        let before = topLine(leaf, font: font)
        XCTAssertEqual(before, 600)

        leaf = try pass(wraps: true)
        XCTAssertEqual(topLine(leaf, font: font), before, "wrap on moved the reader")

        // And it stays put while the rest of the file is broken behind it.
        var passes = 0
        while leaf.wrapUnmeasured > 0, passes < 400 {
            leaf = try pass(wraps: true)
            passes += 1
            XCTAssertEqual(
                topLine(leaf, font: font), before,
                "the top line moved on refinement pass \(passes)"
            )
        }
    }

    /// A resize re-breaks every line, so it has the same problem and the same
    /// answer.
    func testANarrowerBoxKeepsTheLineAtTheTop() throws {
        var leaf = try settleWrap()
        let font = try XCTUnwrap(leaf.font ?? FontStore.default)
        leaf.scrollY = Float(leaf.editing.layout.count / 2) * font.lineHeight
        leaf = try pass(wraps: true)
        let before = topLine(leaf, font: font)

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
        let narrow = try XCTUnwrap(walk(root))
        XCTAssertEqual(topLine(narrow, font: font), before, "the resize moved the reader")
    }
}

