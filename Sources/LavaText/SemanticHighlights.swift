/// Highlighting a language server worked out — what the lexer cannot know,
/// such as that this identifier is a type and that one a parameter — kept
/// per logical line and laid over the lexer's spans.
///
/// Sparse on purpose: a server only reports the identifiers it has something
/// to say about, and everything between them keeps the lexer's colour. That
/// is also what keeps the lexer useful while the server is busy: a keystroke
/// is coloured at once, and refined when the reply comes.
public struct SemanticHighlights: Sendable, Equatable {
    /// Spans per logical line, columns in characters, sorted and disjoint.
    public private(set) var lines: [Int: [HighlightSpan]]

    public init(lines: [Int: [HighlightSpan]] = [:]) {
        self.lines = lines.mapValues { $0.sorted { $0.range.lowerBound < $1.range.lowerBound } }
    }

    public var isEmpty: Bool { lines.isEmpty }

    /// These highlights after an edit that replaced logical lines
    /// `old.lowerBound...old.upperBound` with `old.lowerBound...newLast`:
    /// lines above keep their spans, lines below move by the difference, and
    /// the edited ones take `replacement`, keyed by their new line numbers.
    ///
    /// Spans are columns within their own line, so no other line changes —
    /// which is what lets a keystroke convert only the tokens it touched
    /// rather than every token in the document.
    public func replacing(
        _ old: ClosedRange<Int>, newLast: Int, with replacement: [Int: [HighlightSpan]]
    ) -> SemanticHighlights {
        let delta = newLast - old.upperBound
        var result = SemanticHighlights()
        result.lines.reserveCapacity(lines.count + replacement.count)
        for (line, spans) in lines {
            if line < old.lowerBound {
                result.lines[line] = spans
            } else if line > old.upperBound {
                result.lines[line + delta] = spans
            }
        }
        for (line, spans) in replacement where (old.lowerBound...newLast).contains(line) && !spans.isEmpty {
            result.lines[line] = spans.sorted { $0.range.lowerBound < $1.range.lowerBound }
        }
        return result
    }

    /// `base` — the lexer's spans for `line` — with this line's spans laid
    /// over it: inside a semantic span its style wins, outside it the
    /// lexer's stands, cut where the two meet.
    public func overlay(_ base: [HighlightSpan], line: Int) -> [HighlightSpan] {
        guard let top = lines[line], !top.isEmpty else { return base }
        var result: [HighlightSpan] = []
        result.reserveCapacity(base.count + top.count)
        for span in base {
            var lower = span.range.lowerBound
            let upper = span.range.upperBound
            for cover in top where cover.range.upperBound > lower && cover.range.lowerBound < upper {
                if cover.range.lowerBound > lower {
                    result.append(HighlightSpan(range: lower..<cover.range.lowerBound, styleIndex: span.styleIndex))
                }
                lower = max(lower, cover.range.upperBound)
                if lower >= upper { break }
            }
            if lower < upper {
                result.append(HighlightSpan(range: lower..<upper, styleIndex: span.styleIndex))
            }
        }
        result.append(contentsOf: top)
        result.sort { $0.range.lowerBound < $1.range.lowerBound }
        return result
    }
}
