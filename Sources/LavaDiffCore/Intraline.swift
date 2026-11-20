/// Which characters of a changed line pair actually changed.
///
/// Words, not characters: a character diff of `count` against `amount` finds
/// the shared `o`, `u`, `n`, `t` and highlights the four letters between them,
/// which is correct and unreadable. Splitting into identifier runs, whitespace
/// runs and single punctuation marks first makes the unit of change the unit a
/// reader thinks in.
public enum Intraline {
    /// Changed character ranges on each side, as character offsets into the
    /// two lines. Nil when the lines have too little in common for a
    /// highlight to mean anything — then the whole line is the change.
    public static func ranges(
        old: Substring, new: Substring, minimumShared: Double = 0.3
    ) -> (old: [Range<Int>], new: [Range<Int>])? {
        let oldTokens = tokens(old)
        let newTokens = tokens(new)
        var interner = Interner<Substring>()
        let a = oldTokens.map { interner.id($0.text) }
        let b = newTokens.map { interner.id($0.text) }
        var myers = Myers(a, b, costLimit: 256)
        myers.run()

        var shared = 0
        for (i, token) in oldTokens.enumerated() where !myers.changedA[i] {
            shared += token.range.count
        }
        let shorter = min(old.count, new.count)
        if shorter > 0, Double(shared) < Double(shorter) * minimumShared { return nil }

        return (
            merge(oldTokens, changed: myers.changedA),
            merge(newTokens, changed: myers.changedB)
        )
    }

    struct Token {
        var text: Substring
        var range: Range<Int>
    }

    static func tokens(_ line: Substring) -> [Token] {
        enum Class { case word, space, other }
        func classify(_ c: Character) -> Class {
            if c == " " || c == "\t" { return .space }
            if c.isLetter || c.isNumber || c == "_" { return .word }
            return .other
        }
        var out: [Token] = []
        var start = line.startIndex
        var startOffset = 0
        var offset = 0
        var index = line.startIndex
        var current: Class?
        while index < line.endIndex {
            let kind = classify(line[index])
            // Punctuation is one token a mark, so `)` and `);` share the `)`.
            if let current, current != kind || kind == .other {
                out.append(Token(text: line[start..<index], range: startOffset..<offset))
                start = index
                startOffset = offset
            }
            current = kind
            index = line.index(after: index)
            offset += 1
        }
        if start < line.endIndex {
            out.append(Token(text: line[start..<line.endIndex], range: startOffset..<offset))
        }
        return out
    }

    /// Joins runs of changed tokens into ranges, bridging a gap of whitespace
    /// alone — two changed words with one unchanged space between them read as
    /// one change, and drawn as two they look like a stutter.
    static func merge(_ tokens: [Token], changed: [Bool]) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var pendingGap: Range<Int>?
        for (i, token) in tokens.enumerated() {
            if changed[i] {
                if let last = out.last, let gap = pendingGap, gap.lowerBound == last.upperBound {
                    out[out.count - 1] = last.lowerBound..<token.range.upperBound
                } else if let last = out.last, last.upperBound == token.range.lowerBound {
                    out[out.count - 1] = last.lowerBound..<token.range.upperBound
                } else {
                    out.append(token.range)
                }
                pendingGap = nil
            } else if token.text.allSatisfy({ $0 == " " || $0 == "\t" }),
                      let last = out.last, last.upperBound == token.range.lowerBound {
                pendingGap = token.range
            } else {
                pendingGap = nil
            }
        }
        return out
    }
}
