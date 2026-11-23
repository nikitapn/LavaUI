import Foundation

/// One region where the two sides differ, as line ranges.
///
/// Between consecutive hunks, and before the first and after the last, the two
/// sides are equal line for line. A pure insertion has an empty `old` range
/// sitting at the line it was inserted before; a pure deletion, an empty `new`.
public struct DiffHunk: Equatable, Sendable {
    /// Lines of the old side this hunk replaces.
    public var old: Range<Int>
    /// Lines of the new side that replace them.
    public var new: Range<Int>

    /// Creates a hunk.
    public init(old: Range<Int>, new: Range<Int>) {
        self.old = old
        self.new = new
    }

    /// Lines only on the new side.
    public var isInsertion: Bool { old.isEmpty && !new.isEmpty }
    /// Lines only on the old side.
    public var isDeletion: Bool { new.isEmpty && !old.isEmpty }
}

/// Splits text into lines the way `git diff` counts them.
///
/// A final newline ends the last line rather than starting an empty one, so
/// `"a\n"` is one line and `"a"` is the same one line — the difference between
/// those two is `TextLines.endsWithNewline`, not a line. A `\r\n` is a line
/// break with the `\r` kept on the line, so a file whose endings changed shows
/// every line as changed, which is what it is.
public struct TextLines: Sendable {
    /// The lines, without their `\n`.
    public let lines: [Substring]
    /// Whether the text ended with a newline.
    public let endsWithNewline: Bool

    /// Splits `text` at each `\n` byte — the same breaks the editor's rows
    /// have. Not at the `Character` `"\n"`: that is a grapheme walk over the
    /// whole document on every keystroke the gutter diffs, and `"\r\n"` is
    /// one grapheme, so a CRLF file came out as a single line. A CRLF line
    /// keeps its `\r`, as it does in git.
    public init(_ text: String) {
        var parts: [Substring] = []
        let bytes = text.utf8
        var start = bytes.startIndex
        var index = start
        while index < bytes.endIndex {
            if bytes[index] == 0x0A {
                parts.append(text[start..<index])
                start = bytes.index(after: index)
            }
            index = bytes.index(after: index)
        }
        endsWithNewline = start == bytes.endIndex && !text.isEmpty
        if !endsWithNewline && !text.isEmpty { parts.append(text[start..<bytes.endIndex]) }
        lines = parts
    }
}

/// What a line diff is allowed to ignore.
public struct DiffOptions: Equatable, Sendable {
    /// Lines that differ only in trailing spaces, tabs or a `\r` are equal.
    public var ignoresTrailingWhitespace: Bool
    /// Edits past which one region is reported as wholly different instead of
    /// searched further. See `Myers.costLimit`.
    public var costLimit: Int

    /// Creates options. The defaults compare exactly.
    public init(ignoresTrailingWhitespace: Bool = false, costLimit: Int = 4096) {
        self.ignoresTrailingWhitespace = ignoresTrailingWhitespace
        self.costLimit = costLimit
    }
}

/// Line diff: Myers for the matching, then each change slid to where a person
/// would have put it.
public enum LineDiff {
    /// The hunks that turn `old` into `new`, in order.
    public static func hunks<S: StringProtocol & Hashable>(
        old: [S], new: [S], options: DiffOptions = DiffOptions()
    ) -> [DiffHunk] {
        var interner = Interner<LineBytes>()
        let a = old.map { interner.id(key($0, options)) }
        let b = new.map { interner.id(key($0, options)) }
        return hunks(oldIDs: a, newIDs: b, old: old, new: new, options: options)
    }

    /// The hunks that turn `base` into `new`, with `base` hashed once rather
    /// than on every call — the gutter diffs one commit's copy against every
    /// keystroke. The same answer as `hunks(old:new:options:)`.
    public static func hunks(from base: DiffBaseline, to new: [Substring]) -> [DiffHunk] {
        var interner = Interner<LineBytes>(base: base.table)
        let b = new.map { interner.id(key($0, base.options)) }
        return hunks(oldIDs: base.ids, newIDs: b, old: base.lines, new: new, options: base.options)
    }

    private static func hunks<S: StringProtocol>(
        oldIDs a: [Int], newIDs b: [Int], old: [S], new: [S], options: DiffOptions
    ) -> [DiffHunk] {
        var myers = Myers(a, b, costLimit: options.costLimit)
        myers.run()
        var hunks = collect(changedA: myers.changedA, changedB: myers.changedB)
        Slider.slide(&hunks, oldIDs: a, newIDs: b, old: old, new: new)
        return hunks
    }

    /// What a line is compared by. Bytes, not `Substring`'s own hashing,
    /// which normalises to NFC first and was most of a per-keystroke gutter
    /// diff: lines that differ only in how an accent is encoded differ, as
    /// they do in git.
    static func key<S: StringProtocol>(_ line: S, _ options: DiffOptions) -> LineBytes {
        let sub = Substring(line)
        guard options.ignoresTrailingWhitespace else { return LineBytes(sub) }
        var end = sub.endIndex
        while end > sub.startIndex {
            let before = sub.index(before: end)
            let c = sub[before]
            guard c == " " || c == "\t" || c == "\r" else { break }
            end = before
        }
        return LineBytes(sub[sub.startIndex..<end])
    }

    /// Turns per-line change flags into hunks. The unchanged lines of the two
    /// sides pair up in order, so walking both at once finds every region where
    /// either side has a changed line.
    static func collect(changedA: [Bool], changedB: [Bool]) -> [DiffHunk] {
        var hunks: [DiffHunk] = []
        var i = 0, j = 0
        let n = changedA.count, m = changedB.count
        while i < n || j < m {
            if i < n, j < m, !changedA[i], !changedB[j] {
                i += 1; j += 1
                continue
            }
            let i0 = i, j0 = j
            while i < n, changedA[i] { i += 1 }
            while j < m, changedB[j] { j += 1 }
            // A side that ran out has nothing left to pair, so whatever the
            // other side still has is part of this hunk.
            if i == n { j = m }
            if j == m { i = n }
            hunks.append(DiffHunk(old: i0..<i, new: j0..<j))
        }
        return hunks
    }
}

/// Moves pure insertions and deletions to the boundary a reader expects.
///
/// Where a block of added lines repeats the line just above or below it, the
/// diff is equally correct shifted by one, and Myers picks a position by the
/// order it happened to search in. Adding a function between two others is
/// the classic case: it can come out as `}`, blank, `func b() {` added — the
/// closing brace of the function above, the new header, and the new body's
/// brace left as context. Every such position is tried and scored the way
/// VS Code and git's indent heuristic do: a boundary is better where the lines
/// on either side of it are shallow, and better again next to a blank line.
enum Slider {
    static func slide<S: StringProtocol>(
        _ hunks: inout [DiffHunk], oldIDs: [Int], newIDs: [Int], old: [S], new: [S]
    ) {
        for index in hunks.indices {
            let hunk = hunks[index]
            // A hunk with both sides changed is a replacement, and moving one
            // side alone would split it in two.
            guard hunk.old.isEmpty != hunk.new.isEmpty else { continue }
            let insertion = hunk.old.isEmpty
            let ids = insertion ? newIDs : oldIDs
            let lines = insertion ? new : old
            let block = insertion ? hunk.new : hunk.old
            let length = block.count

            // How far it can go without touching a neighbour: the equal run
            // above must keep a line if there is a hunk above it, and the same
            // below. Equal runs are the same length on both sides.
            let floor = index > 0
                ? (insertion ? hunks[index - 1].new.upperBound : hunks[index - 1].old.upperBound) + 1
                : 0
            let ceiling = index + 1 < hunks.count
                ? (insertion ? hunks[index + 1].new.lowerBound : hunks[index + 1].old.lowerBound) - 1
                : ids.count

            var top = block.lowerBound
            while top - 1 >= floor, ids[top - 1] == ids[top - 1 + length] { top -= 1 }
            var bottom = block.lowerBound
            while bottom + length < ceiling, ids[bottom] == ids[bottom + length] { bottom += 1 }
            guard top < bottom else { continue }

            var best = bottom
            var bestScore = Int.min
            // From the bottom up, so a tie goes to the lowest position — which
            // is where git puts it, and where "added a block" reads as added
            // *after* the line it follows.
            for start in stride(from: bottom, through: top, by: -1) {
                let score = boundaryScore(lines, at: start) + boundaryScore(lines, at: start + length)
                if score > bestScore {
                    bestScore = score
                    best = start
                }
            }
            let shift = best - block.lowerBound
            guard shift != 0 else { continue }
            hunks[index] = DiffHunk(
                old: (hunk.old.lowerBound + shift)..<(hunk.old.upperBound + shift),
                new: (hunk.new.lowerBound + shift)..<(hunk.new.upperBound + shift)
            )
        }
    }

    /// How good a place the gap before line `index` is to start or end a change.
    static func boundaryScore<S: StringProtocol>(_ lines: [S], at index: Int) -> Int {
        let above = index > 0 ? lines[index - 1] : nil
        let below = index < lines.count ? lines[index] : nil
        var score = -(indent(above) + indent(below))
        if isBlank(above) || isBlank(below) { score += 50 }
        // The ends of the file are natural boundaries too.
        if above == nil || below == nil { score += 50 }
        return score
    }

    static func indent<S: StringProtocol>(_ line: S?) -> Int {
        guard let line else { return 0 }
        var width = 0
        for c in line {
            if c == " " { width += 1 } else if c == "\t" { width += 4 } else { return width }
        }
        // A line of nothing but indentation says nothing about depth.
        return 0
    }

    static func isBlank<S: StringProtocol>(_ line: S?) -> Bool {
        guard let line else { return false }
        return line.allSatisfy { $0 == " " || $0 == "\t" || $0 == "\r" }
    }
}

/// A line compared and hashed by its UTF-8 bytes.
struct LineBytes: Hashable {
    let text: Substring

    init(_ text: Substring) { self.text = text }

    static func == (a: Self, b: Self) -> Bool {
        var a = a.text, b = b.text
        return a.withUTF8 { x in
            b.withUTF8 { y in
                x.count == y.count && (x.isEmpty || memcmp(x.baseAddress!, y.baseAddress!, x.count) == 0)
            }
        }
    }

    func hash(into hasher: inout Hasher) {
        var text = text
        text.withUTF8 { hasher.combine(bytes: UnsafeRawBufferPointer($0)) }
    }
}

/// One side of a line diff, hashed once, for diffing many versions of the
/// other side against it: HEAD's copy of a file, which the gutter compares
/// with the buffer on every keystroke. Build it off the main thread — it is
/// the whole file's worth of hashing that `LineDiff.hunks(from:to:)` then
/// does not repeat.
public struct DiffBaseline: Sendable {
    /// The lines, as given.
    public let lines: [Substring]
    /// What the comparison ignores; fixed for the baseline's life, since the
    /// numbering depends on it.
    public let options: DiffOptions
    let ids: [Int]
    let table: [LineBytes: Int]

    /// Hashes `lines` under `options`.
    public init(_ lines: [Substring], options: DiffOptions = DiffOptions()) {
        var interner = Interner<LineBytes>()
        self.lines = lines
        self.options = options
        ids = lines.map { interner.id(LineDiff.key($0, options)) }
        table = interner.table
    }
}
