/// Highlighting worked out somewhere other than the editor's own highlighter —
/// a syntax tree parsed on a worker thread — for a buffer the editor holds.
///
/// It is a *base* layer: where it has spans for a line, they replace the
/// highlighter's; where it has none, the highlighter's stand. Language-server
/// tokens are still laid over whichever it was.
public protocol HighlightSource: AnyObject {
    /// Spans for `lines` (logical lines) of `state`'s buffer. Called on the
    /// main thread while drawing, so it may wait only briefly for work in
    /// flight; nil when it has nothing yet.
    func highlights(for state: TextEditingState, lines: Range<Int>) -> HighlightLayer?

    /// Called from any thread when there is a layer newer than the last one
    /// `highlights` returned. The editor installs it; the last installed wins.
    var highlightsChanged: (@Sendable () -> Void)? { get set }

    /// Whether a layer newer than the last one returned is waiting. Asked on
    /// the main thread before redrawing for `highlightsChanged`, which often
    /// fires for a layer the frame in progress already waited for and drew.
    var hasUndrawnHighlights: Bool { get }
}

/// A source's spans for some lines of the buffer as it was at `revision`.
public struct HighlightLayer: Sendable {
    /// The `TextEditingState.revision` these were worked out for.
    public let revision: UInt64
    /// How many logical lines the buffer had then.
    public let lineCount: Int
    /// Per logical line, for the lines covered.
    public let lines: [Int: Line]

    public struct Line: Sendable, Equatable {
        /// The line as it read, without its newline: what decides whether the
        /// spans still fit it once the buffer has moved on.
        public let text: String
        /// Character columns within the line, sorted and disjoint.
        public let spans: [HighlightSpan]

        public init(text: String, spans: [HighlightSpan]) {
            self.text = text
            self.spans = spans
        }
    }

    public init(revision: UInt64, lineCount: Int, lines: [Int: Line]) {
        self.revision = revision
        self.lineCount = lineCount
        self.lines = lines
    }

    /// The spans for logical line `line` of a buffer at `revision` with
    /// `lineCount` lines, or nil to let the editor's own highlighter answer.
    ///
    /// At the layer's own revision, the line's entry as it is. Behind it —
    /// edits the source has not caught up with — an entry is used only where
    /// its text is still the line's: at the same line number, or moved by the
    /// lines added or removed since (`text` is only read then). A line that
    /// was edited falls back for the frame or two until the source answers.
    public func spans(
        forLine line: Int, revision: UInt64, lineCount: Int, text: () -> Substring
    ) -> [HighlightSpan]? {
        if revision == self.revision { return lines[line]?.spans }
        let current = text()
        if let entry = lines[line], entry.text == current { return entry.spans }
        let moved = line - (lineCount - self.lineCount)
        if moved != line, let entry = lines[moved], entry.text == current { return entry.spans }
        return nil
    }
}
