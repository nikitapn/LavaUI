internal import SwiftTreeSitter
internal import TreeSitterPython

final class PythonIndentation {
    private let document = TreeSitterDocument(tree_sitter_python())

    func indentation(in text: String, at caret: Int, unit: String) -> String? {
        guard caret > 0, let root = document.parse(text),
              let leaf = document.token(before: caret, in: root),
              let parent = leaf.parent else { return nil }
        let bytes = document.bytes
        if leaf.nodeType == ":", leaf.byteRange.upperBound <= caret,
           (0..<parent.childCount).contains(where: { parent.child(at: $0)?.nodeType == "block" }) {
            return indented(lineIndent(in: bytes, at: Int(parent.byteRange.lowerBound)), by: unit)
        }

        var ancestor: Node? = parent
        while let node = ancestor {
            switch node.nodeType {
            case "string":
                guard caret >= node.byteRange.upperBound else { return nil }
            case "argument_list", "parameters", "tuple", "parenthesized_expression", "list",
                 "dictionary", "set", "subscript", "list_comprehension", "dictionary_comprehension",
                 "set_comprehension", "generator_expression", "ERROR":
                if let delimiter = document.openDelimiter(in: node, at: caret) {
                    let base = lineIndent(in: bytes, at: delimiter.open)
                    if let close = delimiter.close, bytes[caret..<close].allSatisfy(isHorizontalSpace) {
                        return base
                    }
                    return indented(base, by: unit)
                }
            default:
                break
            }
            ancestor = node.parent
        }
        return nil
    }
}
