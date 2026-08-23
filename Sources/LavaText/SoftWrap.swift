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

    /// The same scan over raw UTF-8. Nil when it cannot answer, so the caller
    /// falls back to the grapheme walk.
    ///
    /// Worth the special case because the `for ch in text` walk above
    /// materialises a `Character` per position, and each one is a small
    /// allocation and a bridge-object release. On a 10 MB log that is ~130ms
    /// every time the editor mounts; the byte scan is a few. Logs, source
    /// files and config are overwhelmingly ASCII, and anything else still gets
    /// the correct answer from the walk.
    ///
    /// **The ASCII test is per line, not per buffer.** A grapheme cluster
    /// never spans a newline (CRLF excepted, below), so a line's character
    /// count is a property of that line alone: an ASCII line's is its byte
    /// count, and any other line is counted by decoding just that line. That
    /// matters because the all-or-nothing version fell off the fast path for
    /// the *whole file* on the first non-ASCII byte anywhere in it — one `é`
    /// in a 4 MB log, and every rescan cost 50 ms instead of 2 ms. Files with
    /// a stray accented word in them are not the rare case.
    ///
    /// CR still bails out for the whole buffer: Swift treats "\r\n" as one
    /// grapheme cluster, so with CRLF in play a line break is not one
    /// character and the offsets between lines stop lining up — which is not
    /// something a per-line count can repair.
    private static func asciiLogicalRows(_ text: String) -> [Range<Int>]? {
        let scanned: [Range<Int>]?? = text.utf8.withContiguousStorageIfAvailable { bytes in
            var rows: [Range<Int>] = []
            // Byte where the current line starts, and the character offset of
            // that byte. They diverge on the first non-ASCII line and stay
            // diverged, which is the whole reason both are tracked.
            var lineStart = 0
            var charStart = 0
            var lineIsASCII = true

            @inline(__always)
            func closeLine(endingAt end: Int) -> Bool {
                let length: Int
                if lineIsASCII {
                    length = end - lineStart
                } else {
                    // Only this line is decoded, and only when it needs to be.
                    let slice = UnsafeBufferPointer(
                        rebasing: bytes[lineStart..<end]
                    )
                    length = String(decoding: slice, as: UTF8.self).count
                }
                rows.append(charStart..<(charStart + length))
                charStart += length + 1  // + the newline that ended it
                lineStart = end + 1
                lineIsASCII = true
                return true
            }

            for i in 0..<bytes.count {
                let byte = bytes[i]
                if byte == 0x0D { return nil }
                if byte >= 0x80 {
                    lineIsASCII = false
                    continue
                }
                if byte == 0x0A { _ = closeLine(endingAt: i) }
            }
            _ = closeLine(endingAt: bytes.count)
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
        // The scan below is the definition of this function, boundary rules
        // and all; the search only decides where it may start.
        //
        // A row whose `upperBound` is below `offset` satisfies neither branch —
        // the first needs `offset < upperBound`, the second `offset ==
        // upperBound` — so the loop skips every one of them, and starting past
        // them cannot change the answer. `upperBound` is non-decreasing across
        // rows (they are ordered and do not overlap), so the first row that
        // could match is a binary search away.
        //
        // Worth doing because this is on the caret's path: it ran per redraw
        // while a selection was being dragged, and at 9,200 rows the scan was
        // ~1.1ms of every frame — the whole remaining cost once the buffer
        // walks around it were fixed. It grows with the file, so a 225,000-row
        // log paid ~25ms a frame for it.
        var i = firstRowEnding(atOrAfter: offset)
        while i < rows.count {
            let row = rows[i]
            if offset < row.upperBound, offset >= row.lowerBound { return i }
            if offset == row.upperBound {
                let nextStartsHere = i + 1 < rows.count && rows[i + 1].lowerBound == offset
                if affinity == .downstream, nextStartsHere {
                    i += 1
                    continue
                }
                return i
            }
            i += 1
        }
        return max(0, rows.count - 1)
    }

    /// First row whose `upperBound` is `>= offset`, or `rows.count` when none
    /// is — the lower bound of the scan above.
    private func firstRowEnding(atOrAfter offset: Int) -> Int {
        var low = 0
        var high = rows.count
        while low < high {
            let mid = low + (high - low) / 2
            if rows[mid].upperBound < offset {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
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
