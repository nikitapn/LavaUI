/// One row of a two-column diff.
public struct DiffRow: Equatable, Sendable {
    /// What the row shows.
    public enum Kind: Equatable, Sendable {
        /// The same line on both sides.
        case context
        /// A line on each side, the old one replaced by the new.
        case changed
        /// A line only on the old side; the new side is blank.
        case removed
        /// A line only on the new side; the old side is blank.
        case added
        /// Unchanged lines left out: `old` and `new` are where they start, and
        /// `count` how many there are.
        case folded(count: Int)
    }

    public var kind: Kind
    /// Line index on the old side, or nil where that side is blank.
    public var old: Int?
    /// Line index on the new side, or nil where that side is blank.
    public var new: Int?
    /// Which hunk this row belongs to, for rows inside one.
    public var hunk: Int?

    public init(kind: Kind, old: Int?, new: Int?, hunk: Int? = nil) {
        self.kind = kind
        self.old = old
        self.new = new
        self.hunk = hunk
    }
}

/// Lays hunks out as rows: both sides scroll together, so a line and its
/// replacement are always on the same row, and a side with fewer lines in a
/// hunk is padded with blank ones.
public enum SideBySide {
    /// Rows for the whole of both files, folding runs of unchanged lines down
    /// to `context` lines each side of a change, when that hides at least
    /// `minimumFold` of them. `context` nil shows every line.
    ///
    /// Inside a hunk the lines pair in order — the third removed line beside
    /// the third added one — which is what `git diff --word-diff` and every
    /// side-by-side tool that does not try to be clever does. Pairing by
    /// similarity instead is better where a hunk rewrote a block and kept a few
    /// lines, and is the obvious next step.
    public static func rows(
        hunks: [DiffHunk], oldCount: Int, newCount: Int,
        context: Int? = 3, minimumFold: Int = 4
    ) -> [DiffRow] {
        var rows: [DiffRow] = []
        var oldLine = 0, newLine = 0

        func equalRun(to oldEnd: Int, first: Bool, last: Bool) {
            let length = oldEnd - oldLine
            guard length > 0 else { return }
            let before = first ? 0 : (context ?? length)
            let after = last ? 0 : (context ?? length)
            // Folding three lines into a row that says "3 lines" saves nothing.
            if context != nil, length - before - after >= minimumFold {
                for i in 0..<before {
                    rows.append(DiffRow(kind: .context, old: oldLine + i, new: newLine + i))
                }
                let hidden = length - before - after
                rows.append(DiffRow(
                    kind: .folded(count: hidden), old: oldLine + before, new: newLine + before
                ))
                for i in (length - after)..<length {
                    rows.append(DiffRow(kind: .context, old: oldLine + i, new: newLine + i))
                }
            } else {
                for i in 0..<length {
                    rows.append(DiffRow(kind: .context, old: oldLine + i, new: newLine + i))
                }
            }
            oldLine += length
            newLine += length
        }

        for (index, hunk) in hunks.enumerated() {
            // `first`: the run before the first hunk has nothing above it to
            // keep context for, so it can fold right down to the change.
            equalRun(to: hunk.old.lowerBound, first: index == 0, last: false)
            let pairs = min(hunk.old.count, hunk.new.count)
            for i in 0..<pairs {
                rows.append(DiffRow(
                    kind: .changed, old: hunk.old.lowerBound + i, new: hunk.new.lowerBound + i,
                    hunk: index
                ))
            }
            for i in pairs..<hunk.old.count {
                rows.append(DiffRow(kind: .removed, old: hunk.old.lowerBound + i, new: nil, hunk: index))
            }
            for i in pairs..<hunk.new.count {
                rows.append(DiffRow(kind: .added, old: nil, new: hunk.new.lowerBound + i, hunk: index))
            }
            oldLine = hunk.old.upperBound
            newLine = hunk.new.upperBound
        }
        equalRun(to: oldCount, first: hunks.isEmpty, last: true)
        return rows
    }

    /// The rows a folded row stands for, to put in its place when it is opened.
    public static func unfold(_ row: DiffRow) -> [DiffRow] {
        guard case .folded(let count) = row.kind, let old = row.old, let new = row.new else {
            return [row]
        }
        return (0..<count).map { DiffRow(kind: .context, old: old + $0, new: new + $0) }
    }
}

/// A finished comparison of two texts: lines, hunks, rows, and the word-level
/// highlights inside changed rows, computed once.
public struct TextDiff: Sendable {
    public let old: TextLines
    public let new: TextLines
    public let hunks: [DiffHunk]
    /// Lines added and removed, as `git diff --stat` counts them.
    public let added: Int
    public let removed: Int

    /// Diffs `old` against `new`.
    public init(old: String, new: String, options: DiffOptions = DiffOptions()) {
        self.old = TextLines(old)
        self.new = TextLines(new)
        hunks = LineDiff.hunks(old: self.old.lines, new: self.new.lines, options: options)
        added = hunks.reduce(0) { $0 + $1.new.count }
        removed = hunks.reduce(0) { $0 + $1.old.count }
    }

    /// Whether the texts differ in anything but the final newline.
    public var isEmpty: Bool { hunks.isEmpty }

    /// Only the final newline differs: no hunk, but not the same file either.
    public var newlineAtEndChanged: Bool { old.endsWithNewline != new.endsWithNewline }

    /// Side-by-side rows. See `SideBySide.rows`.
    public func rows(context: Int? = 3) -> [DiffRow] {
        SideBySide.rows(
            hunks: hunks, oldCount: old.lines.count, newCount: new.lines.count, context: context
        )
    }

    /// Word-level change ranges for a `.changed` row, or nil when the pair is
    /// too different for them to help.
    public func intraline(_ row: DiffRow) -> (old: [Range<Int>], new: [Range<Int>])? {
        guard row.kind == .changed, let o = row.old, let n = row.new else { return nil }
        return Intraline.ranges(old: old.lines[o], new: new.lines[n])
    }
}
