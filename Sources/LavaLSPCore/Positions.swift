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
    }

    public let text: String
    public let encoding: PositionEncoding
    public let characterCount: Int
    private let lines: [Line]

    public var lineCount: Int { lines.count }

    public init(_ text: String, encoding: PositionEncoding = .utf16) {
        self.text = text
        self.encoding = encoding
        var lines: [Line] = []
        var start = text.startIndex
        var offset = 0
        var lineOffset = 0
        var index = start
        while index < text.endIndex {
            let next = text.index(after: index)
            if text.utf8[text.utf8.index(before: next)] == 10 {
                lines.append(Line(start: start, end: index, offset: lineOffset))
                start = next
                lineOffset = offset + 1
            }
            offset += 1
            index = next
        }
        lines.append(Line(start: start, end: text.endIndex, offset: lineOffset))
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
        let index = text.index(line.start, offsetBy: offset - line.offset)
        return LSPPosition(line: low, character: encoding.length(of: text[line.start..<index]))
    }

    /// Positions inside a grapheme round down by default; overlong columns clamp to end of line.
    public func characterOffset(at position: LSPPosition, roundingUp: Bool = false) -> Int? {
        guard lines.indices.contains(position.line), position.character >= 0 else { return nil }
        let line = lines[position.line]
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
    public static func between(_ old: String, and new: String,
                               encoding: PositionEncoding = .utf16) -> Self? {
        if old.utf8.elementsEqual(new.utf8) { return nil }
        var oldStart = old.startIndex
        var newStart = new.startIndex
        while oldStart < old.endIndex && newStart < new.endIndex {
            let oldNext = old.index(after: oldStart)
            let newNext = new.index(after: newStart)
            guard old[oldStart..<oldNext].utf8.elementsEqual(new[newStart..<newNext].utf8) else { break }
            oldStart = oldNext
            newStart = newNext
        }
        var oldEnd = old.endIndex
        var newEnd = new.endIndex
        while oldEnd > oldStart && newEnd > newStart {
            let oldPrevious = old.index(before: oldEnd)
            let newPrevious = new.index(before: newEnd)
            guard old[oldPrevious..<oldEnd].utf8.elementsEqual(new[newPrevious..<newEnd].utf8) else { break }
            oldEnd = oldPrevious
            newEnd = newPrevious
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
