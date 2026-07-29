import Foundation

/// A pattern-to-style mapping, applied per line.
///
/// Styles are **indices, not colours**: `LavaText` has no colour type and
/// should not grow one. The view owns a palette and resolves indices against
/// it, which also means a theme swap restyles code without touching rules.
public struct HighlightRule: Equatable, Sendable {
    public var pattern: String
    public var styleIndex: Int
    /// Higher wins where spans overlap. Keywords should outrank identifiers;
    /// comments and strings should outrank both.
    public var priority: Int

    public init(pattern: String, styleIndex: Int, priority: Int = 0) {
        self.pattern = pattern
        self.styleIndex = styleIndex
        self.priority = priority
    }
}

/// A styled character range within one line.
public struct HighlightSpan: Equatable, Sendable {
    public var range: Range<Int>   // character offsets within the line
    public var styleIndex: Int

    public init(range: Range<Int>, styleIndex: Int) {
        self.range = range
        self.styleIndex = styleIndex
    }
}

/// Applies rules to a line and resolves overlaps by priority.
///
/// Line-at-a-time on purpose: it keeps highlighting incremental (only visible
/// rows need work) and independent of scroll position. The cost is that
/// constructs spanning lines — a block comment, a multi-line string — cannot
/// be expressed. That is a real limit, and the point at which this needs to
/// grow into a stateful lexer rather than a rule list.
public struct SyntaxHighlighter {
    public var rules: [HighlightRule]
    private let compiled: [(regex: NSRegularExpression, rule: HighlightRule)]

    public init(rules: [HighlightRule]) {
        self.rules = rules
        // Invalid patterns are dropped rather than thrown: a bad rule should
        // cost its own highlighting, not the whole editor.
        self.compiled = rules.compactMap { rule in
            guard let re = try? NSRegularExpression(pattern: rule.pattern) else {
                return nil
            }
            return (re, rule)
        }
    }

    /// Spans for `line`, sorted by position, non-overlapping.
    public func spans(in line: String) -> [HighlightSpan] {
        guard !line.isEmpty, !compiled.isEmpty else { return [] }

        let ns = line as NSString
        let whole = NSRange(location: 0, length: ns.length)

        // Winning style per UTF-16 offset, so overlap resolution is a simple
        // priority comparison rather than interval surgery.
        var winner = [Int?](repeating: nil, count: ns.length)
        var winningPriority = [Int](repeating: Int.min, count: ns.length)

        for (regex, rule) in compiled {
            regex.enumerateMatches(in: line, range: whole) { match, _, _ in
                guard let r = match?.range, r.length > 0 else { return }
                for i in r.location..<(r.location + r.length) where i < winner.count {
                    if rule.priority >= winningPriority[i] {
                        winner[i] = rule.styleIndex
                        winningPriority[i] = rule.priority
                    }
                }
            }
        }

        // Collapse runs, converting UTF-16 offsets to character offsets.
        var spans: [HighlightSpan] = []
        var runStart: Int?
        var runStyle: Int?

        func closeRun(at end: Int) {
            guard let start = runStart, let style = runStyle else { return }
            if let lo = characterOffset(of: start, in: line, ns: ns),
               let hi = characterOffset(of: end, in: line, ns: ns), lo < hi
            {
                spans.append(HighlightSpan(range: lo..<hi, styleIndex: style))
            }
            runStart = nil
            runStyle = nil
        }

        for i in 0..<ns.length {
            if winner[i] != runStyle {
                closeRun(at: i)
                if winner[i] != nil {
                    runStart = i
                    runStyle = winner[i]
                }
            }
        }
        closeRun(at: ns.length)
        return spans
    }

    /// UTF-16 offset → Character offset, so spans line up with the rest of the
    /// editor, which counts in Characters throughout.
    private func characterOffset(
        of utf16Offset: Int, in line: String, ns: NSString
    ) -> Int? {
        guard utf16Offset >= 0, utf16Offset <= ns.length else { return nil }
        guard let idx = String.Index(
            String.Index(utf16Offset: utf16Offset, in: line), within: line
        ) else {
            return nil
        }
        return line.distance(from: line.startIndex, to: idx)
    }
}
