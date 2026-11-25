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
        let span = HighlightPaint.byteSpan(of: wanted, lines: lines, total: bytes.count)
        var captures: [HighlightPaint.Capture] = []
        if !span.isEmpty {
            let cursor = query.execute(node: root, in: tree)
            cursor.setByteRange(range: UInt32(span.lowerBound)..<UInt32(span.upperBound))
            while let match = cursor.next() {
                guard allows(match, bytes: bytes) else { continue }
                for capture in match.captures {
                    guard capture.index < names.count, let name = names[capture.index] else { continue }
                    let range = capture.node.byteRange
                    captures.append(.init(
                        start: Int(range.lowerBound), end: Int(range.upperBound),
                        priority: match.patternIndex, name: name
                    ))
                }
            }
        }
        return HighlightPaint.layer(
            captures, bytes: bytes, lines: lines, wanted: wanted, revision: revision
        )
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
