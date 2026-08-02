import Foundation

/// Greedy line breaking.
///
/// Takes *measured advances* rather than doing any measuring itself, which is
/// what keeps it in `LavaText`: the caller supplies one advance per Character
/// and this decides where the breaks fall. Synthetic advances make every rule
/// below testable without a font.
public enum SoftWrap {
    /// Splits `text` into row ranges (character offsets, relative to `text`)
    /// that each fit within `maxWidth`.
    ///
    /// Always returns at least one row, even for empty input — the caret has
    /// to have somewhere to sit.
    public static func rows(
        text: String, advances: [Float], maxWidth: Float
    ) -> [Range<Int>] {
        let count = text.count
        guard count > 0, maxWidth > 0, advances.count >= count else {
            return [0..<count]
        }

        var result: [Range<Int>] = []
        var rowStart = 0
        var width: Float = 0
        // Last position where a break would look intentional, and the width up
        // to it, so we can rewind without re-measuring.
        var lastBreak: Int?

        for (i, ch) in text.enumerated() {
            let advance = advances[i]

            // A break opportunity sits *after* whitespace: "foo bar" wrapping
            // between the words leaves the space on the first row, which is
            // where every text engine puts it.
            if ch.isWhitespace { lastBreak = i + 1 }

            if width + advance > maxWidth, i > rowStart {
                if let brk = lastBreak, brk > rowStart, brk <= i {
                    result.append(rowStart..<brk)
                    rowStart = brk
                } else {
                    // A single word longer than the row: break mid-word rather
                    // than overflow. Anything else would let one long token
                    // push text outside the box.
                    result.append(rowStart..<i)
                    rowStart = i
                }
                lastBreak = nil
                // Re-accumulate from the new row start.
                width = 0
                for j in rowStart...i where j < advances.count {
                    width += advances[j]
                }
                continue
            }
            width += advance
        }

        result.append(rowStart..<count)
        return result
    }
}

/// Which side of a wrap boundary a caret belongs to.
public enum CaretAffinity: Equatable, Sendable {
    /// The row that *starts* at this offset — a click, or Home.
    case downstream
    /// The row that *ends* at this offset — a vertical move whose column was
    /// clamped to that row's end.
    case upstream
}

/// Where each visual row begins and ends, in character offsets over the whole
/// buffer.
///
/// With wrapping, a visual row is no longer a logical line, and every mapping
/// — caret, hit test, selection, vertical movement — has to use *this* rather
/// than newline positions.
public struct VisualLayout: Equatable {
    public var rows: [Range<Int>]

    public init(rows: [Range<Int>]) {
        self.rows = rows.isEmpty ? [0..<0] : rows
    }

    /// One row per logical line — the no-wrapping case.
    public static func logical(_ text: String) -> VisualLayout {
        VisualLayout(rows: logicalRows(text))
    }

    /// Row boundaries for `logical(_:)`, exposed separately so a caller (an
    /// editor leaf with wrapping off) can cache the result via
    /// `TextEditingState.setVisualRows` instead of recomputing this O(length)
    /// scan on every `layout` access — which, left uncached, is what a large
    /// buffer felt: every caret draw, hit test, and gutter row rescanned the
    /// whole document.
    public static func logicalRows(_ text: String) -> [Range<Int>] {
        if let rows = asciiLogicalRows(text) { return rows }

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

    /// The same scan over raw UTF-8, valid only when every byte is ASCII —
    /// then a character offset *is* a byte offset and no grapheme breaking is
    /// needed. Nil when that does not hold, so the caller falls back.
    ///
    /// Worth the special case because the `for ch in text` walk above
    /// materialises a `Character` per position, and each one is a small
    /// allocation and a bridge-object release. On a 10 MB log that is ~130ms
    /// every time the editor mounts; the byte scan is a few. Logs, source
    /// files and config are overwhelmingly ASCII, and anything else still gets
    /// the correct answer from the walk.
    ///
    /// CR bails out as well as non-ASCII: Swift treats "\r\n" as one grapheme
    /// cluster, so a buffer that still has CRLF in it breaks the offset
    /// identity this depends on even though every byte is ASCII.
    private static func asciiLogicalRows(_ text: String) -> [Range<Int>]? {
        let scanned: [Range<Int>]?? = text.utf8.withContiguousStorageIfAvailable { bytes in
            var rows: [Range<Int>] = []
            var start = 0
            for i in 0..<bytes.count {
                let byte = bytes[i]
                if byte >= 0x80 || byte == 0x0D { return nil }
                if byte == 0x0A {
                    rows.append(start..<i)
                    start = i + 1
                }
            }
            rows.append(start..<bytes.count)
            return rows
        }
        return scanned ?? nil
    }

    public var count: Int { rows.count }

    /// Row containing `offset`.
    ///
    /// At a soft-wrap boundary one offset is *both* the end of a row and the
    /// start of the next, and there is no way to pick from the offset alone —
    /// which is why carets carry an affinity. Upstream keeps the caret on the
    /// row that ended (where a clamped vertical move should stay); downstream
    /// puts it on the row that starts (where a click or Home should land).
    public func rowIndex(ofOffset offset: Int, affinity: CaretAffinity = .downstream) -> Int {
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

    public func column(ofOffset offset: Int, affinity: CaretAffinity = .downstream) -> Int {
        let row = rows[rowIndex(ofOffset: offset, affinity: affinity)]
        return max(0, offset - row.lowerBound)
    }

    /// Offset at `row`/`column`, clamped to that row.
    public func offset(row: Int, column: Int) -> Int {
        let r = rows[max(0, min(row, rows.count - 1))]
        return min(r.lowerBound + max(0, column), r.upperBound)
    }
}
