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
}
