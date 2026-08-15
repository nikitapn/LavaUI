import XCTest

@testable import LavaText

/// `VisualLayout.rowIndex` answers where the caret's row is, and it is on the
/// path of every redraw while a selection is dragged. It was a scan of every
/// row; it is now a binary search that hands off to that same scan.
///
/// These are equivalence tests against the scan, not expectation tests: the
/// boundary rules (an offset that is both the end of one row and the start of
/// the next, empty rows sharing a position, the offset *of* a newline) are
/// subtle enough that hand-written expectations would test my reading of them
/// rather than the behaviour that shipped.
final class RowIndexTests: XCTestCase {
    /// What `rowIndex` was before the search was put in front of it.
    private func linearScan(
        _ rows: [Range<Int>], _ offset: Int, _ affinity: CaretAffinity
    ) -> Int {
        for (i, row) in rows.enumerated() {
            if offset < row.upperBound, offset >= row.lowerBound { return i }
            if offset == row.upperBound {
                let nextStartsHere = i + 1 < rows.count && rows[i + 1].lowerBound == offset
                if affinity == .downstream, nextStartsHere { continue }
                return i
            }
        }
        return max(0, rows.count - 1)
    }

    private func assertMatchesScan(
        _ rows: [Range<Int>], upTo limit: Int,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let layout = VisualLayout(rows: rows)
        for offset in -2...limit {
            for affinity in [CaretAffinity.downstream, .upstream] {
                XCTAssertEqual(
                    layout.rowIndex(ofOffset: offset, affinity: affinity),
                    linearScan(rows, offset, affinity),
                    "offset \(offset), \(affinity)", file: file, line: line
                )
            }
        }
    }

    func testLogicalRowsMatchTheScan() {
        // "abc\nde\n\nfghi" — note the empty line, which is an empty row.
        assertMatchesScan([0..<3, 4..<6, 7..<7, 8..<12], upTo: 15)
    }

    func testWrappedRowsMatchTheScan() {
        // A soft wrap shares an offset between two rows: 6 is both the end of
        // the first and the start of the second, which is what affinity is for.
        assertMatchesScan([0..<6, 6..<12, 12..<15], upTo: 18)
    }

    func testConsecutiveEmptyRowsMatchTheScan() {
        // Several rows at the same position — a run of blank lines, where
        // downstream has to walk past all of them and upstream must not.
        assertMatchesScan([0..<3, 4..<4, 5..<5, 6..<6, 7..<10], upTo: 13)
    }

    func testASingleEmptyRowMatchesTheScan() {
        assertMatchesScan([0..<0], upTo: 3)
    }

    func testRandomLayoutsMatchTheScan() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            var rows: [Range<Int>] = []
            var cursor = 0
            for _ in 0..<Int.random(in: 1...40, using: &generator) {
                let length = Int.random(in: 0...5, using: &generator)
                rows.append(cursor..<(cursor + length))
                // 0 leaves the next row starting where this one ended (a soft
                // wrap), 1 skips a newline (a logical line).
                cursor += length + Int.random(in: 0...1, using: &generator)
            }
            assertMatchesScan(rows, upTo: cursor + 3)
        }
    }

    /// The search must not change what a real buffer's layout answers either.
    func testLogicalLayoutOfARealBufferMatchesTheScan() {
        let text = "first\n\nthird line\nfourth\n\n\nseventh"
        let layout = VisualLayout.logical(text)
        for offset in 0...(text.count + 2) {
            for affinity in [CaretAffinity.downstream, .upstream] {
                XCTAssertEqual(
                    layout.rowIndex(ofOffset: offset, affinity: affinity),
                    linearScan(layout.rows, offset, affinity),
                    "offset \(offset), \(affinity)"
                )
            }
        }
    }
}
