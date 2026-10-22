import XCTest
@testable import LavaTermCore

/// The fast paths of ingest — printable runs, bulk scrolls, CSI parameters
/// read as numbers — against what the byte-at-a-time code did.
final class IngestTests: XCTestCase {
    func testMultibyteCharacterSplitAcrossFeeds() {
        let s = TerminalScreen(cols: 10, rows: 2)
        let bytes = Array("aé€😀".utf8)
        // Every split point, including inside each multi-byte character.
        for cut in 0...bytes.count {
            s.feed("\u{1B}[H\u{1B}[2J")
            s.feed(Data(bytes[..<cut]))
            s.feed(Data(bytes[cut...]))
            let row = (0..<4).map { Character(s.cell(row: 0, col: $0).scalar) }
            XCTAssertEqual(String(row), "aé€😀", "split at \(cut)")
        }
    }

    func testPrintableRunWrapsAtTheEdge() {
        let s = TerminalScreen(cols: 4, rows: 3)
        s.feed("abcdefghij")
        XCTAssertEqual(s.text(row: 0), "abcd")
        XCTAssertEqual(s.text(row: 1), "efgh")
        XCTAssertEqual(s.text(row: 2), "ij  ")
        XCTAssertEqual(s.cursorRow, 2)
        XCTAssertEqual(s.cursorCol, 2)
    }

    func testRunCarriesCurrentAttributes() {
        let s = TerminalScreen(cols: 8, rows: 1)
        s.feed("\u{1B}[1;31mab\u{1B}[0mc")
        XCTAssertEqual(s.cell(row: 0, col: 1).fg, .index(1))
        XCTAssertTrue(s.cell(row: 0, col: 1).bold)
        XCTAssertEqual(s.cell(row: 0, col: 2).fg, .default)
        XCTAssertFalse(s.cell(row: 0, col: 2).bold)
    }

    func testScrollRegionScrollsOnlyInsideIt() {
        let s = TerminalScreen(cols: 3, rows: 4)
        s.feed("aaa\r\nbbb\r\nccc\r\nddd")
        s.feed("\u{1B}[2;3r\u{1B}[3;1H\n")
        XCTAssertEqual(s.text(row: 0), "aaa")
        XCTAssertEqual(s.text(row: 1), "ccc")
        XCTAssertEqual(s.text(row: 2), "   ")
        XCTAssertEqual(s.text(row: 3), "ddd")
        s.feed("\u{1B}[2;1H\u{1B}M")  // reverse index at the region's top
        XCTAssertEqual(s.text(row: 1), "   ")
        XCTAssertEqual(s.text(row: 2), "ccc")
        XCTAssertEqual(s.text(row: 3), "ddd")
    }

    /// `\n` then `CSI 2 M` on a three-row screen trapped; so did IL/DL with
    /// the cursor below the scroll region. Both are no-ops outside it now.
    func testDeleteAndInsertLinesNearTheBottomDoNotTrap() {
        let s = TerminalScreen(cols: 6, rows: 3)
        s.feed("one\r\ntwo\r\nsix")
        s.feed("\u{1B}[2;1H\u{1B}[2M")
        XCTAssertEqual(s.text(row: 0), "one   ")
        XCTAssertEqual(s.text(row: 1), "      ")
        XCTAssertEqual(s.text(row: 2), "      ")
        s.feed("\u{1B}[H\u{1B}[2Jab\r\ncd\r\nef\u{1B}[1;2r\u{1B}[3;1H\u{1B}[M\u{1B}[L")
        XCTAssertEqual(s.text(row: 2), "ef    ")
        s.feed("\u{1B}[r\u{1B}[1;1H\u{1B}[L")
        XCTAssertEqual(s.text(row: 0), "      ")
        XCTAssertEqual(s.text(row: 1), "ab    ")
        XCTAssertEqual(s.text(row: 2), "cd    ")
    }

    func testCSIParametersParseAsBefore() {
        let cases: [(String, AnsiParser.Output)] = [
            ("\u{1B}[m", .setGraphics([0])),
            ("\u{1B}[0m", .setGraphics([0])),
            ("\u{1B}[;1m", .setGraphics([0, 1])),
            ("\u{1B}[1;m", .setGraphics([1, 0])),
            ("\u{1B}[38;5;208m", .setGraphics([38, 5, 208])),
            // Colon sub-parameters are not supported: the part reads as 0.
            ("\u{1B}[38:2:1:2:3m", .setGraphics([0])),
            ("\u{1B}[H", .cursorPosition(row: 1, col: 1)),
            ("\u{1B}[5;8H", .cursorPosition(row: 5, col: 8)),
            ("\u{1B}[;8H", .cursorPosition(row: 1, col: 8)),
            ("\u{1B}[?1049h", .privateModes(modes: [1049], set: true)),
            ("\u{1B}[?25;1l", .privateModes(modes: [25, 1], set: false)),
            ("\u{1B}[?h", .privateModes(modes: [0], set: true)),
            ("\u{1B}[3;r", .setScrollRegion(top: 3, bottom: 3)),
            ("\u{1B}[99999999999999999999A", .cursorUp(1)),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(AnsiParser().feed(Data(input.utf8)), [expected], input.debugDescription)
        }
    }
}

private extension TerminalScreen {
    func text(row: Int) -> String {
        String((0..<cols).map { Character(cell(row: row, col: $0).scalar) })
    }
}
