import XCTest
@testable import LavaTermCore

final class AnsiScreenTests: XCTestCase {
    func testPrintableAdvancesCursor() {
        let s = TerminalScreen(cols: 10, rows: 4)
        s.feed("hi")
        XCTAssertEqual(s.cursorCol, 2)
        XCTAssertEqual(s.cursorRow, 0)
        XCTAssertEqual(Character(s.cell(row: 0, col: 0).scalar), "h")
        XCTAssertEqual(Character(s.cell(row: 0, col: 1).scalar), "i")
    }

    func testNewlineAndCarriageReturn() {
        let s = TerminalScreen(cols: 10, rows: 4)
        s.feed("ab\r\ncd")
        XCTAssertEqual(Character(s.cell(row: 0, col: 0).scalar), "a")
        XCTAssertEqual(Character(s.cell(row: 1, col: 0).scalar), "c")
        XCTAssertEqual(s.cursorRow, 1)
        XCTAssertEqual(s.cursorCol, 2)
    }

    func testCSIColorSGR() {
        let s = TerminalScreen(cols: 10, rows: 4)
        s.feed("\u{1B}[31mR\u{1B}[0m.")
        let red = s.cell(row: 0, col: 0)
        XCTAssertEqual(red.fg, .index(1))
        XCTAssertEqual(Character(red.scalar), "R")
        let reset = s.cell(row: 0, col: 1)
        XCTAssertEqual(reset.fg, .default)
    }

    func testCursorPosition() {
        let s = TerminalScreen(cols: 20, rows: 10)
        s.feed("\u{1B}[5;8H*")
        XCTAssertEqual(s.cursorRow, 4)  // after writing, col advances
        XCTAssertEqual(s.cursorCol, 8)
        XCTAssertEqual(Character(s.cell(row: 4, col: 7).scalar), "*")
    }

    func testEraseLine() {
        let s = TerminalScreen(cols: 10, rows: 3)
        s.feed("abcdef")
        s.feed("\u{1B}[3G")  // CHA col 3
        s.feed("\u{1B}[K")
        XCTAssertEqual(Character(s.cell(row: 0, col: 0).scalar), "a")
        XCTAssertEqual(Character(s.cell(row: 0, col: 1).scalar), "b")
        XCTAssertEqual(Character(s.cell(row: 0, col: 2).scalar), " ")
        XCTAssertEqual(Character(s.cell(row: 0, col: 5).scalar), " ")
    }

    func testScrollOnLastLine() {
        let s = TerminalScreen(cols: 4, rows: 3)
        s.feed("AAAA\nBBBB\nCCCC\nDDDD")
        // After filling 3 lines and another LF, content should have scrolled.
        XCTAssertEqual(Character(s.cell(row: 0, col: 0).scalar), "B")
        XCTAssertEqual(Character(s.cell(row: 2, col: 0).scalar), "D")
    }

    func test256Color() {
        let s = TerminalScreen(cols: 5, rows: 2)
        s.feed("\u{1B}[38;5;196mX")
        XCTAssertEqual(s.cell(row: 0, col: 0).fg, .index(196))
    }

    func testResizePreservesContent() {
        let s = TerminalScreen(cols: 4, rows: 2)
        s.feed("abcd\nefgh")
        s.resize(cols: 6, rows: 3)
        XCTAssertEqual(Character(s.cell(row: 0, col: 0).scalar), "a")
        XCTAssertEqual(Character(s.cell(row: 1, col: 0).scalar), "e")
        XCTAssertEqual(s.cols, 6)
        XCTAssertEqual(s.rows, 3)
    }

    /// tmux / less / vim enter the alternate screen with `CSI ? 1049 h`.
    /// Without it, full-screen tools paint over the shell's scrollback.
    func testAlternateScreen1049SwapsAndRestores() {
        let s = TerminalScreen(cols: 8, rows: 3)
        s.feed("shell\r\nprompt")
        XCTAssertEqual(Character(s.cell(row: 0, col: 0).scalar), "s")
        XCTAssertFalse(s.onAlternateScreen)

        s.feed("\u{1B}[?1049h")
        XCTAssertTrue(s.onAlternateScreen)
        // Fresh alt buffer — shell text must not show through.
        XCTAssertEqual(Character(s.cell(row: 0, col: 0).scalar), " ")
        s.feed("TMUX")
        XCTAssertEqual(Character(s.cell(row: 0, col: 0).scalar), "T")

        s.feed("\u{1B}[?1049l")
        XCTAssertFalse(s.onAlternateScreen)
        XCTAssertEqual(Character(s.cell(row: 0, col: 0).scalar), "s")
        XCTAssertEqual(Character(s.cell(row: 1, col: 0).scalar), "p")
    }

    func testCursorVisibilityPrivateMode() {
        let s = TerminalScreen(cols: 4, rows: 2)
        XCTAssertTrue(s.cursorVisible)
        s.feed("\u{1B}[?25l")
        XCTAssertFalse(s.cursorVisible)
        s.feed("\u{1B}[?25h")
        XCTAssertTrue(s.cursorVisible)
    }

    func testApplicationCursorKeysMode() {
        let s = TerminalScreen(cols: 4, rows: 2)
        XCTAssertFalse(s.applicationCursorKeys)
        s.feed("\u{1B}[?1h")
        XCTAssertTrue(s.applicationCursorKeys)
        s.feed("\u{1B}[?1l")
        XCTAssertFalse(s.applicationCursorKeys)
    }

    /// `sgr0` on xterm-256color is `ESC ( B` then `CSI m`. The charset
    /// designate used to return to ground before consuming `B`, so every
    /// color reset left a stray `B` in the prompt: `nikitaB@Blaptop`.
    func testCharsetDesignateDoesNotPrintTheFinal() {
        let s = TerminalScreen(cols: 40, rows: 2)
        s.feed("\u{1B}[1;32mnikita\u{1B}[0m\u{1B}(B@\u{1B}[1;32mlaptop\u{1B}[0m\u{1B}(B")
        var line = ""
        for c in 0..<20 {
            let ch = Character(s.cell(row: 0, col: c).scalar)
            if ch != " " { line.append(ch) }
        }
        XCTAssertEqual(line, "nikita@laptop")
        XCTAssertFalse(line.contains("B"))
    }

    /// tmux paints its status bar with black-on-green SGR then a CR/LF on the
    /// last row (which scrolls when the region is full) then the text. The
    /// text has to still be there after `CSI n X` clears the middle.
    func testTmuxStyleStatusBarKeepsText() {
        let s = TerminalScreen(cols: 90, rows: 17)
        s.feed("\u{1B}[?1049h\u{1B}[H\u{1B}[2J\u{1B}[1;17r")
        // Clear every row the way tmux does, then the status line.
        s.feed("\u{1B}[1;1H\u{1B}[?25l")
        for _ in 0..<16 {
            s.feed("\u{1B}[K\r\n")
        }
        s.feed("\u{1B}[K\u{1B}[30m\u{1B}[42m\r\n[0] 0:tmux*\u{1B}[55X\u{1B}[55C\"laptop\"")
        let last = 16
        XCTAssertEqual(Character(s.cell(row: last, col: 0).scalar), "[")
        XCTAssertEqual(Character(s.cell(row: last, col: 1).scalar), "0")
        // Green background from SGR 42, black fg from SGR 30.
        XCTAssertEqual(s.cell(row: last, col: 0).bg, .index(2))
        XCTAssertEqual(s.cell(row: last, col: 0).fg, .index(0))
        // Middle of the bar was erased to spaces, still green.
        XCTAssertEqual(Character(s.cell(row: last, col: 20).scalar), " ")
        XCTAssertEqual(s.cell(row: last, col: 20).bg, .index(2))
    }

    /// A line feed on the status line (below the scrolling region) must not
    /// scroll the pane.
    func testLineFeedBelowScrollRegionDoesNotScroll() {
        let s = TerminalScreen(cols: 10, rows: 5)
        s.feed("AAAA\r\nBBBB\r\nCCCC\r\nDDDD")
        s.feed("\u{1B}[1;4r")          // rows 1–4 scroll; row 5 is status
        s.feed("\u{1B}[5;1HSTATUS")
        s.feed("\n")                   // LF on status line
        XCTAssertEqual(Character(s.cell(row: 0, col: 0).scalar), "A")
        XCTAssertEqual(Character(s.cell(row: 4, col: 0).scalar), "S")
    }
}
