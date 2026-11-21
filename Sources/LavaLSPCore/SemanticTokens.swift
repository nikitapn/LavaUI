public struct SemanticTokenLegend: Codable, Sendable, Equatable {
    public let tokenTypes: [String]
    public let tokenModifiers: [String]

    public init(tokenTypes: [String], tokenModifiers: [String]) {
        self.tokenTypes = tokenTypes
        self.tokenModifiers = tokenModifiers
    }

    public func decode(_ data: [Int]) throws -> [SemanticToken] {
        guard data.count.isMultiple(of: 5) else { throw SemanticTokensError.invalidData }
        var line = 0
        var start = 0
        var tokens: [SemanticToken] = []
        tokens.reserveCapacity(data.count / 5)
        for index in stride(from: 0, to: data.count, by: 5) {
            let deltaLine = data[index]
            let deltaStart = data[index + 1]
            let length = data[index + 2]
            let type = data[index + 3]
            let bits = data[index + 4]
            guard deltaLine >= 0, deltaStart >= 0, length > 0,
                  tokenTypes.indices.contains(type), bits >= 0
            else { throw SemanticTokensError.invalidData }

            let (nextLine, lineOverflow) = line.addingReportingOverflow(deltaLine)
            let (nextStart, startOverflow) = (deltaLine == 0 ? start : 0).addingReportingOverflow(deltaStart)
            guard !lineOverflow, !startOverflow, length <= Int.max - nextStart
            else { throw SemanticTokensError.invalidData }
            line = nextLine
            start = nextStart
            let modifiers = tokenModifiers.enumerated().compactMap { bit, name in
                bits & (1 << bit) == 0 ? nil : name
            }
            tokens.append(SemanticToken(line: line, start: start, length: length,
                                        type: tokenTypes[type], modifiers: modifiers))
        }
        return tokens
    }
}

public enum SemanticTokensError: Error, Sendable, Equatable {
    case invalidData
    case invalidDelta
}

public struct SemanticToken: Sendable, Equatable {
    public let line: Int
    public let start: Int
    public let length: Int
    public let type: String
    public let modifiers: [String]

    fileprivate init(line: Int, start: Int, length: Int, type: String, modifiers: [String]) {
        self.line = line
        self.start = start
        self.length = length
        self.type = type
        self.modifiers = modifiers
    }

    public var range: LSPRange {
        LSPRange(start: LSPPosition(line: line, character: start),
                 end: LSPPosition(line: line, character: start + length))
    }

    /// Shifts single-line tokens in negotiated units. An insertion inside a token drops it.
    public static func shifting(_ tokens: [Self], for change: IncrementalChange,
                                encoding: PositionEncoding) -> [Self] {
        let oldStart = change.range.start
        let oldEnd = change.range.end
        guard oldStart.line >= 0, oldStart.character >= 0, oldEnd.character >= 0, oldStart <= oldEnd,
              oldStart != oldEnd || !change.text.isEmpty else { return tokens }
        let replacement = DocumentPositions(change.text, encoding: encoding)
        guard let end = replacement.position(atCharacterOffset: replacement.characterCount) else { return tokens }
        let (newEndLine, lineOverflow) = oldStart.line.addingReportingOverflow(end.line)
        let (newEndColumn, columnOverflow) = (end.line == 0 ? oldStart.character : 0)
            .addingReportingOverflow(end.character)
        guard !lineOverflow, !columnOverflow else { return tokens }
        return tokens.compactMap { token in
            if token.range.end <= oldStart { return token }
            guard token.range.start >= oldEnd else { return nil }
            let (line, lineOverflow) = newEndLine.addingReportingOverflow(token.line - oldEnd.line)
            let (start, columnOverflow) = token.line == oldEnd.line
                ? newEndColumn.addingReportingOverflow(token.start - oldEnd.character)
                : (token.start, false)
            guard !lineOverflow, !columnOverflow, token.length <= Int.max - start else { return nil }
            return Self(line: line, start: start, length: token.length, type: token.type, modifiers: token.modifiers)
        }
    }
}

public struct SemanticTokensEdit: Decodable, Sendable, Equatable {
    public let start: Int
    public let deleteCount: Int
    public let data: [Int]?

    public init(start: Int, deleteCount: Int, data: [Int]? = nil) {
        self.start = start
        self.deleteCount = deleteCount
        self.data = data
    }
}

public struct SemanticTokensSnapshot: Decodable, Sendable, Equatable {
    public let resultId: String?
    public let data: [Int]

    public init(resultId: String? = nil, data: [Int]) {
        self.resultId = resultId
        self.data = data
    }

    public func applying(_ edits: [SemanticTokensEdit], resultId: String?) throws -> Self {
        // Starts refer to the original array. Copy its spans once, even when edits are unsorted.
        var updated: [Int] = []
        var cursor = 0
        for edit in edits.sorted(by: { $0.start < $1.start }) {
            guard edit.start >= cursor, edit.start <= data.count,
                  edit.deleteCount >= 0, edit.deleteCount <= data.count - edit.start
            else { throw SemanticTokensError.invalidDelta }
            updated.append(contentsOf: data[cursor..<edit.start])
            if let inserted = edit.data { updated.append(contentsOf: inserted) }
            cursor = edit.start + edit.deleteCount
        }
        updated.append(contentsOf: data[cursor...])
        return Self(resultId: resultId, data: updated)
    }
}
