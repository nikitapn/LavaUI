import XCTest
@testable import LavaText

final class CodeLexerTests: XCTestCase {
    private let k = CodeLexer.keyword
    private let s = CodeLexer.string
    private let c = CodeLexer.comment
    private let n = CodeLexer.number
    private let t = CodeLexer.type

    /// Lexes `lines` in order, as the editor does, and renders each line's
    /// spans as the styled text: `"let x = 1"` → `["k:let", "n:1"]`.
    private func lex(_ language: CodeLanguage, _ lines: [String]) -> [[String]] {
        let lexer = CodeLexer(language)
        var state = CodeLexer.initialState
        return lines.map { line in
            let (spans, next) = lexer.highlight(line, state: state)
            state = next
            let chars = Array(line)
            return spans.map { span in
                let tag = ["k", "s", "c", "n", "t"][span.styleIndex]
                return "\(tag):" + String(chars[span.range])
            }
        }
    }

    func testSwiftKeywordsTypesNumbersAttributes() {
        XCTAssertEqual(lex(.swift, ["@MainActor let count: Int = 42"]), [
            ["t:@MainActor", "k:let", "t:Int", "n:42"],
        ])
        XCTAssertEqual(lex(.swift, ["#if DEBUG"]), [["t:#if", "t:DEBUG"]])
    }

    func testSwiftNestedBlockCommentSpansLines() {
        let lines = ["let a = 1 /* outer", "/* inner */ still comment", "end */ return"]
        XCTAssertEqual(lex(.swift, lines), [
            ["k:let", "n:1", "c:/* outer"],
            ["c:/* inner */ still comment"],
            ["c:end */", "k:return"],
        ])
    }

    func testCCommentsDoNotNest() {
        XCTAssertEqual(lex(.c, ["/* /* */ int x;"]), [["c:/* /* */", "k:int"]])
    }

    func testSwiftMultilineStringKeepsKeywordsAsString() {
        let lines = ["let s = \"\"\"", "    return if while", "    \"\"\" + x"]
        XCTAssertEqual(lex(.swift, lines), [
            ["k:let", "s:\"\"\""],
            ["s:    return if while"],
            ["s:    \"\"\""],
        ])
    }

    func testRawStringBackslashDoesNotEscape() {
        // In `#"a\"#` the backslash is a character, so `"#` closes it.
        XCTAssertEqual(lex(.swift, [##"let r = #"a\"# + 1"##]), [["k:let", ##"s:#"a\"#"##, "n:1"]])
    }

    func testEscapedQuoteStaysInsideString() {
        XCTAssertEqual(lex(.swift, [#"x = "a\"b" // tail"#]), [[#"s:"a\"b""#, "c:// tail"]])
    }

    func testCommentMarkerInsideStringIsString() {
        XCTAssertEqual(lex(.javascript, [#"const u = "http://x"; // real"#]), [
            ["k:const", #"s:"http://x""#, "c:// real"],
        ])
    }

    func testUnterminatedSingleLineStringEndsWithItsLine() {
        XCTAssertEqual(lex(.c, ["char *s = \"open", "int y;"]), [
            ["k:char", "s:\"open"],
            ["k:int"],
        ])
    }

    func testPythonTripleQuotedDocstring() {
        let lines = ["def f():", "    '''Doc", "    if not this'''", "    return None"]
        XCTAssertEqual(lex(.python, lines), [
            ["k:def"],
            ["s:'''Doc"],
            ["s:    if not this'''"],
            ["k:return", "k:None"],
        ])
    }

    func testJavaScriptTemplateSpansLines() {
        XCTAssertEqual(lex(.javascript, ["const q = `select", "from t`;"]), [
            ["k:const", "s:`select"],
            ["s:from t`"],
        ])
    }

    func testPreprocessorDirective() {
        XCTAssertEqual(lex(.c, ["  #include <stdio.h>", "x = a # b"]), [
            ["t:#include"],
            [],
        ])
    }

    func testNumbers() {
        XCTAssertEqual(lex(.swift, ["for i in 1..<5 {}"]), [["k:for", "k:in", "n:1", "n:5"]])
        XCTAssertEqual(lex(.c, ["d = 1.5e-9 + 0x1Fu - 1_000;"]), [["n:1.5e-9", "n:0x1Fu", "n:1_000"]])
        XCTAssertEqual(lex(.c, ["h = 0xE-1;"]), [["n:0xE", "n:1"]])
        XCTAssertEqual(lex(.c, ["v2 = x2;"]), [[]], "digits inside identifiers are not numbers")
    }

    func testCharacterOffsetsNotBytes() {
        let lexer = CodeLexer(.swift)
        let (spans, _) = lexer.highlight("let é = \"ü\"", state: .code)
        XCTAssertEqual(spans.map(\.range), [0..<3, 8..<11])
    }

    /// Through `SyntaxHighlighter.Cache`, as the editor uses it: opening a
    /// comment on one line recolours the lines below, and closing it again
    /// puts them back.
    func testCacheRecolorsLinesBelowAnEdit() {
        let highlighter = SyntaxHighlighter(lexer: CodeLexer(.swift), identity: "swift")
        var cache = SyntaxHighlighter.Cache()
        var lines: [Substring] = ["let a = 1", "let b = 2", "let c = 3"]
        cache.update(lines: lines, with: highlighter)
        XCTAssertEqual(cache.spans(atRow: 2).first?.styleIndex, k)

        lines[0] = "let a = 1 /*"
        cache.update(lines: lines, with: highlighter)
        XCTAssertEqual(cache.spans(atRow: 2), [HighlightSpan(range: 0..<9, styleIndex: c)])

        lines[0] = "let a = 1"
        cache.update(lines: lines, with: highlighter)
        XCTAssertEqual(cache.spans(atRow: 2).first?.styleIndex, k)
    }

    func testIdentityTellsLanguagesApart() {
        let swift = SyntaxHighlighter(lexer: CodeLexer(.swift), identity: "swift")
        let c = SyntaxHighlighter(lexer: CodeLexer(.c), identity: "c")
        let rules = SyntaxHighlighter(rules: [HighlightRule(pattern: "x", styleIndex: 0)])
        XCTAssertNotEqual(swift.identity, c.identity)
        XCTAssertNotEqual(swift.identity, rules.identity)
        XCTAssertEqual(
            rules.identity,
            SyntaxHighlighter(rules: [HighlightRule(pattern: "x", styleIndex: 0)]).identity
        )
    }
}
