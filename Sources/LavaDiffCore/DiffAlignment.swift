/// What two editors side by side need to show a `TextDiff`: which lines each
/// marks, the blank rows that keep a line beside its counterpart, and the
/// changed words as character offsets into each whole text.
///
/// Inside a hunk the lines pair top-down, as `SideBySide.rows` pairs them, so
/// the side with fewer lines gets the difference as blank rows *below* its
/// own — above the line that follows the hunk.
public struct DiffAlignment: Sendable {
    public struct Side: Sendable, Equatable {
        /// Lines this side changed, one range per hunk; empty where the hunk
        /// has none on this side (a pure insertion, seen from the old side).
        public var changed: [Range<Int>] = []
        /// `(line, rows)`: blank rows above `line`. `line` may be the line
        /// count — below the last line.
        public var gaps: [Gap] = []
        /// Changed words, as character offsets into the whole text, sorted.
        public var words: [Range<Int>] = []
    }

    public struct Gap: Sendable, Equatable {
        public var line: Int
        public var rows: Int
    }

    public var old = Side()
    public var new = Side()

    public init(_ diff: TextDiff) {
        let oldStarts = Self.lineStarts(diff.old)
        let newStarts = Self.lineStarts(diff.new)
        for hunk in diff.hunks {
            old.changed.append(hunk.old)
            new.changed.append(hunk.new)
            let difference = hunk.new.count - hunk.old.count
            if difference > 0 {
                old.gaps.append(Gap(line: hunk.old.upperBound, rows: difference))
            } else if difference < 0 {
                new.gaps.append(Gap(line: hunk.new.upperBound, rows: -difference))
            }
            for pair in 0..<min(hunk.old.count, hunk.new.count) {
                let o = hunk.old.lowerBound + pair, n = hunk.new.lowerBound + pair
                guard let ranges = Intraline.ranges(old: diff.old.lines[o], new: diff.new.lines[n]) else {
                    continue
                }
                old.words += ranges.old.map { $0.shifted(by: oldStarts[o]) }
                new.words += ranges.new.map { $0.shifted(by: newStarts[n]) }
            }
        }
    }

    /// Character offset of each line's start, counting the `\n`s between.
    public static func lineStarts(_ text: TextLines) -> [Int] {
        var starts: [Int] = []
        starts.reserveCapacity(text.lines.count)
        var offset = 0
        for line in text.lines {
            starts.append(offset)
            offset += line.count + 1
        }
        return starts
    }
}

private extension Range where Bound == Int {
    func shifted(by delta: Int) -> Range<Int> { (lowerBound + delta)..<(upperBound + delta) }
}
