import XCTest
@testable import LavaTermCore

/// Selecting text in a grid.
///
/// Everything here is about two mappings being each other's inverse — a cell
/// drawn at some pixel has to be the cell a press at that pixel finds — and
/// about the range between two cells being reading order rather than a
/// rectangle, which is the difference between selecting a sentence that wraps
/// and selecting a column of it.
final class TerminalSelectionTests: XCTestCase {
    /// 10×4 cells of 8×16 pixels, offset by the padding the view draws with.
    private func geometry(cols: Int = 10, rows: Int = 4) -> TerminalGeometry {
        TerminalGeometry(
            originX: 6, originY: 6, cellW: 8, cellH: 16, cols: cols, rows: rows)
    }

    // MARK: - Geometry

    func testAPixelInACellFindsThatCell() {
        let g = geometry()
        for row in 0..<4 {
            for col in 0..<10 {
                // The middle of where the cell is painted.
                let hit = g.cell(atX: g.x(col: col) + 4, y: g.y(row: row) + 8)
                XCTAssertEqual(hit, CellPosition(row: row, col: col))
            }
        }
    }

    func testACellBoundaryBelongsToTheCellItStarts() {
        let g = geometry()
        XCTAssertEqual(g.cell(atX: g.x(col: 3), y: g.y(row: 2)),
                       CellPosition(row: 2, col: 3))
        // One pixel short is still the cell before.
        XCTAssertEqual(g.cell(atX: g.x(col: 3) - 1, y: g.y(row: 2)),
                       CellPosition(row: 2, col: 2))
    }

    func testAPointOutsideTheGridClampsIntoIt() {
        let g = geometry()
        // A drag off the right edge means "to the end of the line", off the
        // top means "from the first row". Both have to be positions.
        XCTAssertEqual(g.cell(atX: 10_000, y: 10_000),
                       CellPosition(row: 3, col: 9))
        XCTAssertEqual(g.cell(atX: -10_000, y: -10_000),
                       CellPosition(row: 0, col: 0))
    }

    // MARK: - Ranges

    func testDraggingBackwardsSelectsTheSameThing() {
        let screen = TerminalScreen(cols: 10, rows: 4)
        screen.feed("hello")
        var forward = TerminalSelection()
        forward.begin(at: CellPosition(row: 0, col: 1),
                      granularity: .character, in: screen)
        forward.extend(to: CellPosition(row: 0, col: 3), in: screen)

        var backward = TerminalSelection()
        backward.begin(at: CellPosition(row: 0, col: 3),
                       granularity: .character, in: screen)
        backward.extend(to: CellPosition(row: 0, col: 1), in: screen)

        XCTAssertEqual(forward.range, backward.range)
        XCTAssertEqual(forward.text(from: screen), "ell")
        XCTAssertEqual(backward.text(from: screen), "ell")
    }

    /// A plain click is not a selection — only a drag (or a word/line press)
    /// is. Selecting on the press itself left a one-cell highlight and put
    /// one character into the primary selection.
    func testACharacterPressAloneDoesNotSelect() {
        let screen = TerminalScreen(cols: 10, rows: 2)
        screen.feed("hello")
        var selection = TerminalSelection()
        selection.begin(at: CellPosition(row: 0, col: 1),
                        granularity: .character, in: screen)
        XCTAssertTrue(selection.isEmpty)
        XCTAssertFalse(selection.dragged)
        // A release move at the same cell still is not a drag.
        selection.extend(to: CellPosition(row: 0, col: 1), in: screen)
        XCTAssertTrue(selection.isEmpty)
    }

    func testASelectionAcrossRowsIsReadingOrderNotARectangle() {
        let screen = TerminalScreen(cols: 10, rows: 4)
        screen.feed("abcdefghij\r\nklmnopqrst")
        var selection = TerminalSelection()
        selection.begin(at: CellPosition(row: 0, col: 7),
                        granularity: .character, in: screen)
        selection.extend(to: CellPosition(row: 1, col: 2), in: screen)

        // The tail of the first row, then the head of the second — not
        // columns 7…2 of both, which is what a rectangle would give.
        XCTAssertEqual(selection.columns(inRow: 0, cols: 10), 7...9)
        XCTAssertEqual(selection.columns(inRow: 1, cols: 10), 0...2)
        XCTAssertEqual(selection.text(from: screen), "hij\nklm")
    }

    func testRowsOutsideTheSelectionHaveNoColumns() {
        let screen = TerminalScreen(cols: 10, rows: 4)
        var selection = TerminalSelection()
        selection.begin(at: CellPosition(row: 1, col: 0),
                        granularity: .character, in: screen)
        selection.extend(to: CellPosition(row: 1, col: 4), in: screen)
        XCTAssertNil(selection.columns(inRow: 0, cols: 10))
        XCTAssertNil(selection.columns(inRow: 2, cols: 10))
        XCTAssertEqual(selection.columns(inRow: 1, cols: 10), 0...4)
    }

    // MARK: - What a press picks

    func testDoubleClickTakesTheWholeWord() {
        let screen = TerminalScreen(cols: 20, rows: 2)
        screen.feed("ls  /usr/share  now")
        var selection = TerminalSelection()
        // Anywhere inside it, not just its first character.
        selection.begin(at: CellPosition(row: 0, col: 7),
                        granularity: .word, in: screen)
        // A path is one word: three of them would be useless exactly where a
        // terminal selection is used most.
        XCTAssertEqual(selection.text(from: screen), "/usr/share")
    }

    func testDoubleClickOnBlankTakesOnlyThatCell() {
        let screen = TerminalScreen(cols: 20, rows: 2)
        screen.feed("ls  /usr")
        var selection = TerminalSelection()
        selection.begin(at: CellPosition(row: 0, col: 2),
                        granularity: .word, in: screen)
        XCTAssertEqual(selection.range,
                       CellPosition(row: 0, col: 2)...CellPosition(row: 0, col: 2))
    }

    func testAWordDragKeepsWholeWordsAtBothEnds() {
        let screen = TerminalScreen(cols: 20, rows: 2)
        screen.feed("alpha beta gamma")
        var selection = TerminalSelection()
        // Press in the middle of "alpha", drag into the middle of "gamma".
        selection.begin(at: CellPosition(row: 0, col: 2),
                        granularity: .word, in: screen)
        selection.extend(to: CellPosition(row: 0, col: 13), in: screen)
        XCTAssertEqual(selection.text(from: screen), "alpha beta gamma")
    }

    func testTripleClickTakesTheRow() {
        let screen = TerminalScreen(cols: 10, rows: 3)
        screen.feed("one\r\ntwo")
        var selection = TerminalSelection()
        selection.begin(at: CellPosition(row: 1, col: 1),
                        granularity: .line, in: screen)
        XCTAssertEqual(selection.columns(inRow: 1, cols: 10), 0...9)
        // Trailing blanks trimmed: a row is always the full width, and
        // pasting it should not paste seven spaces.
        XCTAssertEqual(selection.text(from: screen), "two")
    }

    // MARK: - Lifecycle

    func testAFreshSelectionIsEmpty() {
        let selection = TerminalSelection()
        XCTAssertTrue(selection.isEmpty)
        XCTAssertNil(selection.range)
        XCTAssertEqual(selection.text(from: TerminalScreen(cols: 4, rows: 2)), "")
    }

    func testAPressThatDidNotMoveIsNotADrag() {
        let screen = TerminalScreen(cols: 10, rows: 2)
        screen.feed("hello")
        var selection = TerminalSelection()
        selection.begin(at: CellPosition(row: 0, col: 1),
                        granularity: .character, in: screen)
        XCTAssertFalse(selection.dragged)
        XCTAssertTrue(selection.isEmpty)
        selection.extend(to: CellPosition(row: 0, col: 2), in: screen)
        XCTAssertTrue(selection.dragged)
        XCTAssertEqual(selection.text(from: screen), "el")
    }

    /// Found by watching the real thing: a release delivers one last move at
    /// the position it is releasing at, so counting any extend as a drag made
    /// every click leave one highlighted character behind.
    func testAnExtendToWhereThePressWasIsStillNotADrag() {
        let screen = TerminalScreen(cols: 10, rows: 2)
        screen.feed("hello")
        var selection = TerminalSelection()
        let press = CellPosition(row: 0, col: 3)
        selection.begin(at: press, granularity: .character, in: screen)
        selection.extend(to: press, in: screen)
        XCTAssertFalse(selection.dragged)
        XCTAssertTrue(selection.isEmpty)
    }

    func testADragThatWandersBackIsStillADrag() {
        let screen = TerminalScreen(cols: 10, rows: 2)
        screen.feed("hello")
        var selection = TerminalSelection()
        let press = CellPosition(row: 0, col: 3)
        selection.begin(at: press, granularity: .character, in: screen)
        selection.extend(to: CellPosition(row: 0, col: 6), in: screen)
        selection.extend(to: press, in: screen)
        XCTAssertTrue(selection.dragged)
    }

    func testExtendingWithoutABeginningDoesNothing() {
        let screen = TerminalScreen(cols: 10, rows: 2)
        var selection = TerminalSelection()
        selection.extend(to: CellPosition(row: 0, col: 3), in: screen)
        XCTAssertTrue(selection.isEmpty)
    }

    func testClearForgetsEverything() {
        let screen = TerminalScreen(cols: 10, rows: 2)
        screen.feed("hello")
        var selection = TerminalSelection()
        selection.begin(at: CellPosition(row: 0, col: 0),
                        granularity: .word, in: screen)
        selection.extend(to: CellPosition(row: 0, col: 4), in: screen)
        selection.clear()
        XCTAssertTrue(selection.isEmpty)
        XCTAssertFalse(selection.dragged)
        XCTAssertEqual(selection.granularity, .character)
    }

    // MARK: - Line numbers

    /// `count` numbered lines, `line1` … `lineN`, each ending in a newline, so
    /// on a 4-row screen all but the last few have scrolled into history.
    private func numbered(_ screen: TerminalScreen, _ count: Int, from start: Int = 1) {
        var text = ""
        for n in start..<(start + count) { text += "line\(n)\r\n" }
        screen.feed(text)
    }

    /// The press, as the view makes it: a viewport row turned into a line.
    private func at(_ screen: TerminalScreen, row: Int, col: Int) -> CellPosition {
        CellPosition(row: screen.line(ofViewportRow: row), col: col)
    }

    func testViewportRowsAndLinesAreInverse() {
        let screen = TerminalScreen(cols: 10, rows: 4)
        numbered(screen, 20)
        screen.scrollView(by: 5)
        for row in 0..<4 {
            let line = screen.line(ofViewportRow: row)
            XCTAssertEqual(screen.viewportRow(ofLine: line), row)
            XCTAssertEqual(screen.cell(line: line, col: 0), screen.visibleCell(row: row, col: 0))
        }
    }

    /// Output arriving under a selection moves the text up the screen; the
    /// selection goes with it rather than staying on the rows it was made on.
    func testASelectionStaysOnItsTextWhileOutputScrolls() {
        let screen = TerminalScreen(cols: 10, rows: 4)
        numbered(screen, 2)
        var selection = TerminalSelection()
        selection.begin(at: at(screen, row: 0, col: 0), granularity: .line, in: screen)
        XCTAssertEqual(selection.text(from: screen), "line1")

        numbered(screen, 10, from: 3)
        XCTAssertEqual(selection.text(from: screen), "line1", "line1 is in history now, still selected")
        XCTAssertTrue(selection.isCurrent(in: screen))
    }

    /// The view scrolling under a selection — the wheel, or autoscroll — does
    /// not change what is selected, and a drag continued after it reaches the
    /// line now under the pointer. That pair is the whole of autoscroll.
    func testADragCarriesOnAcrossAScroll() {
        let screen = TerminalScreen(cols: 10, rows: 4)
        numbered(screen, 30)
        var selection = TerminalSelection()
        selection.begin(at: at(screen, row: 0, col: 0), granularity: .character, in: screen)
        selection.extend(to: at(screen, row: 0, col: 4), in: screen)
        let before = selection.text(from: screen)
        // The top row is line28 — thirty lines, the cursor on an empty last
        // row — and its first five cells read "line2".
        XCTAssertEqual(before, "line2")

        // Pointer held on the top row while the view scrolls up three lines.
        screen.scrollView(by: 3)
        XCTAssertEqual(selection.text(from: screen), before, "scrolling selects nothing by itself")
        selection.extend(to: at(screen, row: 0, col: 0), in: screen)
        XCTAssertEqual(
            selection.text(from: screen), "line25\nline26\nline27\nl",
            "from line25, now the top row, back to the press cell in line28 — a "
                + "drag that crosses its anchor keeps the anchor, not the old focus")
    }

    func testTrimmingHistoryDoesNotMoveLineNumbers() {
        let screen = TerminalScreen(cols: 12, rows: 4)
        numbered(screen, 10_000)
        var selection = TerminalSelection()
        // The newest finished line, which survives the trim below.
        selection.begin(at: at(screen, row: 2, col: 0), granularity: .line, in: screen)
        let text = selection.text(from: screen)
        XCTAssertEqual(text, "line10000")

        // Past the cap plus a trim batch: the oldest lines are dropped.
        numbered(screen, 1_200, from: 10_001)
        XCTAssertEqual(selection.text(from: screen), text)
    }

    func testReflowAndTheAlternateScreenInvalidateLineNumbers() {
        let screen = TerminalScreen(cols: 10, rows: 4)
        numbered(screen, 6)
        var selection = TerminalSelection()
        selection.begin(at: at(screen, row: 0, col: 0), granularity: .line, in: screen)
        XCTAssertTrue(selection.isCurrent(in: screen))

        screen.resize(cols: 8, rows: 4)
        XCTAssertFalse(selection.isCurrent(in: screen), "a reflow re-cuts every line")

        selection.begin(at: at(screen, row: 0, col: 0), granularity: .line, in: screen)
        screen.feed("\u{1B}[?1049h")
        XCTAssertFalse(selection.isCurrent(in: screen), "the alternate screen is another buffer")
    }
}
