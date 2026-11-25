import Foundation
internal import SwiftTreeSitter
internal import TreeSitter

/// One grammar and the last parsed version of an open document.
final class TreeSitterDocument {
    private let parser = Parser()
    private let hasLanguage: Bool
    private var tree: MutableTree?
    private(set) var bytes: [UInt8] = []

    init(_ language: OpaquePointer?) {
        if let language, (try? parser.setLanguage(language)) != nil {
            hasLanguage = true
        } else {
            hasLanguage = false
        }
    }

    /// Last token on the caret's physical line, ignoring trailing comments.
    func token(before caret: Int, in root: Node) -> Node? {
        var end = caret
        while end > 0 {
            while end > 0, isHorizontalSpace(bytes[end - 1]) { end -= 1 }
            guard end > 0, bytes[end - 1] != 0x0a,
                  let token = root.descendant(in: UInt32(end - 1)..<UInt32(end)) else { return nil }
            if token.nodeType != "comment" { return token }
            let commentStart = Int(token.byteRange.lowerBound)
            guard !bytes[commentStart..<end].contains(0x0a) else { return nil }
            end = commentStart
        }
        return nil
    }

    /// The innermost delimiter pair among a syntax node’s immediate children.
    func openDelimiter(in node: Node, at caret: Int) -> (open: Int, close: Int?)? {
        var unmatched: [(offset: Int, close: String)] = []
        let template = node.nodeType == "template_argument_list" || node.nodeType == "template_parameter_list"
        for index in 0..<node.childCount {
            guard let child = node.child(at: index), let kind = child.nodeType, !child.isMissing else { continue }
            let offset = Int(child.byteRange.lowerBound)
            if offset >= caret {
                if let opening = unmatched.last {
                    return (opening.offset, opening.close == kind ? offset : nil)
                }
                return nil
            }
            // A recovered unterminated quote can leave apparent code tokens
            // after a string_start error on the same line.
            if kind == "ERROR", child.firstChild?.nodeType == "string_start",
               !bytes[offset..<caret].contains(0x0a) {
                return nil
            }
            switch kind {
            case "(": unmatched.append((offset, ")"))
            case "[": unmatched.append((offset, "]"))
            case "{": unmatched.append((offset, "}"))
            case "<" where template: unmatched.append((offset, ">"))
            case ")", "]", "}", ">":
                if unmatched.last?.close == kind { unmatched.removeLast() }
            default:
                break
            }
        }
        return unmatched.last.map { ($0.offset, nil) }
    }

    func parse(_ text: String) -> Node? {
        let source = Array(text.utf8)
        guard hasLanguage, source.count < Int(UInt32.max) else { return nil }
        if let tree {
            if source == bytes { return tree.rootNode }
            let change = SourceChange(from: bytes, to: source)
            tree.edit(InputEdit(
                startByte: change.start, oldEndByte: change.oldEnd, newEndByte: change.newEnd,
                startPoint: point(in: bytes, at: change.start), oldEndPoint: point(in: bytes, at: change.oldEnd),
                newEndPoint: point(in: source, at: change.newEnd)
            ))
        }
        tree = parser.parse(tree: tree, encoding: TSInputEncodingUTF8) { offset, _ in
            guard offset < source.count else { return nil }
            var end = min(offset + 4096, source.count)
            while end < source.count, SourceChange.isContinuation(source[end]) { end += 1 }
            return Data(source[offset..<end])
        }
        bytes = source
        return tree?.rootNode
    }

    private func point(in source: [UInt8], at offset: Int) -> Point {
        var row = 0
        var lineStart = 0
        for index in 0..<offset where source[index] == 0x0a {
            row += 1
            lineStart = index + 1
        }
        return Point(row: row, column: offset - lineStart)
    }
}
