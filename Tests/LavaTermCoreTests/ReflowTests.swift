import XCTest

@testable import LavaTermCore

/// Rewrapping on resize.
///
/// The behaviour these pin down is the one a user sees as "the window got
/// narrower and ate half my output": the old resize copied the top-left corner
/// of the grid into the new one, so narrowing deleted the right-hand end of
/// every longer line, permanently and including in the history.
final class ReflowTests: XCTestCase {
    /// One row of the live screen as a string, trailing padding removed.
    private func row(_ screen: TerminalScreen, _ r: Int) -> String {
        var out = ""
        for c in 0..<screen.cols {
            out.unicodeScalars.append(screen.cell(row: r, col: c).scalar)
        }
        while out.hasSuffix(" ") { out.removeLast() }
        return out
    }

    /// Every visible row, history included, from the top of the scrollback.
    private func visible(_ screen: TerminalScreen) -> [String] {
        (0..<screen.rows).map { row(screen, $0) }
    }

    // MARK: - Narrowing

    /// The bug in one test: text that fits before the resize must still exist
    /// after it, on a continuation row rather than in the bin.
    func testNarrowingWrapsInsteadOfTruncating() {
        let s = TerminalScreen(cols: 20, rows: 6)
        s.feed("abcdefghijklmnop")

        s.resize(cols: 10, rows: 6)

        XCTAssertEqual(row(s, 0), "abcdefghij")
        XCTAssertEqual(row(s, 1), "klmnop", "the tail of the line was dropped")
    }

    /// Attributes travel with the cells they belong to — a colour that was on
    /// the part of a line that moved must move with it.
    func testNarrowingCarriesAttributesToTheContinuationRow() {
        let s = TerminalScreen(cols: 12, rows: 4)
        s.feed("\u{1B}[31mRRRRRRRRRRRR\u{1B}[0m")

        s.resize(cols: 6, rows: 4)

        XCTAssertEqual(s.cell(row: 0, col: 0).fg, .index(1))
        XCTAssertEqual(
            s.cell(row: 1, col: 0).fg, .index(1),
            "the wrapped remainder lost its colour"
        )
    }

    /// Separate lines must stay separate. This is what the wrap flag is for:
    /// without it, joining every row would run unrelated output together.
    func testHardNewlinesAreNotJoined() {
        let s = TerminalScreen(cols: 20, rows: 6)
        s.feed("one\r\ntwo\r\nthree")

        s.resize(cols: 40, rows: 6)

        XCTAssertEqual(row(s, 0), "one")
        XCTAssertEqual(row(s, 1), "two")
        XCTAssertEqual(row(s, 2), "three")
    }

    // MARK: - Widening

    /// The other direction: a line broken at a margin that no longer exists
    /// should close back up.
    func testWideningRejoinsAWrappedLine() {
        let s = TerminalScreen(cols: 10, rows: 6)
        s.feed("abcdefghijklmnop")
        XCTAssertEqual(row(s, 1), "klmnop", "precondition: it wrapped")

        s.resize(cols: 20, rows: 6)

        XCTAssertEqual(row(s, 0), "abcdefghijklmnop")
        XCTAssertEqual(row(s, 1), "", "the continuation row should be gone")
    }

    /// Narrow then widen returns the original text. Reflow that loses nothing
    /// is the whole claim, and a round trip is the cheapest way to state it.
    func testNarrowThenWidenRoundTrips() {
        let s = TerminalScreen(cols: 40, rows: 8)
        s.feed("the quick brown fox jumps over the lazy dog\r\nsecond line")

        s.resize(cols: 11, rows: 8)
        s.resize(cols: 40, rows: 8)

        XCTAssertEqual(row(s, 0), "the quick brown fox jumps over the lazy")
        XCTAssertEqual(row(s, 1), "dog")
        XCTAssertEqual(row(s, 2), "second line")
    }

    // MARK: - The cursor

    /// Typing after a resize has to land where the caret is drawn.
    func testCursorFollowsItsCharacter() {
        let s = TerminalScreen(cols: 20, rows: 6)
        s.feed("abcdefghijklmnop")
        XCTAssertEqual(s.cursorCol, 16)

        s.resize(cols: 10, rows: 6)

        XCTAssertEqual(s.cursorRow, 1)
        XCTAssertEqual(s.cursorCol, 6, "cursor should still be after the 'p'")

        s.feed("X")
        XCTAssertEqual(row(s, 1), "klmnopX")
    }

    /// A prompt on its own line keeps its place when the width changes under
    /// it — the case that happens every time somebody drags a window edge.
    func testCursorStaysAtAPromptAcrossResize() {
        let s = TerminalScreen(cols: 30, rows: 6)
        s.feed("output line\r\n$ ")

        s.resize(cols: 15, rows: 6)

        XCTAssertEqual(row(s, s.cursorRow), "$")
        XCTAssertEqual(s.cursorCol, 2)
    }

    // MARK: - History

    /// Scrollback is part of the same sequence, so it reflows too — otherwise
    /// scrolling up after a resize shows lines cut at the old width.
    func testScrollbackReflowsWithTheScreen() {
        let s = TerminalScreen(cols: 20, rows: 3)
        // Enough lines to push the first ones into history.
        for i in 0..<6 {
            s.feed("line-\(i)-padding-x\r\n")
        }
        XCTAssertGreaterThan(s.scrollbackLineCount, 0, "precondition: history exists")

        s.resize(cols: 10, rows: 3)

        // Every history row is now at most the new width, and nothing is lost:
        // "line-0-padding-x" is 16 wide and must occupy two rows.
        _ = s.scrollView(by: s.scrollbackLineCount)
        var seen: [String] = []
        for r in 0..<s.rows {
            var out = ""
            for c in 0..<s.cols {
                out.unicodeScalars.append(s.visibleCell(row: r, col: c).scalar)
            }
            while out.hasSuffix(" ") { out.removeLast() }
            seen.append(out)
        }
        XCTAssertTrue(
            seen.contains("line-0-pad"), "history was not rewrapped: \(seen)"
        )
    }

    // MARK: - The alternate screen

    /// A full-screen program's buffer is an absolute layout that it redraws on
    /// SIGWINCH. Rewrapping it into continuation lines would invent a picture
    /// nothing intended.
    func testAlternateScreenIsNotReflowed() {
        let s = TerminalScreen(cols: 20, rows: 4)
        s.feed("\u{1B}[?1049h")  // enter alt
        s.feed("abcdefghijklmnop")

        s.resize(cols: 10, rows: 4)

        XCTAssertEqual(row(s, 0), "abcdefghij")
        XCTAssertEqual(row(s, 1), "", "alt screen must not wrap onto a new row")
    }

    /// And the main buffer is still there, intact, when the program exits.
    func testLeavingTheAlternateScreenRestoresTheMainBuffer() {
        let s = TerminalScreen(cols: 20, rows: 4)
        s.feed("main content")
        s.feed("\u{1B}[?1049h")
        s.feed("alt")
        s.resize(cols: 12, rows: 4)
        s.feed("\u{1B}[?1049l")

        XCTAssertEqual(row(s, 0), "main content")
    }

    // MARK: - Degenerate sizes

    func testOneColumnDoesNotHangOrLose() {
        let s = TerminalScreen(cols: 10, rows: 8)
        s.feed("abcd")

        s.resize(cols: 1, rows: 8)

        XCTAssertEqual(row(s, 0), "a")
        XCTAssertEqual(row(s, 1), "b")
        XCTAssertEqual(row(s, 2), "c")
        XCTAssertEqual(row(s, 3), "d")
    }

    func testResizingAnEmptyScreenIsHarmless() {
        let s = TerminalScreen(cols: 20, rows: 5)
        s.resize(cols: 7, rows: 3)
        XCTAssertEqual(s.cols, 7)
        XCTAssertEqual(s.rows, 3)
        XCTAssertEqual(visible(s), ["", "", ""])
        XCTAssertEqual(s.cursorRow, 0)
        XCTAssertEqual(s.cursorCol, 0)
    }
}
