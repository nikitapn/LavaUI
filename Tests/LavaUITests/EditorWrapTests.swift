import CxxCanvas
import XCTest

@testable import LavaText
@testable import LavaUI

/// `EditorView(wraps:)` — a line of the file drawn across several rows.
///
/// The interesting part is not the breaking, which `SoftWrap` already tested.
/// It is everything that used to be allowed to say "row" and mean "line":
/// the gutter, go-to-line, a gutter click, and a stateful lexer's spans.
final class EditorWrapTests: XCTestCase {
    private static let viewport: (w: Float, h: Float) = (240, 400)

    /// One line far too long for a 240pt box, then two that fit.
    private static let text = [
        String(repeating: "wrap ", count: 40),
        "short",
        "also short",
    ].joined(separator: "\n")

    private var editor: Editor!
    private var host: LayoutHost!
    private var box: String = EditorWrapTests.text

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
    }

    override func tearDown() {
        host = nil
        editor = nil
        super.tearDown()
    }

    private var binding: Binding<String> {
        Binding(get: { self.box }, set: { self.box = $0 })
    }

    @discardableResult
    private func settle(wraps: Bool, controller: EditorController? = nil) throws -> LeafNode {
        // Inside a sized stack, not as the root: a root leaf is measured with
        // an undefined width, and soft wrap needs a finite one to break
        // against. This is also the shape a real app mounts.
        host.setRoot(
            VStack(width: .pt(Self.viewport.w), height: .pt(Self.viewport.h)) {
                EditorView(
                    text: binding, wraps: wraps, visibleLines: 20, controller: controller
                )
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

    func testWrappingSplitsALineIntoSeveralRows() throws {
        let leaf = try settle(wraps: true)
        XCTAssertGreaterThan(
            leaf.editing.layout.count, 3,
            "a 200-character line in a 240pt box has to break"
        )
        XCTAssertEqual(leaf.logicalLineCount, 3)
    }

    func testNotWrappingLeavesRowAndLineIdentical() throws {
        let leaf = try settle(wraps: false)
        XCTAssertEqual(leaf.editing.layout.count, 3)
        XCTAssertEqual(leaf.logicalLineCount, 3)
        XCTAssertTrue(leaf.rowLogicalLine.isEmpty, "no map is needed when they agree")
        for row in 0..<3 {
            XCTAssertEqual(leaf.logicalLine(ofRow: row), row)
            XCTAssertEqual(leaf.columnStart(ofRow: row), 0)
            XCTAssertTrue(leaf.isLineStart(ofRow: row))
        }
    }

    /// Only the first row of a line carries a number, or the file claims more
    /// lines than it has and every number below the wrap is wrong.
    func testOnlyTheFirstRowOfALineIsNumbered() throws {
        let leaf = try settle(wraps: true)
        let rows = leaf.editing.layout.count
        let numbered = (0..<rows).filter { leaf.isLineStart(ofRow: $0) }
        XCTAssertEqual(numbered.count, 3, "one number per logical line")
        XCTAssertEqual(numbered.map { leaf.logicalLine(ofRow: $0) }, [0, 1, 2])
        XCTAssertEqual(numbered[0], 0)
        XCTAssertGreaterThan(numbered[1], 1, "line 2 starts below the wrapped line 1")
    }

    func testEveryRowMapsBackToItsLine() throws {
        let leaf = try settle(wraps: true)
        let rows = leaf.editing.layout.rows
        for (index, row) in rows.enumerated() {
            let line = leaf.logicalLine(ofRow: index)
            let expectedFirst = (0..<rows.count).first { leaf.logicalLine(ofRow: $0) == line }
            XCTAssertEqual(
                leaf.firstRow(ofLine: line), expectedFirst,
                "firstRow must land on the start of this row's run"
            )
            // The line a row belongs to has to contain the row.
            let span = leaf.logicalLineRange(ofRow: index)
            XCTAssertLessThanOrEqual(span.lowerBound, row.lowerBound)
            XCTAssertGreaterThanOrEqual(span.upperBound, row.upperBound)
        }
    }

    /// Go-to-line means a line of the file, not the row it happens to be at.
    func testRevealResolvesALogicalLine() throws {
        let controller = EditorController()
        let leaf = try settle(wraps: true, controller: controller)
        controller.reveal(line: 3)
        let selected = leaf.editing.selectedText.trimmingCharacters(in: .newlines)
        XCTAssertEqual(selected, "also short")
    }

    /// A gutter click selects the line it numbered, not one wrapped fragment.
    func testGutterClickSelectsTheWholeLogicalLine() throws {
        let leaf = try settle(wraps: true)
        let font = try XCTUnwrap(leaf.font ?? FontStore.default)
        // Second row of the wrapped first line.
        leaf.selectRow(atLocalY: leaf.textInset + font.lineHeight * 1.5)
        let selected = leaf.editing.selectedText.trimmingCharacters(in: .newlines)
        XCTAssertEqual(selected, Self.text.split(separator: "\n").first.map(String.init))
    }

    /// Rows are built to fit, so there is nothing to the right of them.
    func testWrappingRemovesHorizontalScroll() throws {
        let font = try XCTUnwrap(FontStore.default)
        let wrapped = try settle(wraps: true)
        XCTAssertEqual(wrapped.maxScrollX(font: font), 0)

        let plain = try settle(wraps: false)
        XCTAssertGreaterThan(
            plain.maxScrollX(font: font), 0,
            "the same long line must overflow when it is not broken"
        )
    }

    /// An edit re-wraps the line it touched, not the file.
    ///
    /// Shaping is what wrapping costs, and there is one shape per line, so
    /// counting shapes is counting how much of the buffer was re-wrapped. This
    /// is a regression guard with teeth: `reconcilePrimitive` seeds logical
    /// rows on every text change, and anything that clears the wrap cache from
    /// there quietly puts the whole file back on every keystroke.
    func testAnEditReWrapsOnlyTheLineItTouched() throws {
        // Distinct lines, so the shape cache cannot answer for a line that was
        // never re-wrapped and hide the thing being measured.
        box = (0..<60).map { "\($0) " + String(repeating: "wrap ", count: 20) }
            .joined(separator: "\n")
        _ = try settle(wraps: true)

        box.insert("x", at: box.startIndex)
        let before = PerfCounters.lineWraps
        _ = try settle(wraps: true)
        let shaped = PerfCounters.lineWraps - before

        XCTAssertLessThanOrEqual(
            shaped, 4,
            "one keystroke re-wrapped \(shaped) lines; only the edited one should shape"
        )
    }

    /// Inserting a whole *line* shifts every line after it by one, so reuse
    /// matched index-for-index finds nothing to reuse from there on and
    /// re-shapes the rest of the file. Aligning the cache from both ends keeps
    /// the cost at the edit, where it belongs.
    func testInsertingALineReWrapsOnlyAroundTheInsertion() throws {
        box = (0..<60).map { "\($0) " + String(repeating: "wrap ", count: 20) }
            .joined(separator: "\n")
        _ = try settle(wraps: true)

        box.insert(contentsOf: "a brand new line\n", at: box.startIndex)
        let before = PerfCounters.lineWraps
        _ = try settle(wraps: true)
        let wrapped = PerfCounters.lineWraps - before

        XCTAssertLessThanOrEqual(
            wrapped, 4,
            "inserting one line re-wrapped \(wrapped) of them"
        )
    }

    /// A different width breaks every line somewhere else, so it cannot reuse.
    func testAWidthChangeReWrapsEverything() throws {
        box = (0..<60).map { "\($0) " + String(repeating: "wrap ", count: 20) }
            .joined(separator: "\n")
        let leaf = try settle(wraps: true)
        let rowsAtFullWidth = leaf.editing.layout.count

        host.setRoot(
            VStack(width: .pt(Self.viewport.w / 2), height: .pt(Self.viewport.h)) {
                EditorView(text: binding, wraps: true, visibleLines: 20)
            }
        )
        _ = host.calculateLayout(width: Self.viewport.w / 2, height: Self.viewport.h)
        XCTAssertGreaterThan(
            leaf.editing.layout.count, rowsAtFullWidth,
            "half the width has to break the same text into more rows"
        )
    }

    /// An editor that fills a flex box wraps too.
    ///
    /// Yoga skips the measure function entirely when a node's width *and*
    /// height are both definite, which is exactly `EditorView(...).flexGrow(1)`
    /// in a stretched column — the shape of every app that is mostly editor.
    /// Such an editor measured once and never again, so `wraps` set the flag
    /// and nothing else: the toggle appeared to do nothing at all.
    func testAStretchedEditorStillWraps() throws {
        let editorNode = try XCTUnwrap(
            Editor.openClient(width: Self.viewport.w, height: Self.viewport.h)
        )
        XCTAssertNotNil(
            FontStore.bootstrap(assetsRoot: LavaResources.root, pixelSize: 16, into: editorNode)
        )
        func settleStretched(wraps: Bool) throws -> LeafNode {
            host.setRoot(
                VStack(width: .pt(Self.viewport.w), height: .pt(Self.viewport.h), spacing: 0) {
                    VStack(flexGrow: 1, spacing: 0) {
                        EditorView(text: binding, wraps: wraps, visibleLines: 20)
                            .flexGrow(1)
                    }
                }
            )
            _ = host.calculateLayout(width: Self.viewport.w, height: Self.viewport.h)
            let root = try XCTUnwrap(host.rootNode)
            let list = DrawList(editor: editorNode)
            list.clear()
            list.emitTree(root, viewportW: Self.viewport.w, viewportH: Self.viewport.h)
            func walk(_ node: any AnyViewNode) -> LeafNode? {
                if let leaf = node as? LeafNode, leaf.kind == .editor { return leaf }
                for child in node.childNodes { if let hit = walk(child) { return hit } }
                return nil
            }
            return try XCTUnwrap(walk(root))
        }

        let plain = try settleStretched(wraps: false)
        XCTAssertEqual(plain.editing.layout.count, 3)
        let wrapped = try settleStretched(wraps: true)
        XCTAssertGreaterThan(
            wrapped.editing.layout.count, 3,
            "a stretched editor never re-measures, so it has to re-wrap at emit"
        )
    }

    // MARK: Replace, through the controller

    /// Going through the editor rather than rewriting the bound string is what
    /// buys one undo step and a row table that matches the new buffer.
    func testControllerReplaceAllRewritesTheBinding() throws {
        box = "cat cat cat"
        let controller = EditorController()
        let leaf = try settle(wraps: false, controller: controller)

        var search = TextSearch()
        search.find("cat", in: box)
        XCTAssertEqual(controller.replaceAll(search, with: "dog"), 3)
        XCTAssertEqual(box, "dog dog dog", "the binding carries the result out")
        XCTAssertEqual(leaf.editing.text, "dog dog dog")

        XCTAssertTrue(leaf.editing.undo())
        XCTAssertEqual(leaf.editing.text, "cat cat cat", "one step, not three")
    }

    func testControllerReplaceCurrentRewritesOnlyTheCurrentMatch() throws {
        box = "cat cat"
        let controller = EditorController()
        try settle(wraps: false, controller: controller)

        var search = TextSearch()
        search.find("cat", in: box)
        XCTAssertTrue(controller.replaceCurrent(search, with: "dog"))
        XCTAssertEqual(box, "dog cat")
    }

    func testControllerReplaceOnAnUnmountedEditorIsANoOp() {
        let controller = EditorController()
        XCTAssertEqual(controller.replace([0..<3], with: "x"), 0)
    }

    /// The gutter reads the row table before the next measure pass, so a
    /// replace that changed the line count has to leave it consistent.
    func testReplaceKeepsTheRowTableInStep() throws {
        box = "a\nb\nc"
        let controller = EditorController()
        let leaf = try settle(wraps: false, controller: controller)
        XCTAssertEqual(leaf.editing.layout.count, 3)

        var search = TextSearch()
        search.find("b", in: box)
        XCTAssertEqual(controller.replaceAll(search, with: "b\nb"), 1)
        XCTAssertEqual(leaf.editing.layout.count, 4)
        XCTAssertEqual(leaf.logicalLineCount, 4)
    }

    /// Toggling has to rebuild the table — both branches of `refreshVisualRows`
    /// short-circuit on an unchanged buffer, and the buffer does not change.
    func testTogglingWrapRebuildsTheRows() throws {
        let plain = try settle(wraps: false)
        XCTAssertEqual(plain.editing.layout.count, 3)
        let wrapped = try settle(wraps: true)
        XCTAssertGreaterThan(wrapped.editing.layout.count, 3)
        let again = try settle(wraps: false)
        XCTAssertEqual(again.editing.layout.count, 3)
    }

    // MARK: What a keystroke is allowed to throw away

    /// Rows for `text`, wrapped from nothing — the answer an incremental pass
    /// has to match.
    private func coldRows(_ text: String) throws -> [Range<Int>] {
        let saved = box
        defer { box = saved }
        box = text
        let fresh = LayoutHost()
        let outer = host
        host = fresh
        defer { host = outer }
        return try settle(wraps: true).editing.layout.rows
    }

    private func rowsAfterEditing(
        _ edit: (LeafNode) -> Void, expecting text: String
    ) throws -> [Range<Int>] {
        let leaf = try settle(wraps: true)
        leaf.focusSelf(binding: binding, onSubmit: nil)
        edit(leaf)
        XCTAssertEqual(box, text, "the edit did not produce the buffer under test")
        return try settle(wraps: true).editing.layout.rows
    }

    /// The wrap cache is reused by matching lines against the previous pass.
    /// Matching them *by index* is only right while the line count holds:
    /// inserting a line shifts every line after it, and a positional check
    /// then says they all changed. Reuse has to be aligned from both ends —
    /// and, more importantly, the rows it produces have to be the rows a cold
    /// wrap would have produced.
    func testInsertingALineAheadOfAWrappedLineStillWrapsIt() throws {
        let expected = "new\n" + Self.text
        let rows = try rowsAfterEditing({ leaf in
            leaf.editing.setCursor(leaf.editing.text.startIndex)
            _ = FocusManager.handle(character: "n")
            _ = FocusManager.handle(character: "e")
            _ = FocusManager.handle(character: "w")
            _ = FocusManager.handle(KeyEvent(key: KeyCode.enter, mods: 0))
        }, expecting: expected)
        XCTAssertEqual(rows, try coldRows(expected))
    }

    func testDeletingALineStillWrapsWhatIsLeft() throws {
        var lines = Self.text.split(separator: "\n", omittingEmptySubsequences: false)
        lines.remove(at: 1)
        let expected = lines.joined(separator: "\n")
        let rows = try rowsAfterEditing({ leaf in
            let start = leaf.editing.text.firstIndex(of: "\n")!
            let next = leaf.editing.text[leaf.editing.text.index(after: start)...]
                .firstIndex(of: "\n")!
            leaf.editing.setCursor(start)
            leaf.editing.setCursor(next, extending: true)
            _ = FocusManager.handle(KeyEvent(key: KeyCode.backspace, mods: 0))
        }, expecting: expected)
        XCTAssertEqual(rows, try coldRows(expected))
    }

    func testEditingInsideTheWrappedLineRebreaksIt() throws {
        let expected = "X" + Self.text
        let rows = try rowsAfterEditing({ leaf in
            leaf.editing.setCursor(leaf.editing.text.startIndex)
            _ = FocusManager.handle(character: "X")
        }, expecting: expected)
        XCTAssertEqual(rows, try coldRows(expected))
    }

    /// The other half: a key that only moved the caret must leave the wrap
    /// marks alone. Clearing them was what made Page Down re-break the whole
    /// file — 4.4 s a press on a 4 MB log, and paid again on every arrow key.
    func testACaretMoveKeepsTheWrapCacheWarm() throws {
        let leaf = try settle(wraps: true)
        leaf.focusSelf(binding: binding, onSubmit: nil)
        let rows = leaf.editing.layout.rows
        let width = leaf.lastMeasuredWidth
        for key in [KeyCode.down, KeyCode.right, KeyCode.pageDown, KeyCode.end] {
            _ = FocusManager.handle(KeyEvent(key: key, mods: 0))
            XCTAssertEqual(
                leaf.lastWrappedText, leaf.editing.text,
                "a caret move dropped the wrap mark"
            )
            XCTAssertEqual(leaf.lastMeasuredWidth, width, "a caret move dropped the width")
            XCTAssertEqual(leaf.editing.layout.rows, rows, "rows moved without an edit")
        }
    }

    /// And with wrapping off, the same key must not reseed the logical-row
    /// table — the O(buffer) scan that cost 58 ms a press.
    func testACaretMoveKeepsTheLogicalRowMarkWarm() throws {
        let leaf = try settle(wraps: false)
        leaf.focusSelf(binding: binding, onSubmit: nil)
        for key in [KeyCode.down, KeyCode.pageDown] {
            _ = FocusManager.handle(KeyEvent(key: key, mods: 0))
            XCTAssertEqual(leaf.lastLogicalRowsText, leaf.editing.text)
        }
    }
}

