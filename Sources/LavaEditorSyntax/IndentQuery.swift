internal import SwiftTreeSitter

/// Indentation for a new line, from a language's `indents.scm`.
///
/// The answer is always relative to a line already in the file — the line a
/// scope opened on, or a statement began on — plus at most one level, so the
/// whitespace the file already has is carried over and never rewritten. Nil
/// means "keep the current line's", which is the right answer for anything
/// the rules do not cover.
///
/// Captures a query may use:
///
/// | Capture | On | Means |
/// |---|---|---|
/// | `@indent.scope` | a node | Its bracket children open a scope: after an unclosed opener, one level past the opener's line; directly before the closer, at the opener's line |
/// | `@indent.block` | a node | The same, except that a brace opens a block, whose body past its first line keeps the user's indentation |
/// | `@indent.after` | a token | Last on the line, it indents the next one level past `@indent.anchor` (or its parent) |
/// | `@indent.anchor` | a node | The line `@indent.after` counts from |
/// | `@indent.ignore` | a node | Text, not code: no answer with the caret inside it, or right after it when it is a leaf |
/// | `@indent.open_string` | a node | A string that never closed: no answer on the line it starts |
/// | `@indent.comment` | a node | Skipped when looking for the line's last token |
///
/// Brackets are `(`, `[` and `{`, and `<` in a node that begins with one — a
/// template list, not a comparison.
enum IndentQuery {
    private enum Scope { case scope, block }

    private struct Key: Hashable {
        let id: UInt
        let range: Range<UInt32>
        init(_ node: Node) {
            id = node.id
            range = node.byteRange
        }
    }

    /// What the query said about the nodes on the caret's line and the ones
    /// enclosing it.
    private struct Captures {
        var scopes: [Key: Scope] = [:]
        var ignore: Set<Key> = []
        var comments: Set<Key> = []
        var openStrings: [Int] = []
        /// Each `@indent.after` token and its anchor, if the pattern named one.
        var after: [Key: Node?] = [:]

        init(query: Query, tree: MutableTree, root: Node, range: Range<Int>) {
            let cursor = query.execute(node: root, in: tree)
            cursor.setByteRange(range: UInt32(range.lowerBound)..<UInt32(range.upperBound))
            while let match = cursor.next() {
                var anchor: Node?
                var token: Node?
                for capture in match.captures {
                    let key = Key(capture.node)
                    switch capture.name {
                    case "indent.scope": scopes[key] = scopes[key] ?? .scope
                    case "indent.block": scopes[key] = .block
                    case "indent.ignore": ignore.insert(key)
                    case "indent.comment": comments.insert(key)
                    case "indent.open_string": openStrings.append(Int(capture.node.byteRange.lowerBound))
                    case "indent.after": token = capture.node
                    case "indent.anchor": anchor = capture.node
                    default: break
                    }
                }
                if let token { after[Key(token)] = anchor }
            }
        }
    }

    static func indentation(
        query: Query, tree: TreeSitterTree, root: Node, bytes: UnsafeBufferPointer<UInt8>, at caret: Int,
        unit: String
    ) -> String? {
        let lineStart = tree.lines.lineStart(at: caret)
        guard caret > lineStart, let mutable = tree.mutableTree else { return nil }
        let captures = Captures(query: query, tree: mutable, root: root, range: lineStart..<caret)
        guard let token = lastToken(before: caret, lineStart: lineStart, in: root, bytes: bytes, captures: captures)
        else { return nil }
        if captures.openStrings.contains(where: { lineStart <= $0 && $0 < caret }) { return nil }

        if let entry = captures.after[Key(token)] {
            let anchor = entry ?? token.parent ?? token
            return indented(lineIndent(in: bytes, at: Int(anchor.byteRange.lowerBound)), by: unit)
        }
        if token.childCount == 0, captures.ignore.contains(Key(token)) { return nil }

        var ancestor = token.parent
        while let node = ancestor {
            let key = Key(node)
            if captures.ignore.contains(key), caret < node.byteRange.upperBound { return nil }
            if let scope = captures.scopes[key], let delimiter = openDelimiter(in: node, at: caret) {
                let base = lineIndent(in: bytes, at: delimiter.open)
                if let close = delimiter.close,
                   UnsafeBufferPointer(rebasing: bytes[caret..<close]).allSatisfy(isHorizontalSpace) {
                    return base
                }
                if scope == .block, bytes[delimiter.open] == UInt8(ascii: "{"),
                   UnsafeBufferPointer(rebasing: bytes[delimiter.open..<caret]).contains(0x0a) {
                    return nil
                }
                return indented(base, by: unit)
            }
            ancestor = node.parent
        }
        return nil
    }

    /// The last token on the caret's line before it, not counting trailing
    /// comments; nil when there is none.
    private static func lastToken(
        before caret: Int, lineStart: Int, in root: Node, bytes: UnsafeBufferPointer<UInt8>, captures: Captures
    ) -> Node? {
        var end = caret
        while end > lineStart {
            while end > lineStart, isHorizontalSpace(bytes[end - 1]) { end -= 1 }
            guard end > lineStart, let token = root.descendant(in: UInt32(end - 1)..<UInt32(end)) else { return nil }
            guard captures.comments.contains(Key(token)) else { return token }
            // A comment that began on an earlier line means the caret is in
            // its middle, which is prose.
            let start = Int(token.byteRange.lowerBound)
            guard start >= lineStart else { return nil }
            end = start
        }
        return nil
    }

    /// The innermost bracket among `node`'s own children that is open at
    /// `caret`, and its closer when it has one.
    private static func openDelimiter(in node: Node, at caret: Int) -> (open: Int, close: Int?)? {
        var unmatched: [(offset: Int, close: String)] = []
        let angle = node.firstChild?.nodeType == "<"
        for index in 0..<node.childCount {
            guard let child = node.child(at: index), let kind = child.nodeType, !child.isMissing else { continue }
            let offset = Int(child.byteRange.lowerBound)
            if offset >= caret {
                guard let opening = unmatched.last else { return nil }
                return (opening.offset, opening.close == kind ? offset : nil)
            }
            switch kind {
            case "(": unmatched.append((offset, ")"))
            case "[": unmatched.append((offset, "]"))
            case "{": unmatched.append((offset, "}"))
            case "<" where angle: unmatched.append((offset, ">"))
            case ")", "]", "}", ">":
                if unmatched.last?.close == kind { unmatched.removeLast() }
            default:
                break
            }
        }
        return unmatched.last.map { ($0.offset, nil) }
    }
}
