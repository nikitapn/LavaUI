public struct DecodedSemanticTokens: Sendable, Equatable {
    /// Server data to supply on a later delta request. Keep it separate from shifted display tokens.
    public let snapshot: SemanticTokensSnapshot
    public let tokens: [SemanticToken]
}

extension LSPClient {
    @discardableResult
    public func definition(uri: String, at position: LSPPosition, timeout: Double = 30,
                           completion: @escaping Reply<[LSPLocation]>) -> LSPRequestID {
        enqueueRequest(timeout: timeout, completion: completion) { _ in
            ("textDocument/definition", Self.positionParams(uri, position), { try $0.decode(DefinitionResult.self).locations })
        }
    }

    @discardableResult
    public func hover(uri: String, at position: LSPPosition, timeout: Double = 30,
                      completion: @escaping Reply<LSPHover?>) -> LSPRequestID {
        request("textDocument/hover", params: Self.positionParams(uri, position),
                as: LSPHover?.self, timeout: timeout, completion: completion)
    }

    @discardableResult
    public func completion(uri: String, at position: LSPPosition, timeout: Double = 30,
                           completion: @escaping Reply<CompletionResult>) -> LSPRequestID {
        request("textDocument/completion", params: Self.positionParams(uri, position),
                as: CompletionResult.self, timeout: timeout, completion: completion)
    }

    /// Pass a previous snapshot from the same document and server session to request a delta.
    /// A server may return a new full snapshot in response to a delta request.
    @discardableResult
    public func semanticTokens(uri: String, previous: SemanticTokensSnapshot? = nil, timeout: Double = 30,
                               completion: @escaping Reply<DecodedSemanticTokens?>) -> LSPRequestID {
        enqueueRequest(timeout: timeout, completion: completion) { capabilities in
            guard capabilities.supportsSemanticTokensFull, let legend = capabilities.semanticTokens else {
                throw LSPClientError.unsupported
            }
            var method = "textDocument/semanticTokens/full"
            var params = ["textDocument": Self.documentID(uri)]
            if capabilities.supportsSemanticTokensDelta, let id = previous?.resultId {
                method += "/delta"
                params["previousResultId"] = .string(id)
            }
            return (method, .object(params), { result in
                if result == .null { return nil }
                let snapshot: SemanticTokensSnapshot
                if let edits = result["edits"], let previous {
                    snapshot = try previous.applying(edits.decode([SemanticTokensEdit].self),
                                                     resultId: result["resultId"]?.string)
                } else {
                    snapshot = try result.decode(SemanticTokensSnapshot.self)
                }
                return DecodedSemanticTokens(snapshot: snapshot, tokens: try legend.decode(snapshot.data))
            })
        }
    }

    private static func positionParams(_ uri: String, _ position: LSPPosition) -> JSON {
        .object([
            "textDocument": documentID(uri),
            "position": .object(["line": .integer(position.line), "character": .integer(position.character)]),
        ])
    }
}
