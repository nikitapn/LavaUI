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

    /// `logicalRows` has a byte-scan fast path. It applies per *line* — an
    /// ASCII line is counted by its byte count and any other line is decoded
    /// and counted — and the whole buffer falls back to the grapheme walk
    /// only for CR, which is the one thing that makes a line break stop being
    /// one character. It has to agree with the walk exactly, including on the
    /// buffers that disqualify it: a wrong row table means glyphs drawn from
    /// the wrong offsets.
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
            // What a real log looks like: thousands of ASCII lines with a
            // stray accented word somewhere in the middle. Every line but one
            // takes the byte count; the odd one out is decoded on its own.
            (1...50).map { $0 == 27 ? "ligne \($0) déjà vu" : "line \($0)" }
                .joined(separator: "\n"),
            // Non-ASCII at the very edges of a line, where a per-line count
            // is easiest to get off by one.
            "é\nabc\né",
            "abcé\n👍\nz",
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

    /// The byte scan steps eight bytes at a time while nothing interesting is
    /// in them, so *where* the interesting byte falls within a word is the
    /// thing that can go wrong. These put a newline, a non-ASCII scalar and a
    /// CR at every offset in a long buffer, which is the only way that lands
    /// on every lane and every partial-word tail.
    func testLineIndexAgreesWithTheWalkAtEveryAlignment() {
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

        for filler in ["a", "ab", "abc"] {
            for length in [1, 7, 8, 9, 15, 16, 17, 31, 64, 129] {
                let base = String(repeating: filler, count: length)
                for at in 0...base.count {
                    // "\r\n" is the one that matters most: Swift counts it as a
                    // single `Character`, so a scan that skipped past the CR
                    // and split on the LF would report one line too many —
                    // and a lone CR alone would not show that, because there
                    // the byte count and the character count still agree.
                    for insert in ["\n", "é", "👍", "\r", "\r\n"] {
                        var text = base
                        text.insert(
                            contentsOf: insert,
                            at: text.index(text.startIndex, offsetBy: at)
                        )
                        XCTAssertEqual(
                            VisualLayout.logicalRows(text), reference(text),
                            "row table disagrees for \(text.debugDescription)"
                        )
                    }
                }
            }
        }
    }

    /// And the byte ranges have to name the same lines the character ranges
    /// do, or the wrap plan slices the wrong text out of the buffer.
    func testByteRangesNameTheSameLines() {
        let cases = [
            "",
            "\n",
            (0..<40).map { "line \($0) with some length to it" }.joined(separator: "\n"),
            "héllo\nwörld\n👍 emoji here\nplain",
            "a\n\nb\n\n\nc",
        ]
        for text in cases {
            let index = VisualLayout.lineIndex(text)
            let bytes = Array(text.utf8)
            XCTAssertEqual(index.rows.count, index.byteRanges.count, text.debugDescription)
            for (n, range) in index.byteRanges.enumerated() {
                let line = String(decoding: bytes[range], as: UTF8.self)
                XCTAssertFalse(line.contains("\n"), "line \(n) swallowed a newline")
                XCTAssertEqual(
                    line.count, index.rows[n].count,
                    "line \(n) of \(text.debugDescription) disagrees about its length"
                )
                XCTAssertEqual(index.line(atByte: range.lowerBound), n)
                if !range.isEmpty {
                    XCTAssertEqual(index.line(atByte: range.upperBound - 1), n)
                }
            }
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
