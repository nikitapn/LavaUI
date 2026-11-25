import Foundation
import LavaText
import XCTest

@testable import LavaEditorSyntax

final class HighlightTests: XCTestCase {
    func testHighlightQueriesCompileForEveryGrammar() {
        XCTAssertNotNil(Grammar.c.highlights)
        XCTAssertNotNil(Grammar.cpp.highlights)
        XCTAssertNotNil(Grammar.python.highlights)
    }

    func testCTokensTakeTheirCaptureNames() {
        let names = highlighted("int run(int x) {\n    // note\n    return x + 42; /* c */\n}\n", .c)
        XCTAssertEqual(names[0]["int"], "type")
        XCTAssertEqual(names[0]["run"], "function")
        XCTAssertEqual(names[1]["// note"], "comment")
        XCTAssertEqual(names[2]["return"], "keyword")
        XCTAssertEqual(names[2]["42"], "number")
        XCTAssertEqual(names[2]["/* c */"], "comment")
    }

    func testAnEscapeInsideAStringIsItsOwnSpan() {
        let names = highlighted(#"char *s = "a\nb";"#, .c)
        XCTAssertEqual(names[0][#"\n"#], "escape", "inside its string")
        XCTAssertEqual(names[0][#""a"#], "string")
        XCTAssertEqual(names[0][#"b""#], "string")
    }

    func testTheLastPatternForANodeWinsAndPredicatesAreEvaluated() {
        let names = highlighted("print(Widget(), CONSTANT, value)\nobj.attr = Widget\n", .python)
        // `(identifier) @variable` comes first in the file; these come later.
        XCTAssertEqual(names[0]["print"], "function.builtin")
        XCTAssertEqual(names[1]["Widget"], "constructor", "#match? ^[A-Z]")
        // The call pattern comes after the constructor one, so a called
        // `Widget` is a function — as tree-sitter's own highlighter has it.
        XCTAssertEqual(names[0]["Widget"], "function")
        XCTAssertEqual(names[0]["CONSTANT"], "constant", "#match? ^[A-Z][A-Z_]*$")
        XCTAssertEqual(names[0]["value"], "variable", "matches no later pattern")
        XCTAssertEqual(names[1]["attr"], "property")
    }

    func testOurAdditionsToTheGrammarsFiles() {
        let python = highlighted("def f(self):\n    return cls\n", .python)
        XCTAssertEqual(python[0]["self"], "variable.builtin", "#any-of?")
        XCTAssertEqual(python[1]["cls"], "variable.builtin")
        let c = highlighted("bool b = true; void *p = NULL;\n", .c)
        XCTAssertEqual(c[0]["true"], "constant.builtin")
    }

    func testCppAddsToC() {
        let names = highlighted("namespace demo { class Widget { public: bool ok = true; }; }\n", .cpp)
        XCTAssertEqual(names[0]["namespace"], "keyword")
        XCTAssertEqual(names[0]["true"], "constant.builtin", "our addition to C's file, inherited")
        XCTAssertEqual(names[0]["bool"], "type", "C's rule, inherited")
    }

    func testColumnsAreCharactersNotBytes() {
        let names = highlighted("s = \"café 🍎\"; x = 1\n", .python)
        XCTAssertEqual(names[0]["\"café 🍎\""], "string")
        XCTAssertEqual(names[0]["1"], "number")
    }

    func testTheSourceFollowsEditsAndSaysWhenItHasMore() {
        let document = SyntaxDocument(answerTimeout: .seconds(10), highlightWait: 10)
        var state = TextEditingState("int x;\n")
        document.follow(state, language: .c)
        final class Flag: @unchecked Sendable { var count = 0; let lock = NSLock() }
        let flag = Flag()
        document.highlightsChanged = { flag.lock.lock(); flag.count += 1; flag.lock.unlock() }

        var layer = document.highlights(for: state, lines: 0..<1)
        XCTAssertEqual(layer?.revision, state.revision)
        XCTAssertFalse(document.hasUndrawnHighlights, "the layer just drawn is the newest")

        state.setCursor(state.text.endIndex)
        state.insert("// done\n")
        layer = document.highlights(for: state, lines: 0..<2)
        XCTAssertEqual(layer?.revision, state.revision, "drawing waits for the revision on screen")
        XCTAssertEqual(layer.map { names(in: $0, line: 1, of: state.text) }?["// done"], "comment")
        flag.lock.lock(); defer { flag.lock.unlock() }
        XCTAssertGreaterThan(flag.count, 0)
    }

    func testSwiftTakesTheCompilersClassification() throws {
        try XCTSkipUnless(SyntaxDocument.highlights(.swift))
        let names = highlighted(
            "@MainActor\nstruct S: Equatable {\n    /// Doc.\n    let x: Int = 4.2 // note\n"
                + "    func f() -> String { \"a\\(x)b\" + \"\\($0)\" }\n}\n#if DEBUG\nlet café = [1: \"é\"]\n#endif\n",
            .swift
        )
        XCTAssertEqual(names[0]["@MainActor"], "attribute")
        XCTAssertEqual(names[1]["struct"], "keyword")
        XCTAssertEqual(names[1]["Equatable"], "type")
        XCTAssertNil(names[1]["S"], "a declared name is an identifier to the classifier: plain")
        XCTAssertEqual(names[2]["/// Doc."], "comment.documentation")
        XCTAssertEqual(names[3]["Int"], "type")
        XCTAssertEqual(names[3]["4.2"], "number")
        XCTAssertEqual(names[3]["// note"], "comment")
        XCTAssertEqual(names[4]["\"a"], "string")
        XCTAssertEqual(names[4]["b\""], "string", "the interpolation between is code")
        XCTAssertEqual(names[4]["$0"], "variable.builtin")
        XCTAssertEqual(names[6]["#if"], "keyword.directive")
        XCTAssertEqual(names[7]["\"é\""], "string", "columns after a multi-byte character")
        XCTAssertEqual(names[8]["#endif"], "keyword.directive")

        // Identifiers to the classifier, but not to a reader.
        let more = highlighted("import Foundation.NSString\nprivate(set) var count = 0\n", .swift)
        XCTAssertEqual(more[0]["Foundation"], "namespace")
        XCTAssertEqual(more[0]["NSString"], "namespace")
        XCTAssertEqual(more[1]["set"], "keyword")
        XCTAssertNil(more[1]["count"])
    }

    func testSwiftHighlightsFollowEdits() throws {
        try XCTSkipUnless(SyntaxDocument.highlights(.swift))
        let document = SyntaxDocument(answerTimeout: .seconds(10), highlightWait: 10)
        var state = TextEditingState("let a = 1\n")
        document.follow(state, language: .swift)
        _ = document.highlights(for: state, lines: 0..<2)
        state.setCursor(state.text.endIndex)
        state.insert("var b: String = \"x\"")
        let layer = document.highlights(for: state, lines: 0..<2)
        XCTAssertEqual(layer?.revision, state.revision)
        XCTAssertEqual(layer.map { names(in: $0, line: 1, of: state.text) }?["String"], "type")
        XCTAssertEqual(document.fullParses, 1, "followed, not reparsed whole")
    }

    func testAStaleLayerKeepsLinesWhoseTextIsUnchanged() {
        let line = HighlightLayer.Line(text: "int x;", spans: [HighlightSpan(range: 0..<3, styleIndex: HighlightName.type)])
        let layer = HighlightLayer(revision: 1, lineCount: 3, lines: [1: line])
        XCTAssertEqual(layer.spans(forLine: 1, revision: 1, lineCount: 3, text: { "anything" }), line.spans)
        XCTAssertEqual(layer.spans(forLine: 1, revision: 2, lineCount: 3, text: { "int x;" }), line.spans)
        XCTAssertNil(layer.spans(forLine: 1, revision: 2, lineCount: 3, text: { "int xy;" }), "edited: lexer")
        XCTAssertEqual(layer.spans(forLine: 2, revision: 2, lineCount: 4, text: { "int x;" }), line.spans, "moved down a line")
        XCTAssertNil(layer.spans(forLine: 0, revision: 1, lineCount: 3, text: { "" }), "not covered")
    }

    // MARK: Helpers

    /// For each line, the text of each span and the name it took.
    private func highlighted(_ text: String, _ language: SyntaxDocument.Language) -> [[String: String]] {
        let document = SyntaxDocument(answerTimeout: .seconds(10), highlightWait: 10)
        let state = TextEditingState(text)
        document.follow(state, language: language)
        let count = text.split(separator: "\n", omittingEmptySubsequences: false).count
        guard let layer = document.highlights(for: state, lines: 0..<count) else {
            XCTFail("no layer")
            return []
        }
        return (0..<count).map { names(in: layer, line: $0, of: text) }
    }

    private func names(in layer: HighlightLayer, line: Int, of text: String) -> [String: String] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let entry = layer.lines[line] else { return [:] }
        let characters = Array(lines[line])
        var result: [String: String] = [:]
        for span in entry.spans {
            result[String(characters[span.range])] = HighlightName.name(at: span.styleIndex)
        }
        return result
    }
}
