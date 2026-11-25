#if canImport(SwiftParser) && canImport(SwiftSyntax)
import LavaText
#if canImport(SwiftIDEUtils)
@_implementationOnly import SwiftIDEUtils
#endif
@_implementationOnly import SwiftParser
@_implementationOnly import SwiftSyntax

/// A Swift document on the compiler's own parser, following the buffer the
/// way `TreeSitterTree` does: edits are applied as they come and parsed
/// incrementally when someone needs the tree.
///
/// SwiftSyntax rather than tree-sitter because tree-sitter has no grammar for
/// Swift that it maintains; the rules here are code, not a query, for the
/// same reason. Used only on the parse worker's queue.
final class SwiftTree {
    private var previous: IncrementalParseResult?
    /// Splices since `previous`, in order.
    private var pending: [SourceEdit] = []
    private var isCurrent = false
    private(set) var lines = LineStarts()
    private(set) var fullParses = 0

    var isDirty: Bool { !isCurrent }

    func reset(_ bytes: UnsafeBufferPointer<UInt8>) {
        previous = nil
        pending = []
        isCurrent = false
        lines = LineStarts(bytes)
    }

    /// False when a splice does not fit the buffer this tree knows.
    func apply(_ changes: [TextChange]) -> Bool {
        for change in changes {
            guard change.offset >= 0, change.offset + change.removedLength <= lines.byteCount else { return false }
            lines.apply(change)
        }
        pending += changes.map {
            SourceEdit(
                range: AbsolutePosition(utf8Offset: $0.offset)..<AbsolutePosition(utf8Offset: $0.offset + $0.removedLength),
                replacement: Array($0.inserted.utf8)
            )
        }
        isCurrent = false
        return true
    }

    #if canImport(SwiftIDEUtils)
    /// The compiler's own classification of lines `wanted`, as highlight
    /// names. What it calls an identifier, an operator or an argument label
    /// is left plain, as `variable` is for the tree-sitter languages: those
    /// are most of a line, and colouring them would bury what is not.
    func highlights(bytes: UnsafeBufferPointer<UInt8>, wanted: Range<Int>, revision: UInt64) -> HighlightLayer {
        let tree = parse(bytes)
        let span = HighlightPaint.byteSpan(of: wanted, lines: lines, total: bytes.count)
        var captures: [HighlightPaint.Capture] = []
        if !span.isEmpty {
            let range = AbsolutePosition(utf8Offset: span.lowerBound)..<AbsolutePosition(utf8Offset: span.upperBound)
            for classified in tree.classifications(in: range) {
                guard let name = Self.names[classified.kind] else { continue }
                captures.append(.init(
                    start: classified.range.lowerBound.utf8Offset, end: classified.range.upperBound.utf8Offset,
                    priority: 0, name: name
                ))
            }
            // What the classifier calls an identifier but a reader does not.
            // A walk of the lines asked for only, token by token.
            var token = tree.token(at: range.lowerBound)
            while let current = token, current.positionAfterSkippingLeadingTrivia < range.upperBound {
                if let name = Self.contextualName(of: current) {
                    captures.append(.init(
                        start: current.positionAfterSkippingLeadingTrivia.utf8Offset,
                        end: current.endPositionBeforeTrailingTrivia.utf8Offset, priority: 1, name: name
                    ))
                }
                token = current.nextToken(viewMode: .sourceAccurate)
            }
        }
        return HighlightPaint.layer(captures, bytes: bytes, lines: lines, wanted: wanted, revision: revision)
    }

    /// A module named by an import, and the `set` of `private(set)`: both
    /// identifiers to the classifier, and both coloured by the lexer this
    /// replaced — losing them read as a regression.
    private static func contextualName(of token: TokenSyntax) -> Int? {
        guard case .identifier = token.tokenKind, let parent = token.parent else { return nil }
        if parent.is(ImportPathComponentSyntax.self) { return namespace }
        if parent.is(DeclModifierDetailSyntax.self) { return HighlightName.keyword }
        return nil
    }

    private static let namespace = HighlightName.index(of: "namespace")

    private static let names: [SyntaxClassification: Int] = {
        let names: [SyntaxClassification: String] = [
            .keyword: "keyword",
            .stringLiteral: "string",
            .regexLiteral: "string.regexp",
            .integerLiteral: "number",
            .floatLiteral: "number",
            .lineComment: "comment",
            .blockComment: "comment",
            .docLineComment: "comment.documentation",
            .docBlockComment: "comment.documentation",
            .type: "type",
            .attribute: "attribute",
            .ifConfigDirective: "keyword.directive",
            .dollarIdentifier: "variable.builtin",
        ]
        return names.mapValues { HighlightName.index(of: $0) }
    }()
    #endif

    func indentation(bytes: UnsafeBufferPointer<UInt8>, at caret: Int, unit: String) -> String? {
        guard caret > 0 else { return nil }
        let tree = parse(bytes)
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

    @discardableResult
    func parse(_ bytes: UnsafeBufferPointer<UInt8>) -> SourceFileSyntax {
        if isCurrent, let previous { return previous.tree }
        let transition = previous.map {
            IncrementalParseTransition(
                previousIncrementalParseResult: $0, edits: ConcurrentEdits(fromSequential: pending)
            )
        }
        var result = Parser.parseIncrementally(source: bytes, parseTransition: transition)
        // A tree that does not span the buffer means the edits and the old
        // tree disagreed; start over rather than answer from it.
        if transition == nil || result.tree.totalLength.utf8Length != bytes.count {
            if transition != nil { result = Parser.parseIncrementally(source: bytes, parseTransition: nil) }
            fullParses += 1
        }
        previous = result
        pending = []
        isCurrent = true
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
