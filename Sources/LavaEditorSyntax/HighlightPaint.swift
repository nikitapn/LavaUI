import LavaText

/// Byte ranges with highlight names in, a `HighlightLayer` of per-line
/// character spans out — the part every source of syntax colour shares,
/// whether the ranges came from a tree-sitter query or from SwiftSyntax's
/// classifier.
enum HighlightPaint {
    struct Capture {
        let start: Int
        let end: Int
        /// Among ranges that are exactly equal, the higher one shows.
        let priority: Int
        /// A `HighlightName` index.
        let name: Int
    }

    /// Lines longer than this are left to the editor's own highlighter: a
    /// minified file's one line would otherwise be walked a character at a
    /// time on every publish.
    static let longestLine = 10_000

    /// The bytes lines `wanted` occupy, clamped to the buffer.
    static func byteSpan(of wanted: Range<Int>, lines: LineStarts, total: Int) -> Range<Int> {
        let starts = lines.starts
        let first = min(max(0, wanted.lowerBound), starts.count)
        let last = min(max(first, wanted.upperBound), starts.count)
        guard first < last else { return 0..<0 }
        return starts[first]..<(last < starts.count ? starts[last] : total)
    }

    /// Paints outermost first and, for one range, in priority order, so the
    /// innermost range and the highest priority are what is left showing.
    static func layer(
        _ captures: [Capture], bytes: UnsafeBufferPointer<UInt8>, lines: LineStarts,
        wanted: Range<Int>, revision: UInt64
    ) -> HighlightLayer {
        let starts = lines.starts
        let span = byteSpan(of: wanted, lines: lines, total: bytes.count)
        guard !span.isEmpty else { return HighlightLayer(revision: revision, lineCount: starts.count, lines: [:]) }
        let first = min(max(0, wanted.lowerBound), starts.count)
        let last = min(max(first, wanted.upperBound), starts.count)

        let ordered = captures.sorted {
            let a = $0.end - $0.start, b = $1.end - $1.start
            return a != b ? a > b : $0.priority < $1.priority
        }
        var paint = [Int32](repeating: -1, count: span.count)
        for capture in ordered {
            let start = max(capture.start, span.lowerBound)
            let end = min(capture.end, span.upperBound)
            guard start < end else { continue }
            for index in (start - span.lowerBound)..<(end - span.lowerBound) { paint[index] = Int32(capture.name) }
        }

        var result: [Int: HighlightLayer.Line] = [:]
        result.reserveCapacity(last - first)
        for line in first..<last {
            let start = starts[line]
            let end = line + 1 < starts.count ? starts[line + 1] - 1 : bytes.count
            guard end - start <= longestLine else { continue }
            let text = String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<end]), as: UTF8.self)
            result[line] = HighlightLayer.Line(
                text: text, spans: spans(of: text, from: start - span.lowerBound, paint: paint)
            )
        }
        return HighlightLayer(revision: revision, lineCount: starts.count, lines: result)
    }

    /// Runs of one name, in characters: a character takes the name painted
    /// on its first byte.
    private static func spans(of text: String, from start: Int, paint: [Int32]) -> [HighlightSpan] {
        var spans: [HighlightSpan] = []
        var column = 0
        var byte = start
        var runName: Int32 = -1
        var runStart = 0
        for character in text {
            let name = byte < paint.count ? paint[byte] : -1
            if name != runName {
                if runName >= 0 { spans.append(HighlightSpan(range: runStart..<column, styleIndex: Int(runName))) }
                runName = name
                runStart = column
            }
            column += 1
            byte += character.utf8.count
        }
        if runName >= 0, runStart < column {
            spans.append(HighlightSpan(range: runStart..<column, styleIndex: Int(runName)))
        }
        return spans
    }
}
