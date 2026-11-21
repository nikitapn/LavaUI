public struct ServerCapabilities: Decodable, Sendable {
    public enum SyncKind: Int, Decodable, Sendable {
        case none = 0, full, incremental
    }

    public let positionEncoding: PositionEncoding
    public let syncKind: SyncKind
    public let openClose: Bool
    public let saveIncludesText: Bool?
    public let semanticTokens: SemanticTokenLegend?
    public let supportsSemanticTokensFull: Bool
    public let supportsSemanticTokensDelta: Bool

    private enum CodingKeys: String, CodingKey {
        case positionEncoding, textDocumentSync, semanticTokensProvider
    }

    private struct Sync: Decodable {
        let openClose: Bool?
        let change: SyncKind?
        let save: JSON?
    }

    private struct Tokens: Decodable {
        let legend: SemanticTokenLegend
        let full: JSON?
    }

    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        positionEncoding = try fields.decodeIfPresent(PositionEncoding.self, forKey: .positionEncoding) ?? .utf16
        if let kind = try? fields.decode(SyncKind.self, forKey: .textDocumentSync) {
            syncKind = kind
            openClose = kind != .none
            saveIncludesText = nil
        } else {
            let sync = try fields.decodeIfPresent(Sync.self, forKey: .textDocumentSync)
            syncKind = sync?.change ?? .none
            openClose = sync?.openClose ?? false
            switch sync?.save {
            case .bool(true): saveIncludesText = false
            case .object(let fields): saveIncludesText = fields["includeText"] == .bool(true)
            default: saveIncludesText = nil
            }
        }

        let provider = try fields.decodeIfPresent(Tokens.self, forKey: .semanticTokensProvider)
        semanticTokens = provider?.legend
        switch provider?.full {
        case .bool(true), .object: supportsSemanticTokensFull = true
        default: supportsSemanticTokensFull = false
        }
        supportsSemanticTokensDelta = provider?.full?["delta"] == .bool(true)
    }

    static let client: JSON = .object([
        "general": .object(["positionEncodings": .array([.string("utf-8"), .string("utf-16")])]),
        // Refresh support is what makes a server's highlighting arrive at all
        // for a file it is still preparing: sourcekit-lsp answers the first
        // request with nothing, and asks for another once it knows more.
        "workspace": .object([
            "configuration": .bool(true),
            "semanticTokens": .object(["refreshSupport": .bool(true)]),
        ]),
        "window": .object(["workDoneProgress": .bool(true)]),
        "textDocument": .object([
            "publishDiagnostics": .object(["versionSupport": .bool(true)]),
            "definition": .object(["linkSupport": .bool(true)]),
            "hover": .object(["contentFormat": .array([.string("plaintext"), .string("markdown")])]),
            // Snippets are what tell an editor where in `foo(, )` the caret
            // goes; without them a server sends the call with its arguments
            // empty and nothing to say which one comes first.
            "completion": .object(["completionItem": .object([
                "insertReplaceSupport": .bool(true),
                "snippetSupport": .bool(true),
            ])]),
            "semanticTokens": .object([
                "requests": .object(["full": .object(["delta": .bool(true)])]),
                "tokenTypes": .array([
                    "namespace", "type", "class", "enum", "interface", "struct", "typeParameter",
                    "parameter", "variable", "property", "enumMember", "event", "function", "method",
                    "macro", "keyword", "modifier", "comment", "string", "number", "regexp",
                    "operator", "decorator",
                ].map(JSON.string)),
                "tokenModifiers": .array([
                    "declaration", "definition", "readonly", "static", "deprecated", "abstract",
                    "async", "modification", "documentation", "defaultLibrary",
                ].map(JSON.string)),
                "formats": .array([.string("relative")]),
                "overlappingTokenSupport": .bool(false),
                "multilineTokenSupport": .bool(false),
            ]),
        ]),
    ])
}
