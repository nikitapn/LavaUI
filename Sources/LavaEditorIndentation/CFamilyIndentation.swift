internal import SwiftTreeSitter
internal import TreeSitterC
internal import TreeSitterCPP

final class CFamilyIndentation {
    private let document: TreeSitterDocument

    init(cpp: Bool) {
        document = TreeSitterDocument(cpp ? tree_sitter_cpp() : tree_sitter_c())
    }

    func indentation(in text: String, at caret: Int, unit: String) -> String? {
        guard caret > 0, let root = document.parse(text),
              let token = document.token(before: caret, in: root),
              let parent = token.parent else { return nil }
        let bytes = document.bytes
        if token.nodeType == ":" {
            if parent.nodeType == "case_statement" {
                return indented(lineIndent(in: bytes, at: Int(parent.byteRange.lowerBound)), by: unit)
            }
            if let access = token.previousSibling, access.nodeType == "access_specifier" {
                return indented(lineIndent(in: bytes, at: Int(access.byteRange.lowerBound)), by: unit)
            }
        }
        // Error recovery can promote the contents of an unfinished literal
        // out of its string node.
        if token.nodeType == "string_content" || token.nodeType == "raw_string_content" { return nil }

        var ancestor: Node? = parent
        while let node = ancestor {
            switch node.nodeType {
            case "string_literal", "char_literal", "raw_string_literal":
                if caret < node.byteRange.upperBound { return nil }
            case "compound_statement", "field_declaration_list", "declaration_list",
                 "initializer_list", "enumerator_list", "argument_list", "parameter_list",
                 "parenthesized_expression", "parenthesized_declarator", "subscript_expression",
                 "subscript_argument_list", "array_declarator", "condition_clause", "for_statement",
                 "template_argument_list", "template_parameter_list", "ERROR":
                if let delimiter = document.openDelimiter(in: node, at: caret) {
                    let base = lineIndent(in: bytes, at: delimiter.open)
                    if let close = delimiter.close, bytes[caret..<close].allSatisfy(isHorizontalSpace) {
                        return base
                    }
                    // Inside a block, keep the body's current indentation.
                    // Argument and initializer lists keep using their opener.
                    if bytes[delimiter.open] == 0x7b,
                       node.nodeType != "initializer_list", node.nodeType != "enumerator_list",
                       bytes[delimiter.open..<caret].contains(0x0a) {
                        return nil
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
