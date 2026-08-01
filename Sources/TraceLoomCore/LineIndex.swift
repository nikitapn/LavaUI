/// Character offsets of a text's lines, computed in a single pass.
///
/// Exists because deriving one line's range on demand is fine and deriving
/// many is not. The version this replaces re-split the entire text and
/// re-summed the prefix for *every* diagnostic being decorated, which is
/// O(diagnostics x text): a rule referring to a capture group that does not
/// exist emits one diagnostic per matching line — ~126,000 on a 12 MB log —
/// and the resulting ~126,000 full splits per body evaluation stopped the
/// window responding at all.
///
/// Offsets are in `Character`s, matching what `EditorDecoration.range` means.
public struct LineIndex {
    /// Offset where each line begins, and its length excluding the newline.
    private let starts: [Int]
    private let lengths: [Int]

    public init(_ text: String) {
        self.init(text, upTo: Int.max)
    }

    /// Stops once line `maxLine` has been closed. Callers decorating a handful
    /// of early lines in a large log should not pay to index the rest of it.
    public init(_ text: String, upTo maxLine: Int) {
        var starts: [Int] = []
        var lengths: [Int] = []
        var offset = 0
        var lineStart = 0
        var stoppedEarly = false

        for character in text {
            // `"\r\n"` is one grapheme cluster in Swift and is *not* equal to
            // `"\n"`, so testing only for the latter reports a CRLF buffer as a
            // single line — which is how a 23 MB log once became one line and
            // took the process past 9 GB. Both terminators count as one
            // character here, matching the offsets `text` itself uses.
            if character == "\n" || character == "\r\n" || character == "\r" {
                starts.append(lineStart)
                lengths.append(offset - lineStart)
                lineStart = offset + 1
                if starts.count >= maxLine {
                    stoppedEarly = true
                    break
                }
            }
            offset += 1
        }
        // The trailing segment is a line too, even unterminated — and even
        // when empty, which is what `split(omittingEmptySubsequences: false)`
        // reported and what line numbering has to keep agreeing with.
        if !stoppedEarly {
            starts.append(lineStart)
            lengths.append(offset - lineStart)
        }

        self.starts = starts
        self.lengths = lengths
    }

    /// Number of lines indexed. Less than the text's total when construction
    /// was bounded by `maxLine`.
    public var count: Int { starts.count }

    /// 1-based, matching the line numbers `TraceParser` puts in diagnostics.
    /// Nil when the line is past the end of what was indexed.
    ///
    /// An empty line still yields a one-wide range: a zero-width decoration
    /// would be invisible, and a blank line is exactly where a "missing
    /// something here" marker needs to show.
    public func range(ofLine line: Int) -> Range<Int>? {
        guard line >= 1, line <= starts.count else { return nil }
        let start = starts[line - 1]
        return start..<(start + max(1, lengths[line - 1]))
    }
}
