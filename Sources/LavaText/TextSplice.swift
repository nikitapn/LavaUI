/// The one replacement that turns `old` into `new`: the span between their
/// common prefix and common suffix, in character offsets — what an editor's
/// `replace` takes.
///
/// For putting a whole new text into an editor as an edit rather than as a
/// new buffer: reverting to the saved file, or a tool that rewrote the
/// document. One span is one undo step, and everything outside it — the
/// caret, the scroll, the rows — stays where it was, which a replacement of
/// the whole buffer would not leave alone.
public struct TextSplice: Equatable, Sendable {
    /// Characters of `old` to replace.
    public var range: Range<Int>
    /// What goes there.
    public var replacement: String

    public init(range: Range<Int>, replacement: String) {
        self.range = range
        self.replacement = replacement
    }

    /// Nil when the two are the same text.
    public static func between(_ old: String, _ new: String) -> TextSplice? {
        // Prefix by Character, so a span never starts inside a cluster.
        var a = old.startIndex, b = new.startIndex
        var prefix = 0
        while a < old.endIndex, b < new.endIndex, old[a] == new[b] {
            old.formIndex(after: &a)
            new.formIndex(after: &b)
            prefix += 1
        }
        if a == old.endIndex, b == new.endIndex { return nil }
        // Suffix the same way, from the end, not reaching back into the
        // prefix of either.
        var x = old.endIndex, y = new.endIndex
        var oldCount = prefix
        var cursor = a
        while cursor < old.endIndex { old.formIndex(after: &cursor); oldCount += 1 }
        var suffix = 0
        while x > a, y > b {
            let px = old.index(before: x), py = new.index(before: y)
            guard old[px] == new[py] else { break }
            x = px
            y = py
            suffix += 1
        }
        return TextSplice(range: prefix..<(oldCount - suffix), replacement: String(new[b..<y]))
    }

    /// `old` with the splice applied — for checking one against the other.
    public func applied(to old: String) -> String {
        let lower = old.index(old.startIndex, offsetBy: range.lowerBound)
        let upper = old.index(old.startIndex, offsetBy: range.upperBound)
        return old.replacingCharacters(in: lower..<upper, with: replacement)
    }
}
