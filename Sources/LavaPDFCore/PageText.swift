import Foundation

/// One UTF-16 unit of a page's text and the box it was drawn in, in points
/// from the page's top-left.
public struct PageCharacter: Equatable, Sendable {
    public var unit: UInt16
    public var box: Box
    /// The last character of a word.
    public var endsWord: Bool
    /// A word followed by a space.
    public var spaceAfter: Bool

    public init(unit: UInt16, box: Box, endsWord: Bool = false, spaceAfter: Bool = false) {
        self.unit = unit
        self.box = box
        self.endsWord = endsWord
        self.spaceAfter = spaceAfter
    }
}

/// The text on one page, and the questions a reader asks of it: what is under
/// the pointer, what a drag selected and where to paint it, what to copy, and
/// where a search matched.
///
/// Everything is in character indices — positions in `characters` — because
/// that is the one numbering both halves share: a box belongs to a
/// character, and so does a place in the text. `string` is the text a person
/// would copy, with the spaces and line breaks the PDF never stored.
public struct PageText: Sendable {
    public let characters: [PageCharacter]
    /// The page as text: characters in reading order, a space after a word
    /// that has one, a line break where the next word starts a new line.
    public let string: String
    /// UTF-16 offset in `string` of each character.
    private let offsets: [Int]
    /// For each UTF-16 offset in `string`, the character it came from, or -1
    /// for a separator this inserted.
    private let owners: [Int]

    public init(characters: [PageCharacter]) {
        self.characters = characters
        var units: [UInt16] = []
        var offsets: [Int] = []
        var owners: [Int] = []
        units.reserveCapacity(characters.count + characters.count / 4)
        for (index, character) in characters.enumerated() {
            offsets.append(units.count)
            owners.append(index)
            units.append(character.unit)
            guard character.endsWord, index + 1 < characters.count else { continue }
            let next = characters[index + 1]
            if !Self.sameLine(character.box, next.box) {
                units.append(0x0a)
                owners.append(-1)
            } else if character.spaceAfter || Self.apart(character.box, next.box) {
                units.append(0x20)
                owners.append(-1)
            }
        }
        self.string = String(decoding: units, as: UTF16.self)
        self.offsets = offsets
        self.owners = owners
    }

    public var isEmpty: Bool { characters.isEmpty }

    /// Two boxes are on one line when they overlap vertically by at least half
    /// the shorter one. Half, because superscripts and mixed sizes on one line
    /// overlap partly, while two lines of body text do not overlap at all.
    static func sameLine(_ a: Box, _ b: Box) -> Bool {
        let overlap = min(a.maxY, b.maxY) - max(a.y, b.y)
        return overlap >= min(a.height, b.height) / 2
    }

    /// Two words on one line with no space between them as far as poppler
    /// knows, but a gap a reader would see as one: a running header with the
    /// title on the left and the chapter on the right, or two table cells.
    /// A quarter of the line's height is wider than any kerning and narrower
    /// than any real space.
    static func apart(_ a: Box, _ b: Box) -> Bool {
        b.x - a.maxX > min(a.height, b.height) / 4
    }

    // ─── Under the pointer ───────────────────────────────────────────────

    /// The character a press or a drag at (`x`, `y`) means, or nil on a page
    /// with no text.
    ///
    /// The one containing the point if there is one. Otherwise the nearest on
    /// the line the point is level with — a drag into the margin past the end
    /// of a line means that line's last character, not the nearest character
    /// on some other line that happens to be closer. Otherwise the nearest
    /// anywhere.
    public func index(nearestX x: Double, y: Double) -> Int? {
        guard !characters.isEmpty else { return nil }
        if let hit = characters.firstIndex(where: { $0.box.contains(x: x, y: y) }) {
            return hit
        }
        var best: (index: Int, distance: Double)?
        for (index, character) in characters.enumerated()
        where y >= character.box.y && y < character.box.maxY {
            let d = character.box.distance(x: x, y: y)
            if best == nil || d < best!.distance { best = (index, d) }
        }
        if let best { return best.index }
        var nearest = 0
        var nearestDistance = Double.infinity
        for (index, character) in characters.enumerated() {
            let d = character.box.distance(x: x, y: y)
            if d < nearestDistance {
                nearest = index
                nearestDistance = d
            }
        }
        return nearest
    }

    // ─── A selection ─────────────────────────────────────────────────────

    /// Where to paint `range`: one box per line it touches, each the union of
    /// its characters, so a highlight is a bar rather than a row of glyph-sized
    /// tiles with gaps at every space.
    public func boxes(for range: ClosedRange<Int>) -> [Box] {
        let range = clamped(range)
        guard let range else { return [] }
        var result: [Box] = []
        var line = characters[range.lowerBound].box
        for index in range.dropFirst() {
            let box = characters[index].box
            if Self.sameLine(line, box) {
                line = line.union(box)
            } else {
                result.append(line)
                line = box
            }
        }
        result.append(line)
        return result
    }

    /// What copying `range` puts on the clipboard: the characters and the
    /// separators between them, not the one after the last.
    public func text(in range: ClosedRange<Int>) -> String {
        guard let range = clamped(range) else { return "" }
        let start = offsets[range.lowerBound]
        let end = offsets[range.upperBound] + 1
        let utf16 = string.utf16
        let from = utf16.index(utf16.startIndex, offsetBy: start)
        let to = utf16.index(utf16.startIndex, offsetBy: end)
        return String(string[from..<to])
    }

    /// The word containing `index`, for a double click.
    public func word(containing index: Int) -> ClosedRange<Int>? {
        guard index >= 0, index < characters.count else { return nil }
        var start = index
        while start > 0, !characters[start - 1].endsWord { start -= 1 }
        var end = index
        while end + 1 < characters.count, !characters[end].endsWord { end += 1 }
        return start...end
    }

    // ─── Search ──────────────────────────────────────────────────────────

    /// Every place `query` occurs, as character ranges, in reading order.
    ///
    /// Case- and accent-insensitive, the way a reader's find bar is expected
    /// to be, and across the separators this inserted: "end of" finds a match
    /// that wraps a line, because the line break counts as the space between
    /// them. That costs one rule, below.
    public func find(_ query: String) -> [ClosedRange<Int>] {
        guard !query.isEmpty, !characters.isEmpty else { return [] }
        // A line break in the text stands for a space in the query: searching
        // is for words, and nobody types the line breaks of a page they have
        // not seen yet.
        let haystack = string.replacingOccurrences(of: "\n", with: " ") as NSString
        var matches: [ClosedRange<Int>] = []
        var location = 0
        while location < haystack.length {
            let found = haystack.range(
                of: query,
                options: [.caseInsensitive, .diacriticInsensitive],
                range: NSRange(location: location, length: haystack.length - location)
            )
            guard found.location != NSNotFound, found.length > 0 else { break }
            if let range = characterRange(
                utf16: found.location..<(found.location + found.length)
            ) {
                matches.append(range)
            }
            location = found.location + found.length
        }
        return matches
    }

    /// The characters a span of `string` covers, ignoring inserted separators
    /// at either end. Nil for a span of separators only.
    private func characterRange(utf16 span: Range<Int>) -> ClosedRange<Int>? {
        let owned = span.clamped(to: 0..<owners.count).compactMap {
            owners[$0] >= 0 ? owners[$0] : nil
        }
        guard let first = owned.first, let last = owned.last else { return nil }
        return first...last
    }

    private func clamped(_ range: ClosedRange<Int>) -> ClosedRange<Int>? {
        guard !characters.isEmpty else { return nil }
        let low = max(0, range.lowerBound)
        let high = min(characters.count - 1, range.upperBound)
        return low <= high ? low...high : nil
    }
}
