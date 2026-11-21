import Foundation

public enum DiagnosticSeverity: Int, Codable, Sendable {
    case error = 1, warning, information, hint
}

public struct LSPDiagnostic: Decodable, Sendable, Equatable {
    public let range: LSPRange
    public let severity: DiagnosticSeverity?
    public let message: String
    public let source: String?
    public let code: JSON?
}

public struct PublishedDiagnostics: Decodable, Sendable, Equatable {
    public let uri: String
    public let version: Int?
    public let diagnostics: [LSPDiagnostic]
}

public struct LSPLocation: Codable, Sendable, Equatable {
    public let uri: String
    public let range: LSPRange

    public init(uri: String, range: LSPRange) {
        self.uri = uri
        self.range = range
    }
}

public struct DefinitionResult: Decodable, Sendable, Equatable {
    public let locations: [LSPLocation]

    private struct Link: Decodable {
        let targetUri: String
        let targetSelectionRange: LSPRange
    }

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() {
            locations = []
        } else if let location = try? value.decode(LSPLocation.self) {
            locations = [location]
        } else if let locations = try? value.decode([LSPLocation].self) {
            self.locations = locations
        } else {
            locations = try value.decode([Link].self).map {
                LSPLocation(uri: $0.targetUri, range: $0.targetSelectionRange)
            }
        }
    }
}

public struct HoverContent: Sendable, Equatable {
    public let text: String
    public let language: String?
}

public struct LSPHover: Decodable, Sendable, Equatable {
    public let contents: [HoverContent]
    public let range: LSPRange?

    private enum CodingKeys: String, CodingKey { case contents, range }

    private struct Content: Decodable {
        let text: String
        let language: String?

        private enum CodingKeys: String, CodingKey { case kind, value, language }

        init(from decoder: Decoder) throws {
            if let markdown = try? decoder.singleValueContainer().decode(String.self) {
                (text, language) = Self.plainText(markdown)
                return
            }
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            let value = try fields.decode(String.self, forKey: .value)
            if try fields.decodeIfPresent(String.self, forKey: .kind) == "markdown" {
                (text, language) = Self.plainText(value)
            } else {
                text = value
                language = try fields.decodeIfPresent(String.self, forKey: .language)
            }
        }

        // Keep fenced code literal, including operators that look like Markdown.
        private static func plainText(_ markdown: String) -> (String, String?) {
            var fence: String?
            var language: String?
            var lines: [String] = []
            for line in markdown.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if let active = fence {
                    if trimmed.count >= active.count && trimmed.allSatisfy({ $0 == active.first }) {
                        fence = nil
                    } else {
                        lines.append(line)
                    }
                    continue
                }
                if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                    fence = String(trimmed.prefix { $0 == trimmed.first })
                    let info = trimmed.dropFirst(fence?.count ?? 0)
                    language = language ?? info.split(whereSeparator: \.isWhitespace).first.map(String.init)
                    continue
                }
                let plain = line
                    .replacingOccurrences(of: #"^\s{0,3}(#{1,6}|>)\s+"#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: #"!?(?:\[([^\]]*)\])\([^)]+\)"#, with: "$1",
                                          options: .regularExpression)
                    .replacingOccurrences(of: #"(`+|\*{1,3}|_{1,3}|~~)(\S(?:.*?\S)?)\1"#, with: "$2",
                                          options: .regularExpression)
                    .replacingOccurrences(of: #"\\([\\`*_{}\[\]()#+.!|>~-])"#, with: "$1",
                                          options: .regularExpression)
                lines.append(plain)
            }
            return (lines.joined(separator: "\n").trimmingCharacters(in: .newlines), language)
        }
    }

    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        range = try fields.decodeIfPresent(LSPRange.self, forKey: .range)
        let contents: [Content]
        if let list = try? fields.decode([Content].self, forKey: .contents) {
            contents = list
        } else {
            contents = [try fields.decode(Content.self, forKey: .contents)]
        }
        self.contents = contents.map { HoverContent(text: $0.text, language: $0.language) }
    }
}

public struct CompletionTextEdit: Decodable, Sendable, Equatable {
    public let newText: String
    public let insert: LSPRange
    public let replace: LSPRange

    private enum CodingKeys: String, CodingKey { case newText, range, insert, replace }

    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        newText = try fields.decode(String.self, forKey: .newText)
        if let range = try fields.decodeIfPresent(LSPRange.self, forKey: .range) {
            insert = range
            replace = range
        } else {
            insert = try fields.decode(LSPRange.self, forKey: .insert)
            replace = try fields.decode(LSPRange.self, forKey: .replace)
        }
    }
}

public struct CompletionItem: Decodable, Sendable, Equatable {
    public let label: String
    public let kind: Int?
    public let detail: String?
    public let insertText: String?
    public let textEdit: CompletionTextEdit?
    public let sortText: String?
    public let filterText: String?
    /// 2 when `insertText` / `textEdit` is a snippet; see `SnippetText`.
    public let insertTextFormat: Int?

    public var isSnippet: Bool { insertTextFormat == 2 }
}

public struct CompletionResult: Decodable, Sendable, Equatable {
    public let isIncomplete: Bool
    public let items: [CompletionItem]

    private enum CodingKeys: String, CodingKey { case isIncomplete, items }

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() {
            isIncomplete = false
            items = []
        } else if let items = try? value.decode([CompletionItem].self) {
            isIncomplete = false
            self.items = items
        } else {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            isIncomplete = try fields.decode(Bool.self, forKey: .isIncomplete)
            items = try fields.decode([CompletionItem].self, forKey: .items)
        }
    }
}
