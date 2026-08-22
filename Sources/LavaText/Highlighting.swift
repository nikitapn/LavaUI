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

extension Array where Element == HighlightSpan {
    /// The part of a line's spans that falls inside `columns`, re-based so
    /// offset 0 is the start of that slice.
    ///
    /// Soft wrap is what needs this. Spans are produced per *logical line*
    /// (a stateful lexer cannot do otherwise — its state threads line to
    /// line), but a wrapped editor draws one visual row at a time and shapes
    /// each row's own substring, so a span still measured from the start of
    /// the logical line would colour the wrong characters on every row after
    /// the first. A token straddling a wrap boundary is clipped into one span
    /// per row, which is what makes it look continuous across the break.
    public func clipped(to columns: Range<Int>) -> [HighlightSpan] {
        guard columns.lowerBound != 0 || !isEmpty else { return [] }
        var result: [HighlightSpan] = []
        result.reserveCapacity(count)
        for span in self {
            let lower = Swift.max(span.range.lowerBound, columns.lowerBound)
            let upper = Swift.min(span.range.upperBound, columns.upperBound)
            guard lower < upper else { continue }
            result.append(HighlightSpan(
                range: (lower - columns.lowerBound)..<(upper - columns.lowerBound),
                styleIndex: span.styleIndex
            ))
        }
        return result
    }
}

/// A lexer whose highlighting for line N depends on what came before it — the
/// gap a per-line `HighlightRule` list cannot close: a block comment or a
/// string that opens on one line and closes on another.
///
/// `State` is the lexer's own notion of context ("inside a `/* */` comment",
/// "inside a string opened with `"""`, unterminated"); `initialState` is what
/// an empty document — or the very first line — starts with. `highlight`
/// takes the state the *previous* line ended in and returns both this line's
/// spans and the state the *next* line should start with. Chaining that
/// output forward, line after line, is what lets a construct span lines at
/// all; `SyntaxHighlighter`'s cache (see `EditorView`/`DrawList.emitEditor`)
/// is what keeps re-chaining it on every keystroke from costing the whole
/// file instead of just the lines a change actually invalidated.
public protocol StatefulLexer {
    associatedtype State: Hashable
    static var initialState: State { get }
    func highlight(_ line: String, state: State) -> (spans: [HighlightSpan], nextState: State)
}

/// Placeholder state for the rule-list form of `SyntaxHighlighter`, which
/// has no real state — every value is equal to every other, so a cache
/// comparing states across it always finds them unchanged (correct: nothing
/// about a rule-list line depends on anything above it).
private struct EmptyLexerState: Hashable {}

/// Type-erased wrapper so a lexer's own `State` type doesn't have to leak
/// into `SyntaxHighlighter`, which one `EditorView`/`LeafNode` holds
/// regardless of which kind of highlighting strategy backs it.
private struct AnyStatefulLexer {
    let initialState: AnyHashable
    let highlight: (String, AnyHashable) -> (spans: [HighlightSpan], nextState: AnyHashable)

    init<L: StatefulLexer>(_ lexer: L) {
        self.initialState = AnyHashable(L.initialState)
        self.highlight = { line, state in
            // Always reachable with a same-typed state in practice: callers
            // only ever seed with this same `initialState` or a value this
            // closure itself returned. Falling back to `initialState` rather
            // than trapping means a caller that got this wrong loses its
            // place in the lexer, not the whole editor.
            let typed = (state.base as? L.State) ?? L.initialState
            let (spans, next) = lexer.highlight(line, state: typed)
            return (spans, AnyHashable(next))
        }
    }
}

/// Applies rules to a line and resolves overlaps by priority — or, if built
/// from a `StatefulLexer` instead, threads that lexer's state line to line.
///
/// The rule-list form stays exactly what it was: independent of scroll
/// position, correct one line at a time, no notion of state at all. Most
/// syntax highlighting is that simple and should stay that simple —
/// `isStateful` is `false` for it, and every stateful-only entry point
/// degrades to the obvious single-line answer when called on it anyway.
public struct SyntaxHighlighter {
    public var rules: [HighlightRule]
    private let compiled: [(regex: NSRegularExpression, rule: HighlightRule)]
    private let lexer: AnyStatefulLexer?

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
        self.lexer = nil
    }

    public init<L: StatefulLexer>(lexer: L) {
        self.rules = []
        self.compiled = []
        self.lexer = AnyStatefulLexer(lexer)
    }

    public var isStateful: Bool { lexer != nil }

    /// `AnyHashable(())` for the rule-list form — it has no real state, but
    /// giving every highlighter *a* value here means a cache can seed the
    /// first line uniformly without special-casing which kind it holds.
    public var initialState: AnyHashable { lexer?.initialState ?? AnyHashable(EmptyLexerState()) }

    /// Spans for `line` alone, sorted by position, non-overlapping. For a
    /// stateful lexer this uses `initialState` regardless of what actually
    /// precedes `line` — correct only for a line with nothing meaningful
    /// above it. Real multi-line callers want `highlight(_:state:)`, chained
    /// through `SyntaxHighlighter.Cache` — see `EditorView`.
    public func spans(in line: String) -> [HighlightSpan] {
        if let lexer { return lexer.highlight(line, lexer.initialState).spans }
        return ruleSpans(in: line)
    }

    /// `state` is whatever the previous line's `nextState` was. The
    /// rule-list form ignores it and hands it back unchanged, so a caller
    /// that always goes through this entry point does not need to know
    /// which kind of highlighter it has.
    public func highlight(
        _ line: String, state: AnyHashable
    ) -> (spans: [HighlightSpan], nextState: AnyHashable) {
        if let lexer { return lexer.highlight(line, state) }
        return (ruleSpans(in: line), state)
    }

    private func ruleSpans(in line: String) -> [HighlightSpan] {
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

    /// Per-line spans plus the state each line started in, updated
    /// incrementally as the buffer edits rather than re-lexed whole on every
    /// keystroke — the property a stateful lexer needs and a rule list
    /// already got for free from being stateless.
    ///
    /// Rebuilding is a two-part diff against what is cached:
    ///  - a common *prefix* of unchanged lines needs no work, and fixes the
    ///    state the first changed line starts from (it is whatever was
    ///    already cached there — nothing above it could have changed);
    ///  - re-lexing then stops the moment a line's *recomputed* start state
    ///    and text both match what was cached there before, because from
    ///    that point on every line downstream would recompute to exactly
    ///    what it already has.
    /// The second check only fires when the line count hasn't changed — an
    /// inserted or deleted line shifts every index below it, so comparing
    /// old and new content at the same index would compare the wrong lines.
    /// Missing that convergence in the insert/delete case just means
    /// re-lexing to the end of the file instead of stopping early: slower,
    /// never wrong.
    public struct Cache {
        private var lines: [Substring] = []
        private var startStates: [AnyHashable] = []
        private var lineSpans: [[HighlightSpan]] = []

        public init() {}

        /// Spans for `row`, valid only immediately after `update(lines:with:)`
        /// with the same `row` in range.
        public func spans(atRow row: Int) -> [HighlightSpan] {
            lineSpans.indices.contains(row) ? lineSpans[row] : []
        }

        public mutating func update(lines newLines: [Substring], with highlighter: SyntaxHighlighter) {
            guard highlighter.isStateful else {
                // The rule-list form doesn't need this cache — spans(in:) is
                // already O(that line) and independent of everything else.
                // Clearing rather than leaving stale data avoids a lexer ->
                // rule-list swap on the same EditorView reading old spans.
                self = Cache()
                return
            }

            let sameCount = newLines.count == lines.count
            var prefix = 0
            while prefix < newLines.count, prefix < lines.count,
                  newLines[prefix] == lines[prefix]
            {
                prefix += 1
            }
            if sameCount, prefix == newLines.count { return }

            var state = prefix < startStates.count ? startStates[prefix] : highlighter.initialState
            var nextStartStates = Array(startStates.prefix(prefix))
            var nextSpans = Array(lineSpans.prefix(prefix))

            var i = prefix
            while i < newLines.count {
                if sameCount, i < lines.count, i < startStates.count,
                   lines[i] == newLines[i], startStates[i] == state
                {
                    nextStartStates.append(contentsOf: startStates[i...])
                    nextSpans.append(contentsOf: lineSpans[i...])
                    i = newLines.count
                    break
                }
                nextStartStates.append(state)
                let (spans, next) = highlighter.highlight(String(newLines[i]), state: state)
                nextSpans.append(spans)
                state = next
                i += 1
            }

            lines = newLines
            startStates = nextStartStates
            lineSpans = nextSpans
        }
    }
}
