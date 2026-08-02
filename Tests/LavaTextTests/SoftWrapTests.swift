import XCTest

@testable import LavaText

/// Wrapping is tested with *synthetic* advances — every character 10 wide — so
/// the break positions are arithmetic rather than font-dependent. That is the
/// whole reason the algorithm takes measured advances instead of measuring.
final class SoftWrapTests: XCTestCase {

    private func uniform(_ text: String, _ w: Float = 10) -> [Float] {
        Array(repeating: w, count: text.count)
    }

    private func rows(_ text: String, width: Float) -> [String] {
        SoftWrap.rows(text: text, advances: uniform(text), maxWidth: width)
            .map { r in
                let s = text.index(text.startIndex, offsetBy: r.lowerBound)
                let e = text.index(text.startIndex, offsetBy: r.upperBound)
                return String(text[s..<e])
            }
    }

    // MARK: Breaking

    func testShortTextIsOneRow() {
        XCTAssertEqual(rows("abc", width: 100), ["abc"])
    }

    func testEmptyTextStillYieldsARow() {
        XCTAssertEqual(rows("", width: 100), [""], "the caret needs somewhere to sit")
    }

    func testBreaksAtWhitespace() {
        // 10px per char, 60px rows: "foo bar baz" → "foo " / "bar " / "baz"
        XCTAssertEqual(rows("foo bar baz", width: 60), ["foo ", "bar ", "baz"])
    }

    /// The space stays on the row it ended, which is where text engines put it.
    func testTrailingSpaceStaysOnTheRowItEnded() {
        let r = rows("ab cd", width: 30)
        XCTAssertEqual(r.first, "ab ")
    }

    /// A single token longer than the row must break rather than overflow,
    /// otherwise one long word pushes text outside the box.
    func testOverlongWordIsForceBroken() {
        XCTAssertEqual(rows("abcdefgh", width: 30), ["abc", "def", "gh"])
    }

    func testWordLongerThanRowAfterAShortOne() {
        let r = rows("hi abcdefgh", width: 30)
        XCTAssertEqual(r.first, "hi ")
        XCTAssertTrue(r.count > 2, "the long word then force-breaks")
    }

    func testZeroWidthDegradesToOneRowRatherThanLooping() {
        XCTAssertEqual(rows("abc", width: 0), ["abc"])
    }

    // MARK: VisualLayout

    func testLogicalLayoutSplitsOnNewlines() {
        let l = VisualLayout.logical("ab\ncd\n")
        XCTAssertEqual(l.count, 3, "a trailing newline leaves an empty last row")
    }

    /// `logicalRows` has a byte-scan fast path that only applies when every
    /// byte is ASCII and no CR is present. It has to agree with the
    /// grapheme walk exactly, including on the buffers that disqualify it —
    /// a wrong row table means glyphs drawn from the wrong offsets.
    func testLogicalRowsMatchGraphemeWalk() {
        func reference(_ text: String) -> [Range<Int>] {
            var rows: [Range<Int>] = []
            var start = 0
            var offset = 0
            for ch in text {
                if ch == "\n" {
                    rows.append(start..<offset)
                    start = offset + 1
                }
                offset += 1
            }
            rows.append(start..<offset)
            return rows
        }

        let cases = [
            "",
            "\n",
            "one line",
            "ab\ncd\n",
            "\n\n\n",
            // Disqualifies the fast path: multi-byte scalars make a character
            // offset differ from a byte offset.
            "héllo\nwörld\n",
            "emoji 👩‍👩‍👧‍👦 here\nnext\n",
            "combining e\u{0301}\nnext",
            // CRLF is one grapheme cluster, so byte offsets are wrong even
            // though every byte is ASCII.
            "a\r\nb\r\nc",
            "trailing cr\r",
        ]
        for text in cases {
            XCTAssertEqual(
                VisualLayout.logicalRows(text), reference(text),
                "row table disagrees for \(text.debugDescription)"
            )
        }
    }

    func testRowIndexAndColumn() {
        let l = VisualLayout(rows: [0..<3, 3..<7])
        XCTAssertEqual(l.rowIndex(ofOffset: 0), 0)
        XCTAssertEqual(l.rowIndex(ofOffset: 5), 1)
        XCTAssertEqual(l.column(ofOffset: 5), 2)
    }

    func testOffsetClampsToRow() {
        let l = VisualLayout(rows: [0..<3, 3..<7])
        XCTAssertEqual(l.offset(row: 0, column: 99), 3, "clamped to the row end")
    }

    // MARK: Navigation over wrapped rows

    /// Down must step to the next *visual* row, not the next logical line —
    /// otherwise wrapped rows are skipped entirely.
    func testVerticalMovementFollowsVisualRows() {
        var s = TextEditingState("foo bar baz")
        s.setVisualRows([0..<4, 4..<8, 8..<11])
        s.setCursor(s.index(atOffset: 1))    // row 0, column 1

        s.moveDown()
        XCTAssertEqual(s.offset(of: s.focus), 5, "row 1, same column")

        s.moveDown()
        XCTAssertEqual(s.offset(of: s.focus), 9, "row 2, same column")
    }

    func testDesiredColumnSurvivesAShortVisualRow() {
        var s = TextEditingState("abcdefg" + "hi" + "jklmnop")
        s.setVisualRows([0..<7, 7..<9, 9..<16])
        s.setCursor(s.index(atOffset: 5))    // row 0, column 5

        s.moveDown()
        XCTAssertEqual(s.offset(of: s.focus), 9, "clamped to the two-char row")

        s.moveDown()
        XCTAssertEqual(s.offset(of: s.focus), 14, "original column restored")
    }

    func testHomeAndEndActOnTheVisualRow() {
        var s = TextEditingState("foo bar baz")
        s.setVisualRows([0..<4, 4..<8, 8..<11])
        s.setCursor(s.index(atOffset: 6))

        s.moveToLineStart()
        XCTAssertEqual(s.offset(of: s.focus), 4, "start of the wrapped row")

        s.moveToLineEnd()
        XCTAssertEqual(s.offset(of: s.focus), 8, "end of the wrapped row")
    }

    /// With no wrap installed, navigation must fall back to logical lines.
    func testNilVisualRowsFallsBackToLogicalLines() {
        var s = TextEditingState("ab\ncdef")
        s.setVisualRows(nil)
        s.setCursor(s.index(atOffset: 1))
        s.moveDown()
        XCTAssertEqual(s.lineIndex(of: s.focus), 1)
    }
}
