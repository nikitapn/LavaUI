/// How one curly-brace-or-thereabouts language is written, as far as
/// colouring it needs: its keywords, its comments, its strings.
///
/// A table rather than a lexer per language, because Swift, C, JavaScript and
/// Python differ in their tables and almost nowhere else — and four
/// hand-written scanners would drift apart the first time one was fixed.
public struct CodeLanguage: Sendable {
    /// A string literal's delimiters.
    public struct StringForm: Sendable, Equatable {
        public var open: String
        public var close: String
        /// May run past the end of a line: `"""`, `'''`, a JS template.
        /// Otherwise an unclosed string ends with its line, as a compiler
        /// would have it (and the next line is not swallowed).
        public var multiline: Bool
        /// A backslash takes the next character with it.
        public var escapes: Bool

        public init(_ open: String, _ close: String, multiline: Bool = false, escapes: Bool = true) {
            self.open = open
            self.close = close
            self.multiline = multiline
            self.escapes = escapes
        }
    }

    public var keywords: Set<String>
    public var lineComments: [String]
    /// `/*` and `*/`, or nil for a language without block comments.
    public var blockComment: (open: String, close: String)?
    /// Swift nests block comments; C does not, and a C file with `/* /* */`
    /// is closed by the first `*/`.
    public var nestedComments: Bool
    /// Tried in order at each position, so a longer opener that starts with a
    /// shorter one (`"""` before `"`) must come first.
    public var strings: [StringForm]
    /// C's `#include`: a `#` first on its line colours the directive.
    public var preprocessor: Bool
    /// Characters that make the word after them an attribute or directive:
    /// Swift's `@MainActor` and `#if`, Python's `@decorator`.
    public var attributeMarks: Set<Character>
    /// Words starting with a capital read as types. No table can know what a
    /// type is; in every language here the convention holds often enough to
    /// be worth more than nothing.
    public var capitalizedAreTypes: Bool

    public init(
        keywords: Set<String>, lineComments: [String],
        blockComment: (open: String, close: String)? = nil, nestedComments: Bool = false,
        strings: [StringForm], preprocessor: Bool = false,
        attributeMarks: Set<Character> = [], capitalizedAreTypes: Bool = true
    ) {
        self.keywords = keywords
        self.lineComments = lineComments
        self.blockComment = blockComment
        self.nestedComments = nestedComments
        self.strings = strings
        self.preprocessor = preprocessor
        self.attributeMarks = attributeMarks
        self.capitalizedAreTypes = capitalizedAreTypes
    }
}

/// Where a line starts: in code, inside a block comment (how deep, for a
/// language that nests them), or inside a string that has not closed yet.
public enum CodeLexerState: Hashable, Sendable {
    case code
    case comment(depth: Int)
    /// Index into `CodeLanguage.strings`.
    case string(form: Int)
}

/// Colours code with state carried from line to line, so a block comment or a
/// multi-line string is coloured on every line it covers — not only on the
/// lines whose own text says so, which is all a rule list can do.
///
/// Styles are palette indices, the same ones the editor's rule lists use:
/// 0 keyword, 1 string, 2 comment, 3 number, 4 type / attribute / directive.
public struct CodeLexer: StatefulLexer {
    public static let keyword = 0
    public static let string = 1
    public static let comment = 2
    public static let number = 3
    public static let type = 4

    public let language: CodeLanguage
    private let lineComments: [[Character]]
    private let blockOpen: [Character]
    private let blockClose: [Character]
    private let opens: [[Character]]
    private let closes: [[Character]]

    public init(_ language: CodeLanguage) {
        self.language = language
        lineComments = language.lineComments.map(Array.init)
        blockOpen = language.blockComment.map { Array($0.open) } ?? []
        blockClose = language.blockComment.map { Array($0.close) } ?? []
        opens = language.strings.map { Array($0.open) }
        closes = language.strings.map { Array($0.close) }
    }

    public static var initialState: CodeLexerState { .code }

    public func highlight(
        _ line: String, state: CodeLexerState
    ) -> (spans: [HighlightSpan], nextState: CodeLexerState) {
        let c = Array(line)
        var spans: [HighlightSpan] = []
        var i = 0

        func emit(_ from: Int, _ to: Int, _ style: Int) {
            guard to > from else { return }
            // Adjacent runs of one style read as one, and fewer spans is
            // fewer text runs drawn.
            if let last = spans.last, last.styleIndex == style, last.range.upperBound == from {
                spans[spans.count - 1].range = last.range.lowerBound..<to
            } else {
                spans.append(HighlightSpan(range: from..<to, styleIndex: style))
            }
        }

        // Finish whatever the previous line left open.
        switch state {
        case .code:
            break
        case .comment(let depth):
            let (end, left) = scanComment(c, from: 0, depth: depth)
            emit(0, end, Self.comment)
            if left > 0 { return (spans, .comment(depth: left)) }
            i = end
        case .string(let form):
            guard language.strings.indices.contains(form) else { break }
            if let end = scanString(c, from: 0, form: form) {
                emit(0, end, Self.string)
                i = end
            } else {
                emit(0, c.count, Self.string)
                return (spans, .string(form: form))
            }
        }

        let firstNonSpace = c.firstIndex { $0 != " " && $0 != "\t" } ?? c.count
        while i < c.count {
            let ch = c[i]
            if ch == " " || ch == "\t" {
                i += 1
                continue
            }
            if lineComments.contains(where: { matches(c, $0, at: i) }) {
                emit(i, c.count, Self.comment)
                return (spans, .code)
            }
            if !blockOpen.isEmpty, matches(c, blockOpen, at: i) {
                let (end, left) = scanComment(c, from: i + blockOpen.count, depth: 1)
                emit(i, end, Self.comment)
                if left > 0 { return (spans, .comment(depth: left)) }
                i = end
                continue
            }
            if let form = opens.firstIndex(where: { matches(c, $0, at: i) }) {
                let body = i + opens[form].count
                if let end = scanString(c, from: body, form: form) {
                    emit(i, end, Self.string)
                    i = end
                    continue
                }
                emit(i, c.count, Self.string)
                return (spans, language.strings[form].multiline ? .string(form: form) : .code)
            }
            if language.preprocessor, ch == "#", i == firstNonSpace {
                var j = i + 1
                while j < c.count, c[j] == " " || c[j] == "\t" { j += 1 }
                while j < c.count, isIdentifier(c[j]) { j += 1 }
                emit(i, j, Self.type)
                i = j
                continue
            }
            if language.attributeMarks.contains(ch), i + 1 < c.count, isIdentifierStart(c[i + 1]) {
                var j = i + 1
                while j < c.count, isIdentifier(c[j]) { j += 1 }
                emit(i, j, Self.type)
                i = j
                continue
            }
            if isIdentifierStart(ch) {
                var j = i + 1
                while j < c.count, isIdentifier(c[j]) { j += 1 }
                let word = String(c[i..<j])
                if language.keywords.contains(word) {
                    emit(i, j, Self.keyword)
                } else if language.capitalizedAreTypes, ch.isUppercase {
                    emit(i, j, Self.type)
                }
                i = j
                continue
            }
            if ch.isASCII, ch.isNumber {
                var j = i + 1
                while j < c.count {
                    let d = c[j]
                    // `1..<5` is a range, not a malformed float.
                    if d == ".", j + 1 < c.count, c[j + 1] == "." { break }
                    if d == "." || d == "_" || (d.isASCII && (d.isLetter || d.isNumber)) {
                        j += 1
                    } else if d == "+" || d == "-" {
                        // An exponent's sign — `1e-9`, a hex float's `0x1p-3` —
                        // and nothing else: in `0xE-1` the `-` is subtraction.
                        let previous = c[j - 1]
                        let hex = j - i >= 2 && c[i] == "0" && (c[i + 1] == "x" || c[i + 1] == "X")
                        let exponent = hex ? (previous == "p" || previous == "P")
                                           : (previous == "e" || previous == "E")
                        guard exponent else { break }
                        j += 1
                    } else {
                        break
                    }
                }
                emit(i, j, Self.number)
                i = j
                continue
            }
            i += 1
        }
        return (spans, .code)
    }

    /// From `from`, inside a comment `depth` deep: where the scan stopped, and
    /// how deep it still is there (0 once the comment has closed).
    private func scanComment(_ c: [Character], from: Int, depth: Int) -> (end: Int, depth: Int) {
        var depth = depth
        var i = from
        while i < c.count {
            if matches(c, blockClose, at: i) {
                depth -= 1
                i += blockClose.count
                if depth == 0 { return (i, 0) }
                continue
            }
            if language.nestedComments, matches(c, blockOpen, at: i) {
                depth += 1
                i += blockOpen.count
                continue
            }
            i += 1
        }
        return (c.count, depth)
    }

    /// From `from`, inside string `form`: the index just past its close, or
    /// nil if the line ends first.
    private func scanString(_ c: [Character], from: Int, form: Int) -> Int? {
        let close = closes[form]
        let escapes = language.strings[form].escapes
        var i = from
        while i < c.count {
            if escapes, c[i] == "\\" {
                i += 2
                continue
            }
            if matches(c, close, at: i) { return i + close.count }
            i += 1
        }
        return nil
    }

    private func matches(_ c: [Character], _ token: [Character], at i: Int) -> Bool {
        guard !token.isEmpty, i + token.count <= c.count else { return false }
        for k in 0..<token.count where c[i + k] != token[k] { return false }
        return true
    }

    private func isIdentifierStart(_ ch: Character) -> Bool {
        ch == "_" || ch == "$" || ch.isLetter
    }

    private func isIdentifier(_ ch: Character) -> Bool {
        ch == "_" || ch == "$" || ch.isLetter || ch.isNumber
    }
}

extension CodeLanguage {
    public static let swift = CodeLanguage(
        keywords: [
            "func", "let", "var", "if", "else", "guard", "return", "for", "while", "repeat",
            "switch", "case", "default", "break", "continue", "fallthrough", "import", "struct",
            "class", "enum", "protocol", "extension", "init", "deinit", "subscript", "self",
            "Self", "super", "nil", "true", "false", "try", "catch", "throw", "throws",
            "rethrows", "async", "await", "public", "private", "internal", "fileprivate", "open",
            "static", "final", "lazy", "weak", "unowned", "where", "as", "is", "in", "inout",
            "defer", "typealias", "associatedtype", "some", "any", "mutating", "nonmutating",
            "override", "convenience", "required", "operator", "do", "consuming", "borrowing",
            "nonisolated", "isolated", "actor", "macro", "package", "get", "set", "willSet",
            "didSet",
        ],
        lineComments: ["//"],
        blockComment: ("/*", "*/"), nestedComments: true,
        strings: [
            // Raw forms first: `#"` starts with neither `"""` nor `"`.
            .init("#\"\"\"", "\"\"\"#", multiline: true, escapes: false),
            .init("#\"", "\"#", escapes: false),
            .init("\"\"\"", "\"\"\"", multiline: true),
            .init("\"", "\""),
        ],
        attributeMarks: ["@", "#"]
    )

    public static let c = CodeLanguage(
        keywords: [
            "auto", "break", "case", "char", "const", "continue", "default", "do", "double",
            "else", "enum", "extern", "float", "for", "goto", "if", "inline", "int", "long",
            "register", "restrict", "return", "short", "signed", "sizeof", "static", "struct",
            "switch", "typedef", "union", "unsigned", "void", "volatile", "while", "bool", "true",
            "false", "nullptr", "NULL", "class", "namespace", "template", "typename", "public",
            "private", "protected", "virtual", "override", "final", "new", "delete", "this",
            "using", "constexpr", "consteval", "constinit", "noexcept", "static_cast",
            "dynamic_cast", "reinterpret_cast", "const_cast", "operator", "friend", "explicit",
            "mutable", "try", "catch", "throw", "co_await", "co_return", "co_yield", "concept",
            "requires", "decltype", "static_assert", "thread_local", "alignas", "alignof",
        ],
        lineComments: ["//"],
        blockComment: ("/*", "*/"),
        strings: [.init("\"", "\""), .init("'", "'")],
        preprocessor: true
    )

    public static let javascript = CodeLanguage(
        keywords: [
            "function", "const", "let", "var", "if", "else", "for", "while", "do", "break",
            "continue", "return", "class", "extends", "new", "delete", "typeof", "instanceof",
            "this", "super", "import", "export", "from", "default", "try", "catch", "finally",
            "throw", "switch", "case", "null", "undefined", "true", "false", "async", "await",
            "yield", "of", "in", "static", "get", "set", "interface", "type", "implements",
            "enum", "readonly", "as", "void",
        ],
        lineComments: ["//"],
        blockComment: ("/*", "*/"),
        strings: [
            .init("`", "`", multiline: true),
            .init("\"", "\""),
            .init("'", "'"),
        ],
        attributeMarks: ["@"]
    )

    public static let python = CodeLanguage(
        keywords: [
            "def", "class", "if", "elif", "else", "for", "while", "break", "continue", "return",
            "import", "from", "as", "pass", "raise", "try", "except", "finally", "with", "lambda",
            "global", "nonlocal", "assert", "del", "yield", "and", "or", "not", "in", "is",
            "None", "True", "False", "async", "await", "self", "match", "case",
        ],
        lineComments: ["#"],
        strings: [
            .init("\"\"\"", "\"\"\"", multiline: true),
            .init("'''", "'''", multiline: true),
            .init("\"", "\""),
            .init("'", "'"),
        ],
        attributeMarks: ["@"]
    )
}
