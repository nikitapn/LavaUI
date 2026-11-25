import LavaText
import XCTest

@testable import LavaEditorSyntax

/// The tree follows the buffer through `TextEditingState`'s splices, and what
/// it ends up with is what a parse from nothing would give.
final class IncrementalSyncTests: XCTestCase {
    func testQueriesCompileForEveryGrammar() {
        XCTAssertNotNil(Grammar.c.indents)
        XCTAssertNotNil(Grammar.cpp.indents)
        XCTAssertNotNil(Grammar.python.indents)
    }

    func testCTreeFollowsEditsWithoutReparsing() {
        assertFollows(
            "int main(void) {\n    run();\n}\n", language: .c,
            edits: [(27, 0, "    if (x) {\n        y();\n    }\n"), (4, 4, "start"), (0, 0, "// café\n"),
                    (10, 3, ""), (20, 0, "é\n🍎")]
        )
    }

    func testPythonTreeFollowsEditsWithoutReparsing() {
        assertFollows(
            "def f():\n    pass\n", language: .python,
            edits: [(18, 0, "\nclass A:\n    x = [1,\n         2]\n"), (4, 1, "gé"), (9, 4, "\t"),
                    (0, 0, "\n\n"), (3, 6, "")]
        )
    }

    func testUndoAndRedoAreFollowedToo() {
        let document = SyntaxDocument(answerTimeout: .seconds(10))
        var state = TextEditingState("void f() {\n}\n")
        _ = document.sExpression(for: state, language: .c)
        state.setCursor(state.index(atOffset: 10))
        state.insert("\n    g();")
        state.insert(" h();")
        state.undo()
        state.redo()
        state.undo()
        XCTAssertEqual(document.sExpression(for: state, language: .c), fresh(state.text, .c))
        XCTAssertEqual(document.fullParses, 1)
    }

    func testABufferItCannotFollowIsParsedWhole() {
        let document = SyntaxDocument(answerTimeout: .seconds(10))
        var state = TextEditingState("int x;\n")
        _ = document.sExpression(for: state, language: .c)
        state.setText("int y = 2;\n")
        XCTAssertEqual(document.sExpression(for: state, language: .c), fresh(state.text, .c))
        XCTAssertEqual(document.fullParses, 2)
        // Another editor's buffer of the same text has a revision this tree
        // has never seen.
        let other = TextEditingState(state.text)
        _ = document.sExpression(for: other, language: .c)
        XCTAssertEqual(document.fullParses, 3)
    }

    func testIndentationAfterEditsMatchesAFreshDocument() {
        let followed = SyntaxDocument(answerTimeout: .seconds(10))
        var state = TextEditingState("void f(void) {\n}\n")
        _ = followed.indentation(for: state, at: state.text.endIndex, language: .c)
        state.setCursor(state.index(atOffset: 14))
        state.insert("\n    run(\n        one,")
        let caret = state.focus
        XCTAssertEqual(followed.indentation(for: state, at: caret, language: .c), "        ")
        XCTAssertEqual(followed.fullParses, 1)
        XCTAssertEqual(SyntaxDocument(answerTimeout: .seconds(10)).indentation(in: state.text, at: caret, language: .c), "        ")
    }

    func testSwiftFollowsEditsWithoutReparsing() throws {
        try XCTSkipUnless(SyntaxDocument.hasSwiftParser)
        let document = SyntaxDocument(answerTimeout: .seconds(10))
        var state = TextEditingState("func f() {\n}\n")
        _ = document.indentation(for: state, at: state.text.endIndex, language: .swift)
        state.setCursor(state.index(atOffset: 10))
        state.insert("\n    switch café {\n    case .🍎:")
        XCTAssertEqual(document.indentation(for: state, at: state.focus, language: .swift), "        ")
        state.insert("\n        work(")
        XCTAssertEqual(document.indentation(for: state, at: state.focus, language: .swift), "            ")
        XCTAssertEqual(document.fullParses, 1)
    }

    func testLineStartsFollowSplices() {
        var text = "a\nbc\n\nd"
        var lines = withBytes(of: text) { LineStarts($0) }
        for (offset, removed, inserted) in [(1, 1, ""), (0, 0, "x\ny\n"), (5, 3, "é\n"), (2, 0, "\n\n")] {
            let utf8 = Array(text.utf8)
            text = String(decoding: utf8[..<offset] + Array(inserted.utf8) + utf8[(offset + removed)...], as: UTF8.self)
            lines.apply(TextChange(offset: offset, removedLength: removed, inserted: inserted))
            XCTAssertEqual(lines.starts, withBytes(of: text) { LineStarts($0) }.starts, "after splicing at \(offset)")
            XCTAssertEqual(lines.byteCount, text.utf8.count)
        }
    }

    /// Applies each `(offset, removed, inserted)`, in characters, as a
    /// selection replaced by typing, and compares the tree with a fresh parse
    /// after every one.
    private func assertFollows(
        _ initial: String, language: SyntaxDocument.Language, edits: [(Int, Int, String)],
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let document = SyntaxDocument(answerTimeout: .seconds(10))
        var state = TextEditingState(initial)
        XCTAssertEqual(document.sExpression(for: state, language: language), fresh(initial, language),
                       file: file, line: line)
        for (offset, removed, inserted) in edits {
            let count = state.text.count
            state.setCursor(state.index(atOffset: min(offset, count)))
            state.setCursor(state.index(atOffset: min(offset + removed, count)), extending: true)
            state.insert(inserted)
            XCTAssertEqual(document.sExpression(for: state, language: language), fresh(state.text, language),
                           "after inserting \(inserted.debugDescription) at \(offset)", file: file, line: line)
        }
        XCTAssertEqual(document.fullParses, 1, "every edit after the first parse is followed", file: file, line: line)
    }

    private func fresh(_ text: String, _ language: SyntaxDocument.Language) -> String? {
        SyntaxDocument(answerTimeout: .seconds(10)).sExpression(for: TextEditingState(text), language: language)
    }
}

/// What the worker does on its own, between questions.
final class BackgroundParseTests: XCTestCase {
    private func largeC() -> String {
        (0..<5000).map { "int f\($0)(int x) {\n    if (x) {\n        return g(x,\n                 x);\n    }\n}\n" }.joined()
    }

    func testFollowingAFileParsesItWithoutBeingAsked() {
        let document = SyntaxDocument(answerTimeout: .seconds(10))
        document.follow(TextEditingState("int main(void) {\n}\n"), language: .c)
        XCTAssertEqual(document.fullParses, 1)
        XCTAssertFalse(document.isDirty)
    }

    func testTypingIsReparsedOnceItPauses() {
        let document = SyntaxDocument(answerTimeout: .seconds(10))
        var state = TextEditingState("void f(void) {\n}\n")
        document.follow(state, language: .c)
        state.setCursor(state.index(atOffset: 14))
        for character in "\n    run();" {
            state.insert(String(character))
            document.follow(state, language: .c)
        }
        let settled = expectation(description: "the worker reparses after the pause")
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(300)) { settled.fulfill() }
        wait(for: [settled], timeout: 5)
        XCTAssertFalse(document.isDirty, "reparsed without a question")
        XCTAssertEqual(document.fullParses, 1, "and incrementally")
        XCTAssertEqual(document.sExpression(for: state, language: .c),
                       SyntaxDocument().sExpression(for: TextEditingState(state.text), language: .c))
    }

    func testEnterDoesNotWaitOutAFirstParse() {
        let document = SyntaxDocument(answerTimeout: .milliseconds(10))
        let state = TextEditingState(largeC())
        let started = Date()
        _ = document.indentation(for: state, at: state.text.endIndex, language: .c)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.2, "the answer is given up on, not waited for")
        // The parse it gave up on still lands, and later questions use it.
        XCTAssertEqual(document.fullParses, 1)
    }

    func testAnEditFollowedFromAnotherBufferStartsOver() {
        let document = SyntaxDocument(answerTimeout: .seconds(10))
        var state = TextEditingState("int x;\n")
        document.follow(state, language: .c)
        state.setText("int y = 2;\n")
        document.follow(state, language: .c)
        XCTAssertEqual(document.fullParses, 2)
        XCTAssertEqual(document.sExpression(for: state, language: .c),
                       SyntaxDocument().sExpression(for: TextEditingState(state.text), language: .c))
    }
}
