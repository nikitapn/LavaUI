#if canImport(SwiftParser) && canImport(SwiftSyntax)
@_implementationOnly import SwiftParser
@_implementationOnly import SwiftSyntax

final class SwiftIndentation {
    private var bytes: [UInt8] = []
    private var previous: IncrementalParseResult?

    func indentation(in text: String, at caret: Int, unit: String) -> String? {
        guard caret > 0 else { return nil }
        let tree = parse(Array(text.utf8))
        var token = tree.token(at: AbsolutePosition(utf8Offset: caret - 1))
        while let candidate = token, candidate.endPositionBeforeTrailingTrivia.utf8Offset > caret
                || candidate.tokenKind == .endOfFile {
            // A split within the text of a token keeps the line's indentation.
            guard candidate.positionAfterSkippingLeadingTrivia.utf8Offset >= caret
                    || candidate.tokenKind == .endOfFile else { return nil }
            token = candidate.previousToken(viewMode: .sourceAccurate)
        }
        guard let token else { return nil }
        let tokenEnd = token.endPositionBeforeTrailingTrivia.utf8Offset
        let sameLine = !bytes[tokenEnd..<caret].contains(0x0a)

        if sameLine, token.tokenKind == .colon,
           let label = token.parent,
           label.is(SwitchCaseLabelSyntax.self) || label.is(SwitchDefaultLabelSyntax.self) {
            return indented(lineIndent(in: bytes, at: label.positionAfterSkippingLeadingTrivia.utf8Offset), by: unit)
        }

        var ancestor = token.parent
        while let node = ancestor {
            if node.is(StringLiteralExprSyntax.self) || node.is(RegexLiteralExprSyntax.self) { return nil }
            if let (opening, closing) = delimiters(of: node),
               opening.presence == .present,
               opening.endPositionBeforeTrailingTrivia.utf8Offset <= caret {
                let base = lineIndent(in: bytes, at: opening.positionAfterSkippingLeadingTrivia.utf8Offset)
                if let closing, closing.presence == .present {
                    let end = closing.positionAfterSkippingLeadingTrivia.utf8Offset
                    if end < caret {
                        ancestor = node.parent
                        continue
                    }
                    if bytes[caret..<end].allSatisfy(isHorizontalSpace) { return base }
                }
                if opening.tokenKind != .leftBrace || (sameLine && opening == token) {
                    return indented(base, by: unit)
                }
                // Inside a block, inherit body indentation unless a nested
                // argument list has already supplied a more specific answer.
                return nil
            }
            ancestor = node.parent
        }
        if sameLine, token.tokenKind == .leftBrace {
            return indented(lineIndent(in: bytes, at: tokenEnd), by: unit)
        }
        return nil
    }

    private func parse(_ source: [UInt8]) -> SourceFileSyntax {
        if let previous, source == bytes { return previous.tree }
        let transition = previous.map { previous in
            let change = SourceChange(from: bytes, to: source)
            let edit = SourceEdit(
                range: AbsolutePosition(utf8Offset: change.start)..<AbsolutePosition(utf8Offset: change.oldEnd),
                replacement: Array(source[change.start..<change.newEnd])
            )
            return IncrementalParseTransition(previousIncrementalParseResult: previous, edits: ConcurrentEdits(edit))
        }
        let result: IncrementalParseResult = source.withUnsafeBufferPointer {
            Parser.parseIncrementally(source: $0, parseTransition: transition)
        }
        bytes = source
        previous = result
        return result.tree
    }

    private func delimiters(of node: Syntax) -> (TokenSyntax, TokenSyntax?)? {
        if let call = node.as(FunctionCallExprSyntax.self), let opening = call.leftParen {
            return (opening, call.rightParen)
        }
        if let parameters = node.as(FunctionParameterClauseSyntax.self) {
            return (parameters.leftParen, parameters.rightParen)
        }
        if let tuple = node.as(TupleExprSyntax.self) { return (tuple.leftParen, tuple.rightParen) }
        if let array = node.as(ArrayExprSyntax.self) { return (array.leftSquare, array.rightSquare) }
        if let dictionary = node.as(DictionaryExprSyntax.self) { return (dictionary.leftSquare, dictionary.rightSquare) }
        if let index = node.as(SubscriptCallExprSyntax.self) { return (index.leftSquare, index.rightSquare) }
        if let block = node.as(CodeBlockSyntax.self) { return (block.leftBrace, block.rightBrace) }
        if let closure = node.as(ClosureExprSyntax.self) { return (closure.leftBrace, closure.rightBrace) }
        if let members = node.as(MemberBlockSyntax.self) { return (members.leftBrace, members.rightBrace) }
        if let statement = node.as(SwitchExprSyntax.self) { return (statement.leftBrace, statement.rightBrace) }
        return nil
    }
}
#endif
