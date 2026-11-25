import Foundation
import LavaText
internal import SwiftTreeSitter

/// Spans for a range of lines, from a language's `highlights.scm`.
///
/// Capture names are `HighlightName`s, so a theme colours them without a
/// table of its own. Where captures overlap, the rules are tree-sitter's own
/// highlighter's, which the grammars' query files are written for: of the
/// patterns that capture the *same* node, the last in the file wins (they go
/// from general to specific — `(identifier) @variable` first, `@function`
/// for a called one after it); and a node inside another overrides it for
/// its own extent (an escape inside a string).
///
/// A capture whose name starts with `_` only feeds a predicate and colours
/// nothing. `#match?`, `#eq?` and `#any-of?` (and their negations) are
/// evaluated against the buffer's bytes; SwiftTreeSitter's own evaluation
/// assumes UTF-16 ranges, which this tree was not parsed in.
struct HighlightQuery {
    let query: Query
    /// Capture index → `HighlightName` index, nil for a `_` capture.
    private let names: [Int?]

    /// Lines longer than this are left to the editor's own highlighter: a
    /// minified file's one line would otherwise be walked a character at a
    /// time on every publish.
    static let longestLine = 10_000

    init(_ query: Query) {
        self.query = query
        names = (0..<query.captureCount).map { index in
            guard let name = query.captureName(for: index), !name.hasPrefix("_") else { return nil }
            return HighlightName.index(of: name)
        }
    }

    func layer(
        tree: MutableTree, root: Node, bytes: UnsafeBufferPointer<UInt8>, lines: LineStarts,
        wanted: Range<Int>, revision: UInt64
    ) -> HighlightLayer {
        let starts = lines.starts
        let first = min(max(0, wanted.lowerBound), starts.count)
        let last = min(max(first, wanted.upperBound), starts.count)
        guard first < last else { return HighlightLayer(revision: revision, lineCount: starts.count, lines: [:]) }
        let spanStart = starts[first]
        let spanEnd = last < starts.count ? starts[last] : bytes.count

        // Captures in the span, as (start, end, pattern, name).
        var captures: [(start: Int, end: Int, pattern: Int, name: Int)] = []
        let cursor = query.execute(node: root, in: tree)
        cursor.setByteRange(range: UInt32(spanStart)..<UInt32(spanEnd))
        while let match = cursor.next() {
            guard allows(match, bytes: bytes) else { continue }
            for capture in match.captures {
                guard capture.index < names.count, let name = names[capture.index] else { continue }
                let range = capture.node.byteRange
                let start = max(Int(range.lowerBound), spanStart)
                let end = min(Int(range.upperBound), spanEnd)
                guard start < end else { continue }
                captures.append((start, end, match.patternIndex, name))
            }
        }
        // Painted outermost first and, for one node, in pattern order, so the
        // inner node and the later pattern are what is left showing.
        captures.sort {
            let a = $0.end - $0.start, b = $1.end - $1.start
            return a != b ? a > b : $0.pattern < $1.pattern
        }
        var paint = [Int32](repeating: -1, count: spanEnd - spanStart)
        for capture in captures {
            for index in (capture.start - spanStart)..<(capture.end - spanStart) { paint[index] = Int32(capture.name) }
        }

        var result: [Int: HighlightLayer.Line] = [:]
        result.reserveCapacity(last - first)
        for line in first..<last {
            let start = starts[line]
            let end = line + 1 < starts.count ? starts[line + 1] - 1 : bytes.count
            guard end - start <= Self.longestLine else { continue }
            let text = String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<end]), as: UTF8.self)
            result[line] = HighlightLayer.Line(text: text, spans: Self.spans(of: text, from: start, paint: paint, base: spanStart))
        }
        return HighlightLayer(revision: revision, lineCount: starts.count, lines: result)
    }

    /// Runs of one name, in characters: a character takes the name painted
    /// on its first byte.
    private static func spans(of text: String, from start: Int, paint: [Int32], base: Int) -> [HighlightSpan] {
        var spans: [HighlightSpan] = []
        var column = 0
        var byte = start - base
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

    private func allows(_ match: QueryMatch, bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        match.predicates.allSatisfy { predicate in
            switch predicate {
            case .set, .generic, .isNot:
                return true
            default:
                return predicate.captures(in: match).allSatisfy { capture in
                    let range = capture.node.byteRange
                    let text = String(decoding: UnsafeBufferPointer(
                        rebasing: bytes[Int(range.lowerBound)..<min(Int(range.upperBound), bytes.count)]
                    ), as: UTF8.self)
                    return predicate.evalulate(with: text)
                }
            }
        }
    }
}
