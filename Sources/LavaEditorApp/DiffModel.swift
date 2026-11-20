import Foundation
import LavaDiffCore
import LavaText
import LavaUI
import Observation

/// One open comparison: the two texts, what differs, and what the view needs
/// to draw it — computed once when the comparison opens.
///
/// A class, so the per-line caches can fill in while rows are painted without
/// that being a change anything observes; `rows` is the one thing the view
/// rebuilds on, when a fold is opened or closed.
@Observable
final class DiffModel {
    /// What the old side is: "HEAD", a path.
    let oldTitle: String
    /// What the new side is: "Working tree", a path.
    let newTitle: String
    /// The document the new side came from, when it is one — what `Done` goes
    /// back to.
    let documentID: Int?

    @ObservationIgnored let diff: TextDiff
    /// The lines as drawn: tabs expanded, since a tab shaped on its own has no
    /// width the two columns would agree on.
    @ObservationIgnored let oldLines: [String]
    @ObservationIgnored let newLines: [String]
    @ObservationIgnored let highlighter: SyntaxHighlighter

    /// Every unchanged run folded down to `context` lines, or all of them.
    var showsWholeFile = false { didSet { rebuildRows() } }
    private(set) var rows: [DiffRow] = []
    /// The hunk last navigated to, for Next / Previous.
    var currentHunk: Int?

    @ObservationIgnored private var oldSpans: [Int: [HighlightSpan]] = [:]
    @ObservationIgnored private var newSpans: [Int: [HighlightSpan]] = [:]
    @ObservationIgnored private var intraline: [Int: (old: [Range<Int>], new: [Range<Int>])?] = [:]

    static let context = 3

    init(
        old: String, new: String, oldTitle: String, newTitle: String,
        rules: [HighlightRule], documentID: Int?
    ) {
        self.oldTitle = oldTitle
        self.newTitle = newTitle
        self.documentID = documentID
        diff = TextDiff(old: old, new: new)
        oldLines = diff.old.lines.map(Self.display)
        newLines = diff.new.lines.map(Self.display)
        highlighter = SyntaxHighlighter(rules: rules)
        rebuildRows()
    }

    private func rebuildRows() {
        rows = diff.rows(context: showsWholeFile ? nil : Self.context)
    }

    /// Opens the fold at `index` in place.
    func unfold(_ index: Int) {
        guard rows.indices.contains(index) else { return }
        rows.replaceSubrange(index...index, with: SideBySide.unfold(rows[index]))
    }

    static func display(_ line: Substring) -> String {
        guard line.contains("\t") else { return String(line) }
        var out = ""
        var column = 0
        for c in line {
            if c == "\t" {
                let width = 4 - column % 4
                out.append(String(repeating: " ", count: width))
                column += width
            } else {
                out.append(c)
                column += 1
            }
        }
        return out
    }

    // MARK: - Per line, on demand

    /// Syntax spans for a line, highlighted the first time it is drawn. A
    /// file is mostly folded away, and the rest scrolls into view a screen at
    /// a time.
    func spans(old index: Int) -> [HighlightSpan] {
        if let cached = oldSpans[index] { return cached }
        let spans = highlighter.isEmpty ? [] : highlighter.spans(in: oldLines[index])
        oldSpans[index] = spans
        return spans
    }

    func spans(new index: Int) -> [HighlightSpan] {
        if let cached = newSpans[index] { return cached }
        let spans = highlighter.isEmpty ? [] : highlighter.spans(in: newLines[index])
        newSpans[index] = spans
        return spans
    }

    /// The word-level changes inside a changed row, keyed by its old line.
    /// Computed on the drawn lines, so the ranges are columns as drawn.
    func changes(_ row: DiffRow) -> (old: [Range<Int>], new: [Range<Int>])? {
        guard row.kind == .changed, let o = row.old, let n = row.new else { return nil }
        if let cached = intraline[o] { return cached }
        let ranges = Intraline.ranges(old: Substring(oldLines[o]), new: Substring(newLines[n]))
        intraline[o] = ranges
        return ranges
    }

    // MARK: - Navigation

    /// Row index of the first row of each hunk, in order.
    var hunkRows: [Int] {
        var out: [Int] = []
        var last: Int?
        for (index, row) in rows.enumerated() {
            if let hunk = row.hunk, hunk != last {
                out.append(index)
                last = hunk
            }
        }
        return out
    }

    /// The row of the next (or previous) hunk after the current one, wrapping
    /// round, and makes it current.
    func step(forward: Bool) -> Int? {
        let starts = hunkRows
        guard !starts.isEmpty else { return nil }
        let count = starts.count
        let next: Int
        if let current = currentHunk {
            next = ((forward ? current + 1 : current - 1) % count + count) % count
        } else {
            next = forward ? 0 : count - 1
        }
        currentHunk = next
        return starts[next]
    }

    /// The widest line number on either side, for the gutter.
    var lineNumberDigits: Int {
        String(max(oldLines.count, newLines.count, 1)).count
    }
}
