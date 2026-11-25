import Foundation
import LavaEditorSyntax
import LavaText
import LavaUI

/// What a file is written in, chosen from its extension.
///
/// Extension only, deliberately: content sniffing gets a shebang right and a
/// header file wrong, and being wrong about a file the user named `.py` is
/// worse than being plain about one they named nothing. `plain` is a real
/// answer here, not a failure — a text editor's most common document has no
/// syntax at all.
enum Language: String, CaseIterable {
    case plain, swift, c, python, javascript, json, markdown, shell, yaml, toml, ini

    /// What the status bar calls it.
    var title: String {
        switch self {
        case .plain: return "Plain Text"
        case .swift: return "Swift"
        case .c: return "C / C++"
        case .python: return "Python"
        case .javascript: return "JavaScript"
        case .json: return "JSON"
        case .markdown: return "Markdown"
        case .shell: return "Shell"
        case .yaml: return "YAML"
        case .toml: return "TOML"
        case .ini: return "INI"
        }
    }

    static func of(_ url: URL?) -> Language {
        guard let url else { return .plain }
        switch url.pathExtension.lowercased() {
        case "swift": return .swift
        case "c", "h", "cc", "cpp", "cxx", "c++", "hpp", "hh", "hxx", "ipp", "inl", "m", "mm": return .c
        case "py", "pyw": return .python
        case "js", "mjs", "ts", "jsx", "tsx": return .javascript
        case "json": return .json
        case "md", "markdown": return .markdown
        case "sh", "bash", "zsh", "fish": return .shell
        case "yaml", "yml": return .yaml
        case "toml": return .toml
        case "ini", "conf", "cfg", "desktop": return .ini
        default:
            // Files that are known by name rather than by suffix. A Makefile
            // has no extension at all and neither does a dotfile.
            switch url.lastPathComponent.lowercased() {
            case "makefile", "dockerfile": return .shell
            case ".bashrc", ".zshrc", ".profile", ".bash_profile": return .shell
            case "meson.build": return .python
            default: return .plain
            }
        }
    }

    /// What colours a document in this language.
    ///
    /// The languages with comments and strings that span lines — Swift's
    /// nested `/* */` and `"""`, C's `/* */`, Python's `"""`, JavaScript's
    /// template strings — get `CodeLexer`, which carries that state from line
    /// to line. The rest are coloured one line at a time by `rules`, which is
    /// all YAML or an INI file needs.
    var highlighter: SyntaxHighlighter {
        // Built per call: a `CodeLexer` is a few small arrays, and a
        // highlighter is not `Sendable`, so it cannot be a shared static.
        switch self {
        case .swift: return SyntaxHighlighter(lexer: CodeLexer(.swift), identity: "swift")
        case .c: return SyntaxHighlighter(lexer: CodeLexer(.c), identity: "c")
        case .javascript:
            return SyntaxHighlighter(lexer: CodeLexer(.javascript), identity: "javascript")
        case .python: return SyntaxHighlighter(lexer: CodeLexer(.python), identity: "python")
        default: return SyntaxHighlighter(rules: rules)
        }
    }

    func indentationLanguageID(for url: URL?) -> String {
        guard self == .c else { return rawValue }
        let ext = url?.pathExtension ?? ""
        switch ext.lowercased() {
        case "m", "mm": return "objective-c"
        case "c": return ext == "C" ? "cpp" : "c"
        // Shared headers use the C++ grammar, as they do for clangd.
        default: return "cpp"
        }
    }

    /// The grammar `SyntaxDocument` parses this as, or nil for none.
    func syntaxLanguage(for url: URL?) -> SyntaxDocument.Language? {
        switch indentationLanguageID(for: url) {
        case "swift": return SyntaxDocument.hasSwiftParser ? .swift : nil
        case "python": return .python
        case "c": return .c
        case "cpp": return .cpp
        default: return nil
        }
    }

    func indentation(using syntax: SyntaxDocument, url: URL?) -> EditorIndentation {
        guard let language = syntaxLanguage(for: url) else {
            return indentationLanguageID(for: url) == "swift" ? .braces : .inherit
        }
        return .provider { request in
            syntax.indentation(for: request.editing, at: request.caret, language: language, unit: request.unit)
        }
    }

    /// Rules for `SyntaxHighlighter`, ordered by nothing — `priority` decides
    /// what wins where two match the same characters. Applied one line at a
    /// time; the languages that need more than that use `highlighter`.
    var rules: [HighlightRule] {
        switch self {
        case .plain:
            return []
        case .swift:
            return Self.common(
                keywords: """
                    func|let|var|if|else|guard|return|for|while|repeat|switch|case|default|\
                    break|continue|import|struct|class|enum|protocol|extension|init|deinit|\
                    self|super|nil|true|false|try|catch|throw|throws|rethrows|async|await|\
                    public|private|internal|fileprivate|open|static|final|lazy|weak|unowned|\
                    where|as|is|in|inout|defer|typealias|associatedtype|some|any|mutating
                    """,
                lineComment: "//")
        case .c:
            return Self.common(
                keywords: """
                    auto|break|case|char|const|continue|default|do|double|else|enum|extern|\
                    float|for|goto|if|inline|int|long|register|restrict|return|short|signed|\
                    sizeof|static|struct|switch|typedef|union|unsigned|void|volatile|while|\
                    bool|true|false|nullptr|class|namespace|template|typename|public|private|\
                    protected|virtual|override|new|delete|this|using|constexpr|noexcept|auto
                    """,
                lineComment: "//",
                extra: [
                    // Preprocessor lines, which are neither keyword nor comment
                    // and read as neither without this.
                    HighlightRule(pattern: "^\\s*#\\s*\\w+", styleIndex: HighlightName.type, priority: 5)
                ])
        case .python:
            return Self.common(
                keywords: """
                    def|class|if|elif|else|for|while|break|continue|return|import|from|as|\
                    pass|raise|try|except|finally|with|lambda|global|nonlocal|assert|del|\
                    yield|and|or|not|in|is|None|True|False|async|await|self
                    """,
                lineComment: "#")
        case .javascript:
            return Self.common(
                keywords: """
                    function|const|let|var|if|else|for|while|do|break|continue|return|class|\
                    extends|new|delete|typeof|instanceof|this|super|import|export|from|default|\
                    try|catch|finally|throw|switch|case|null|undefined|true|false|async|await|\
                    yield|of|in|static|get|set
                    """,
                lineComment: "//")
        case .json:
            return [
                HighlightRule(pattern: "\"(\\\\.|[^\"\\\\])*\"\\s*:", styleIndex: HighlightName.type, priority: 3),
                HighlightRule(pattern: "\"(\\\\.|[^\"\\\\])*\"", styleIndex: HighlightName.string, priority: 2),
                HighlightRule(pattern: "\\b(true|false|null)\\b", styleIndex: HighlightName.keyword, priority: 1),
                HighlightRule(pattern: "\\b-?\\d+(\\.\\d+)?([eE][-+]?\\d+)?\\b", styleIndex: HighlightName.number),
            ]
        case .markdown:
            return [
                HighlightRule(pattern: "^#{1,6}\\s.*$", styleIndex: HighlightName.keyword, priority: 3),
                HighlightRule(pattern: "^\\s*([-*+]|\\d+\\.)\\s", styleIndex: HighlightName.type, priority: 2),
                HighlightRule(pattern: "`[^`]*`", styleIndex: HighlightName.string, priority: 2),
                HighlightRule(pattern: "\\*\\*[^*]+\\*\\*", styleIndex: HighlightName.number, priority: 1),
                HighlightRule(pattern: "^>\\s.*$", styleIndex: HighlightName.comment, priority: 1),
            ]
        case .shell:
            return Self.common(
                keywords: """
                    if|then|elif|else|fi|for|while|until|do|done|case|esac|function|return|\
                    exit|export|local|readonly|source|shift|break|continue|in|select|time
                    """,
                lineComment: "#",
                extra: [
                    HighlightRule(pattern: "\\$\\{?\\w+\\}?", styleIndex: HighlightName.type, priority: 2)
                ])
        case .yaml:
            return [
                HighlightRule(pattern: "#.*$", styleIndex: HighlightName.comment, priority: 10),
                HighlightRule(pattern: "^\\s*[-\\w.]+\\s*:", styleIndex: HighlightName.type, priority: 3),
                HighlightRule(pattern: "\"(\\\\.|[^\"\\\\])*\"|'[^']*'", styleIndex: HighlightName.string, priority: 2),
                HighlightRule(pattern: "\\b(true|false|null|yes|no)\\b", styleIndex: HighlightName.keyword, priority: 1),
                HighlightRule(pattern: "\\b-?\\d+(\\.\\d+)?\\b", styleIndex: HighlightName.number),
            ]
        case .toml, .ini:
            return [
                HighlightRule(pattern: "[#;].*$", styleIndex: HighlightName.comment, priority: 10),
                HighlightRule(pattern: "^\\s*\\[.+\\]\\s*$", styleIndex: HighlightName.keyword, priority: 4),
                HighlightRule(pattern: "^\\s*[\\w.\\-\"]+\\s*=", styleIndex: HighlightName.type, priority: 3),
                HighlightRule(pattern: "\"(\\\\.|[^\"\\\\])*\"|'[^']*'", styleIndex: HighlightName.string, priority: 2),
                HighlightRule(pattern: "\\b(true|false)\\b", styleIndex: HighlightName.keyword, priority: 1),
                HighlightRule(pattern: "\\b-?\\d+(\\.\\d+)?\\b", styleIndex: HighlightName.number),
            ]
        }
    }

    /// The shape nearly every curly-brace language shares. Only the keyword
    /// list and the comment marker actually differ, so only those are asked
    /// for — six near-identical rule arrays would drift apart the first time
    /// one of them was improved.
    private static func common(
        keywords: String, lineComment: String, extra: [HighlightRule] = []
    ) -> [HighlightRule] {
        let marker = NSRegularExpression.escapedPattern(for: lineComment)
        return [
            // Highest, because a keyword inside a comment is a comment. The
            // reverse ordering is the classic way to get `// return early`
            // half-coloured.
            HighlightRule(pattern: "\(marker).*$", styleIndex: HighlightName.comment, priority: 10),
            HighlightRule(
                pattern: "\"(\\\\.|[^\"\\\\])*\"|'(\\\\.|[^'\\\\])*'",
                styleIndex: HighlightName.string, priority: 8
            ),
            HighlightRule(pattern: "\\b(\(keywords))\\b", styleIndex: HighlightName.keyword, priority: 4),
            // Capitalised words as a stand-in for types: no rule list can know
            // what a type is, and in every language here the convention holds
            // often enough to be worth more than nothing.
            HighlightRule(pattern: "\\b[A-Z][A-Za-z0-9_]*\\b", styleIndex: HighlightName.type, priority: 2),
            HighlightRule(
                pattern: "\\b-?\\d+(\\.\\d+)?([eE][-+]?\\d+)?\\b", styleIndex: HighlightName.number, priority: 1
            ),
        ] + extra
    }

    /// Colours by `HighlightName`. Only names whose colour differs from
    /// their parent's are listed: `function.method` is `function`'s colour,
    /// `constant.builtin` is `constant`'s, and a name with nothing coloured
    /// above it — `variable`, `operator`, `punctuation` — is plain text, so
    /// that the names that do say something are not buried under the ones
    /// that do not. The names past `property` are what tree-sitter's
    /// highlight queries capture; the lexer and the language servers never
    /// produce them.
    static func codeStyle(theme: Theme) -> CodeStyle {
        if theme.inset.luminance > 0.5 {
            let keyword = Color(rgb24: 0x72_43_89)
            let number = Color(rgb24: 0x8e_47_20)
            let type = Color(rgb24: 0x23_5c_73)
            return CodeStyle(
                text: theme.textPrimary,
                searchMatch: Color(rgb24: 0xf1_e0_ab),
                currentSearchMatch: Color(rgb24: 0xf3_c9_a5),
                colors: [
                    "keyword": keyword,
                    "string": Color(rgb24: 0x4b_61_31),
                    "comment": Color(rgb24: 0x6b_62_54),
                    "number": number,
                    "type": type,
                    "function": Color(rgb24: 0x7a_5a_12),
                    "variable.parameter": Color(rgb24: 0x9a_4a_2e),
                    "property": Color(rgb24: 0x2d_6a_5a),
                    "constant": number,
                    "escape": number,
                    "variable.builtin": keyword,
                    "constructor": type,
                    "namespace": type,
                    "attribute": type,
                ]
            )
        }
        let keyword = Color(r: 0.78, g: 0.52, b: 0.90)
        let number = Color(r: 0.90, g: 0.68, b: 0.40)
        let type = Color(r: 0.40, g: 0.72, b: 0.92)
        return CodeStyle(
            text: theme.textPrimary,
            colors: [
                "keyword": keyword,
                "string": Color(r: 0.60, g: 0.80, b: 0.45),
                "comment": Color(r: 0.45, g: 0.50, b: 0.58),
                "number": number,
                "type": type,
                "function": Color(r: 0.88, g: 0.80, b: 0.52),
                "variable.parameter": Color(r: 0.92, g: 0.62, b: 0.55),
                "property": Color(r: 0.55, g: 0.82, b: 0.80),
                "constant": number,
                "escape": number,
                "variable.builtin": keyword,
                "constructor": type,
                "namespace": type,
                "attribute": type,
            ]
        )
    }
}

