public enum PositionEncoding: String, Codable, Sendable {
    case utf8 = "utf-8"
    case utf16 = "utf-16"

    func length(of text: Substring) -> Int {
        switch self {
        case .utf8: text.utf8.count
        case .utf16: text.utf16.count
        }
    }
}

public struct LSPPosition: Codable, Sendable, Hashable, Comparable {
    public var line: Int
    public var character: Int

    public init(line: Int, character: Int) {
        self.line = line
        self.character = character
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.line, lhs.character) < (rhs.line, rhs.character)
    }
}

public struct LSPRange: Codable, Sendable, Equatable {
    public var start: LSPPosition
    public var end: LSPPosition

    public init(start: LSPPosition, end: LSPPosition) {
        self.start = start
        self.end = end
    }
}

/// One entry per line. Conversion walks only the selected line's graphemes.
public struct DocumentPositions: Sendable {
    private struct Line: Sendable {
        var start: String.Index
        var end: String.Index
        var offset: Int
        /// Characters on the line when it is all ASCII — then a Character is
        /// a byte and a UTF-16 unit, and a column is an offset — else nil.
        var asciiLength: Int?
    }

    public let text: String
    public let encoding: PositionEncoding
    public let characterCount: Int
    private let lines: [Line]

    public var lineCount: Int { lines.count }

    public init(_ text: String, encoding: PositionEncoding = .utf16) {
        self.text = text
        self.encoding = encoding
        // Found on bytes, and counted in Characters only where a line is not
        // ASCII: this runs on every keystroke a server's highlighting is
        // shifted through, and a grapheme walk of the whole document was
        // milliseconds of it. No grapheme spans a `\n`, so lines count apart,
        // and the `\r` of a CRLF is the newline's Character, not the line's.
        var breaks: [(end: Int, ascii: Bool)] = []
        var copy = text
        let total = copy.withUTF8 { bytes -> Int in
            var ascii = true
            for i in 0..<bytes.count {
                let byte = bytes[i]
                if byte == 10 {
                    breaks.append((i, ascii))
                    ascii = true
                } else if byte >= 0x80 {
                    ascii = false
                }
            }
            breaks.append((bytes.count, ascii))
            return bytes.count
        }
        let utf8 = text.utf8
        var lines: [Line] = []
        lines.reserveCapacity(breaks.count)
        var startByte = 0
        var offset = 0
        for (number, line) in breaks.enumerated() {
            let last = number == breaks.count - 1
            var endByte = line.end
            if !last, endByte > startByte,
               utf8[utf8.index(utf8.startIndex, offsetBy: endByte - 1)] == 13 {
                endByte -= 1
            }
            let start = utf8.index(utf8.startIndex, offsetBy: startByte)
            let end = utf8.index(utf8.startIndex, offsetBy: endByte)
            lines.append(Line(start: start, end: end, offset: offset,
                              asciiLength: line.ascii ? endByte - startByte : nil))
            offset += line.ascii ? endByte - startByte : text[start..<end].count
            if !last { offset += 1 }
            startByte = min(line.end + 1, total)
        }
        self.lines = lines
        characterCount = offset
    }

    public func position(atCharacterOffset offset: Int) -> LSPPosition? {
        guard (0...characterCount).contains(offset) else { return nil }
        var low = 0
        var high = lines.count
        while low + 1 < high {
            let mid = (low + high) / 2
            if lines[mid].offset <= offset {
                low = mid
            } else {
                high = mid
            }
        }
        let line = lines[low]
        if line.asciiLength != nil {
            return LSPPosition(line: low, character: offset - line.offset)
        }
        let index = text.index(line.start, offsetBy: offset - line.offset)
        return LSPPosition(line: low, character: encoding.length(of: text[line.start..<index]))
    }

    /// Positions inside a grapheme round down by default; overlong columns clamp to end of line.
    public func characterOffset(at position: LSPPosition, roundingUp: Bool = false) -> Int? {
        guard lines.indices.contains(position.line), position.character >= 0 else { return nil }
        let line = lines[position.line]
        // Per token, per keystroke: highlighting converts every one.
        if let length = line.asciiLength {
            return line.offset + min(position.character, length)
        }
        var index = line.start
        var offset = line.offset
        var units = 0
        while index < line.end && units < position.character {
            let next = text.index(after: index)
            units += encoding.length(of: text[index..<next])
            if units > position.character && !roundingUp { break }
            offset += 1
            index = next
        }
        return offset
    }

    /// Expands partial graphemes so a server range can be drawn by the editor.
    public func characterRange(for range: LSPRange) -> Range<Int>? {
        guard range.start <= range.end,
              let start = characterOffset(at: range.start),
              let end = characterOffset(at: range.end, roundingUp: range.start != range.end)
        else { return nil }
        return start..<end
    }
}

public struct IncrementalChange: Codable, Sendable, Equatable {
    public var range: LSPRange
    public var text: String

    public init(range: LSPRange, text: String) {
        self.range = range
        self.text = text
    }

    /// Keeps the common prefix and suffix intact, including the exact Unicode spelling.
    ///
    /// The prefix and suffix are found on bytes and then backed off to a
    /// position that is a `Character` boundary in both texts — the answer a
    /// walk by `Character` gives, without grapheme-breaking the whole document
    /// on every keystroke (that walk was ten milliseconds of a 100 KB file).
    public static func between(_ old: String, and new: String,
                               encoding: PositionEncoding = .utf16) -> Self? {
        var oldBytes = old, newBytes = new
        let common = oldBytes.withUTF8 { a in
            newBytes.withUTF8 { b -> (prefix: Int, suffix: Int) in
                let limit = min(a.count, b.count)
                var prefix = 0
                while prefix < limit && a[prefix] == b[prefix] { prefix += 1 }
                var suffix = 0
                while suffix < limit - prefix && a[a.count - 1 - suffix] == b[b.count - 1 - suffix] {
                    suffix += 1
                }
                return (prefix, suffix)
            }
        }
        if common.prefix == old.utf8.count && common.prefix == new.utf8.count { return nil }

        func aligned(_ index: String.Index, in text: String) -> Bool {
            index.samePosition(in: text) != nil
        }
        var oldStart = old.utf8.index(old.startIndex, offsetBy: common.prefix)
        var newStart = new.utf8.index(new.startIndex, offsetBy: common.prefix)
        while !(aligned(oldStart, in: old) && aligned(newStart, in: new)) {
            oldStart = old.utf8.index(before: oldStart)
            newStart = new.utf8.index(before: newStart)
        }
        // The suffix was measured short of the byte prefix, and backing off
        // only moved the start earlier, so the ends cannot cross the starts.
        var oldEnd = old.utf8.index(old.endIndex, offsetBy: -common.suffix)
        var newEnd = new.utf8.index(new.endIndex, offsetBy: -common.suffix)
        while !(aligned(oldEnd, in: old) && aligned(newEnd, in: new)) {
            oldEnd = old.utf8.index(after: oldEnd)
            newEnd = new.utf8.index(after: newEnd)
        }
        // Count line breaks only up to the edit. The unchanged suffix needs no line table.
        let bytes = old.utf8
        var line = 0
        var lineStart = old.startIndex
        func advance(from start: String.Index, to end: String.Index) -> LSPPosition {
            for index in bytes[start..<end].indices where bytes[index] == 10 {
                line += 1
                lineStart = bytes.index(after: index)
            }
            return LSPPosition(line: line, character: encoding.length(of: old[lineStart..<end]))
        }
        let start = advance(from: old.startIndex, to: oldStart)
        let end = advance(from: oldStart, to: oldEnd)
        return Self(range: LSPRange(start: start, end: end), text: String(new[newStart..<newEnd]))
    }
}
