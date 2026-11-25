import Foundation
import LavaEditorIndentation
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

    func indentation(using provider: IndentationProvider, url: URL?) -> EditorIndentation {
        let parser: IndentationProvider.Language
        switch indentationLanguageID(for: url) {
        case "swift":
            guard IndentationProvider.hasSwiftParser else { return .braces }
            parser = .swift
        case "python": parser = .python
        case "c": parser = .c
        case "cpp": parser = .cpp
        default:
            return .inherit
        }
        return .provider { text, caret, unit in
            provider.indentation(in: text, at: caret, language: parser, unit: unit)
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
                    HighlightRule(pattern: "^\\s*#\\s*\\w+", styleIndex: 4, priority: 5)
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
                HighlightRule(pattern: "\"(\\\\.|[^\"\\\\])*\"\\s*:", styleIndex: 4, priority: 3),
                HighlightRule(pattern: "\"(\\\\.|[^\"\\\\])*\"", styleIndex: 1, priority: 2),
                HighlightRule(pattern: "\\b(true|false|null)\\b", styleIndex: 0, priority: 1),
                HighlightRule(pattern: "\\b-?\\d+(\\.\\d+)?([eE][-+]?\\d+)?\\b", styleIndex: 3),
            ]
        case .markdown:
            return [
                HighlightRule(pattern: "^#{1,6}\\s.*$", styleIndex: 0, priority: 3),
                HighlightRule(pattern: "^\\s*([-*+]|\\d+\\.)\\s", styleIndex: 4, priority: 2),
                HighlightRule(pattern: "`[^`]*`", styleIndex: 1, priority: 2),
                HighlightRule(pattern: "\\*\\*[^*]+\\*\\*", styleIndex: 3, priority: 1),
                HighlightRule(pattern: "^>\\s.*$", styleIndex: 2, priority: 1),
            ]
        case .shell:
            return Self.common(
                keywords: """
                    if|then|elif|else|fi|for|while|until|do|done|case|esac|function|return|\
                    exit|export|local|readonly|source|shift|break|continue|in|select|time
                    """,
                lineComment: "#",
                extra: [
                    HighlightRule(pattern: "\\$\\{?\\w+\\}?", styleIndex: 4, priority: 2)
                ])
        case .yaml:
            return [
                HighlightRule(pattern: "#.*$", styleIndex: 2, priority: 10),
                HighlightRule(pattern: "^\\s*[-\\w.]+\\s*:", styleIndex: 4, priority: 3),
                HighlightRule(pattern: "\"(\\\\.|[^\"\\\\])*\"|'[^']*'", styleIndex: 1, priority: 2),
                HighlightRule(pattern: "\\b(true|false|null|yes|no)\\b", styleIndex: 0, priority: 1),
                HighlightRule(pattern: "\\b-?\\d+(\\.\\d+)?\\b", styleIndex: 3),
            ]
        case .toml, .ini:
            return [
                HighlightRule(pattern: "[#;].*$", styleIndex: 2, priority: 10),
                HighlightRule(pattern: "^\\s*\\[.+\\]\\s*$", styleIndex: 0, priority: 4),
                HighlightRule(pattern: "^\\s*[\\w.\\-\"]+\\s*=", styleIndex: 4, priority: 3),
                HighlightRule(pattern: "\"(\\\\.|[^\"\\\\])*\"|'[^']*'", styleIndex: 1, priority: 2),
                HighlightRule(pattern: "\\b(true|false)\\b", styleIndex: 0, priority: 1),
                HighlightRule(pattern: "\\b-?\\d+(\\.\\d+)?\\b", styleIndex: 3),
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
            HighlightRule(pattern: "\(marker).*$", styleIndex: 2, priority: 10),
            HighlightRule(
                pattern: "\"(\\\\.|[^\"\\\\])*\"|'(\\\\.|[^'\\\\])*'",
                styleIndex: 1, priority: 8
            ),
            HighlightRule(pattern: "\\b(\(keywords))\\b", styleIndex: 0, priority: 4),
            // Capitalised words as a stand-in for types: no rule list can know
            // what a type is, and in every language here the convention holds
            // often enough to be worth more than nothing.
            HighlightRule(pattern: "\\b[A-Z][A-Za-z0-9_]*\\b", styleIndex: 4, priority: 2),
            HighlightRule(
                pattern: "\\b-?\\d+(\\.\\d+)?([eE][-+]?\\d+)?\\b", styleIndex: 3, priority: 1
            ),
        ] + extra
    }

    /// Colours for the style indices the rules above use.
    static func codeStyle(theme: Theme) -> CodeStyle {
        if theme.inset.luminance > 0.5 {
            return CodeStyle(
                text: theme.textPrimary,
                searchMatch: Color(rgb24: 0xf1_e0_ab),
                currentSearchMatch: Color(rgb24: 0xf3_c9_a5),
                palette: [
                    Color(rgb24: 0x72_43_89),  // keyword
                    Color(rgb24: 0x4b_61_31),  // string
                    Color(rgb24: 0x6b_62_54),  // comment
                    Color(rgb24: 0x8e_47_20),  // number
                    Color(rgb24: 0x23_5c_73),  // type / key
                    Color(rgb24: 0x7a_5a_12),  // function (language server)
                    Color(rgb24: 0x9a_4a_2e),  // parameter (language server)
                    Color(rgb24: 0x2d_6a_5a),  // property / member (language server)
                ]
            )
        }
        return CodeStyle(
            text: theme.textPrimary,
            palette: [
                Color(r: 0.78, g: 0.52, b: 0.90),  // 0 keyword
                Color(r: 0.60, g: 0.80, b: 0.45),  // 1 string
                Color(r: 0.45, g: 0.50, b: 0.58),  // 2 comment
                Color(r: 0.90, g: 0.68, b: 0.40),  // 3 number
                Color(r: 0.40, g: 0.72, b: 0.92),  // 4 type / key
                // From here only a language server colours: the lexer cannot
                // tell a call from any other identifier.
                Color(r: 0.88, g: 0.80, b: 0.52),  // 5 function
                Color(r: 0.92, g: 0.62, b: 0.55),  // 6 parameter
                Color(r: 0.55, g: 0.82, b: 0.80),  // 7 property / member
            ]
        )
    }
}
