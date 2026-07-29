#if canImport(CxxCanvas)
import CxxCanvas
import Foundation

/// A shaped line plus the two mappings text editing needs.
///
/// Both directions go through HarfBuzz cluster values (byte offsets into the
/// source string), because shaping is not one-glyph-per-character: a ligature
/// is several characters and one glyph, a combining mark is one glyph with no
/// advance of its own. Any attempt to guess caret positions from character
/// counts falls apart on the first "ffi" or accented vowel.
///
/// Because this is built from the same `Font::shape` call that measurement
/// uses, hit-testing and drawing agree by construction — the invariant
/// `font.hpp` exists to protect, extended to the caret.
public struct ShapedRun {
    public let text: String
    public let glyphs: [canvas.PositionedGlyph]

    /// Grapheme boundaries as UTF-8 offsets. HarfBuzz clusters are aligned to
    /// codepoints, not graphemes, so a cluster can land *inside* a character
    /// (an emoji ZWJ sequence, say). Carets must never sit there, so every
    /// cluster is snapped through this table.
    private let boundaries: [(utf8: Int, index: String.Index)]

    public init(text: String, glyphs: [canvas.PositionedGlyph]) {
        self.text = text
        self.glyphs = glyphs

        var table: [(utf8: Int, index: String.Index)] = []
        table.reserveCapacity(text.count + 1)
        var i = text.startIndex
        while true {
            table.append((text.utf8.distance(from: text.utf8.startIndex,
                                             to: i.samePosition(in: text.utf8)!), i))
            if i == text.endIndex { break }
            i = text.index(after: i)
        }
        boundaries = table
    }

    /// Total advance — where the caret sits at end of line.
    public var width: Float {
        glyphs.reduce(0) { $0 + $1.advance }
    }

    // MARK: cursor → pixels

    /// X of the caret for `index`, relative to the run origin.
    public func caretX(for index: String.Index) -> Float {
        let target = utf8Offset(of: index)

        // Sum advances of every glyph belonging to an earlier cluster. Summing
        // rather than reading the glyph's own `x` keeps the caret on the pen
        // path, so GPOS offsets (which shift ink, not the pen) don't drag it.
        var x: Float = 0
        for glyph in glyphs {
            if Int(glyph.cluster) >= target { break }
            x += glyph.advance
        }
        return x
    }

    // MARK: pixels → cursor

    /// Nearest cursor position to `x`, snapped to a grapheme boundary.
    public func index(atX x: Float) -> String.Index {
        guard !glyphs.isEmpty else { return text.startIndex }
        if x <= 0 { return text.startIndex }

        var penX: Float = 0
        for glyph in glyphs {
            let mid = penX + glyph.advance / 2
            if x < mid {
                return snap(utf8: Int(glyph.cluster))
            }
            // Past this glyph's midpoint: the caret belongs after it, which is
            // the *next* cluster, not this one.
            penX += glyph.advance
        }
        return text.endIndex
    }

    /// One advance per Character, which is what `SoftWrap` consumes.
    ///
    /// Glyphs are not characters: a ligature is one glyph spanning several,
    /// and a combining mark is a glyph with no advance of its own. Summing by
    /// cluster is what keeps the two aligned.
    public var characterAdvances: [Float] {
        guard !text.isEmpty else { return [] }
        var result = [Float](repeating: 0, count: text.count)
        // Character index for each UTF-8 offset where a character starts.
        var charOfUTF8: [Int: Int] = [:]
        for (n, entry) in boundaries.enumerated() where n < text.count {
            charOfUTF8[entry.utf8] = n
        }
        var current = 0
        for glyph in glyphs {
            if let mapped = charOfUTF8[Int(glyph.cluster)] { current = mapped }
            if current < result.count { result[current] += glyph.advance }
        }
        return result
    }

    // MARK: Helpers

    private func utf8Offset(of index: String.Index) -> Int {
        guard let u = index.samePosition(in: text.utf8) else { return 0 }
        return text.utf8.distance(from: text.utf8.startIndex, to: u)
    }

    /// Rounds a byte offset down to the nearest grapheme boundary.
    private func snap(utf8 offset: Int) -> String.Index {
        var candidate = text.startIndex
        for entry in boundaries {
            if entry.utf8 > offset { break }
            candidate = entry.index
        }
        return candidate
    }
}

extension UIFont {
    /// Shapes `line` (cached) and wraps it with the cursor mappings.
    public func shapedRun(_ line: String) -> ShapedRun {
        ShapedRun(text: line, glyphs: shape(line))
    }
}

#endif
