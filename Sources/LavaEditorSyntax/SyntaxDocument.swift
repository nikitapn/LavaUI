import LavaText

/// The syntax tree of one open document, kept up to date with its buffer.
///
/// Owned by the document, not by any one feature: indentation is its first
/// reader, and highlighting, folding or selection by syntax node should read
/// the same tree rather than each parsing the file again.
///
/// It follows the buffer by revision. Asked about a `TextEditingState`, it
/// applies the splices the state recorded since the revision it last parsed
/// (`TextEditingState.changes(since:)`) to the tree and reparses only what
/// they touched. When the state cannot say — another editor's buffer, a
/// `setText`, a log that has moved on — it parses the text whole, which is
/// always correct and only slower. Parsing is lazy: nothing runs until a
/// feature asks.
public final class SyntaxDocument {
    public enum Language: Sendable {
        case swift, python, c, cpp
    }

    #if canImport(SwiftParser) && canImport(SwiftSyntax)
    public static let hasSwiftParser = true
    #else
    public static let hasSwiftParser = false
    #endif

    private var language: Language?
    private var treeSitter: TreeSitterTree?
    #if canImport(SwiftParser) && canImport(SwiftSyntax)
    private var swift: SwiftTree?
    #endif

    public init() {}

    /// The whitespace a new line at `caret` should start with, or nil to keep
    /// the current line's.
    public func indentation(
        for state: TextEditingState, at caret: String.Index, language: Language, unit: String = "    "
    ) -> String? {
        let text = state.text
        let offset = text.utf8.distance(from: text.utf8.startIndex, to: caret)
        return withBytes(of: text) { bytes in
            switch adopt(language) {
            case .swift:
                #if canImport(SwiftParser) && canImport(SwiftSyntax)
                guard let swift else { return nil }
                return swift.indentation(for: state, bytes: bytes, at: offset, unit: unit)
                #else
                return nil
                #endif
            case .python, .c, .cpp:
                guard let tree = treeSitter, let query = tree.grammar.indents,
                      let root = tree.sync(to: state, bytes: bytes) else { return nil }
                return IndentQuery.indentation(
                    query: query, tree: tree, root: root, bytes: bytes, at: offset, unit: unit
                )
            }
        }
    }

    /// The same, for a text that is not being edited. Parses it whole.
    public func indentation(
        in text: String, at caret: String.Index, language: Language, unit: String = "    "
    ) -> String? {
        indentation(for: TextEditingState(text), at: caret, language: language, unit: unit)
    }

    /// Switching language throws the tree away: none of it means anything
    /// in another grammar.
    private func adopt(_ next: Language) -> Language {
        guard next != language else { return next }
        language = next
        treeSitter = nil
        #if canImport(SwiftParser) && canImport(SwiftSyntax)
        swift = nil
        #endif
        switch next {
        case .swift:
            #if canImport(SwiftParser) && canImport(SwiftSyntax)
            swift = SwiftTree()
            #endif
        case .python: treeSitter = TreeSitterTree(.python)
        case .c: treeSitter = TreeSitterTree(.c)
        case .cpp: treeSitter = TreeSitterTree(.cpp)
        }
        return next
    }

    // MARK: Testing

    /// How many times the tree was built from nothing rather than edited.
    var fullParses: Int {
        #if canImport(SwiftParser) && canImport(SwiftSyntax)
        if let swift { return swift.fullParses }
        #endif
        return treeSitter?.fullParses ?? 0
    }

    /// The tree as an S-expression, synced to `state` first.
    func sExpression(for state: TextEditingState, language: Language) -> String? {
        guard language != .swift else { return nil }
        _ = adopt(language)
        return withBytes(of: state.text) { bytes in
            treeSitter?.sync(to: state, bytes: bytes)?.sExpressionString
        }
    }
}

/// The buffer's UTF-8 without copying it. A native string is contiguous; the
/// copy is for one that is not, which a Swift buffer on Linux never is.
func withBytes<R>(of text: String, _ body: (UnsafeBufferPointer<UInt8>) -> R) -> R {
    if let result = text.utf8.withContiguousStorageIfAvailable(body) { return result }
    return Array(text.utf8).withUnsafeBufferPointer(body)
}

func isHorizontalSpace(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x09 }

/// The leading whitespace of the line holding `offset`.
func lineIndent(in bytes: UnsafeBufferPointer<UInt8>, at offset: Int) -> String {
    var start = offset
    while start > 0, bytes[start - 1] != 0x0a { start -= 1 }
    var end = start
    while end < bytes.count, isHorizontalSpace(bytes[end]) { end += 1 }
    return String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<end]), as: UTF8.self)
}

/// One level past `base`, in the base's own character when it ends in a tab.
func indented(_ base: String, by unit: String) -> String {
    base + (base.last == "\t" ? "\t" : unit)
}
