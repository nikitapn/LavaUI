import LavaEditorSyntax
import XCTest

final class IndentationTests: XCTestCase {
    func testSwiftSwitchLabels() throws {
        try XCTSkipUnless(SyntaxDocument.hasSwiftParser)
        let provider = SyntaxDocument(answerTimeout: .seconds(10))
        check("switch value {\ncase .item(let value):|\n}", "    ", .swift, provider)
        check("switch value {\n    default: // explanation|\n}", "        ", .swift, provider)
        check("    let value:|", nil, .swift, provider)
        check("    let value = ready ? yes :|", nil, .swift, provider)
    }

    func testSwiftDelimiterScopes() throws {
        try XCTSkipUnless(SyntaxDocument.hasSwiftParser)
        let provider = SyntaxDocument(answerTimeout: .seconds(10))
        check("    fun(|", "        ", .swift, provider)
        check("    fun(\n        one,|", "        ", .swift, provider)
        check("    fun(\n        one,|)", "    ", .swift, provider)
        check("    fun(\n        inner(|", "            ", .swift, provider)
        check("    func fun(|", "        ", .swift, provider)
        check("    if ready { // explanation|", "        ", .swift, provider)
        check("    if ready {\n        fun()|}", "    ", .swift, provider)
        check("    let value = \"fun(|", nil, .swift, provider)
        check("    // fun(|", nil, .swift, provider)
        check("    /*\n    fun(|", nil, .swift, provider)
    }

    func testPythonSuitesAndContinuations() {
        let provider = SyntaxDocument(answerTimeout: .seconds(10))
        check("if ready: # explanation|", "    ", .python, provider)
        check("def foo():\n\tif ready:|", "\t\t", .python, provider)
        check("match value:\n    case 1:|", "        ", .python, provider)
        check("def foo(\n    arg,\n):|", "    ", .python, provider)
        check("    value:|", nil, .python, provider)
        check("    callback = lambda arg:|", nil, .python, provider)
        check("    fun(|", "        ", .python, provider)
        check("    fun(\n        one,|", "        ", .python, provider)
        check("    fun(\n        one,|)", "    ", .python, provider)
        check("    value = \"fun(|", nil, .python, provider)
        check("    # fun(|", nil, .python, provider)
    }

    func testCBlocksCasesAndCalls() {
        let provider = SyntaxDocument(answerTimeout: .seconds(10))
        check("int main(void) { // entry point|", "    ", .c, provider)
        check("int main(void) {\n    run();|}", "", .c, provider)
        check("int main(void) {\n    run();|", nil, .c, provider)
        check("void f(int x) {\n    switch (x) {\n    case 1:|", "        ", .c, provider)
        check("void f(int x) {\n    switch (x) {\n    default:|", "        ", .c, provider)
        check("void f(void) {\n    run(\n        one,|", "        ", .c, provider)
        check("void f(void) {\n    run(\n        one,|);\n}", "    ", .c, provider)
        check("void f(void) {\n    // run(|", nil, .c, provider)
        check("void f(int x) {\n    switch (x) {\n    case 1: /*\n        comment|", nil, .c, provider)
        check("void f(void) {\n    const char *value = \"{|", nil, .c, provider)
        check("void f(void) { run(\"{|", nil, .c, provider)
    }

    func testCppConstructsAndIncrementalEdits() {
        let provider = SyntaxDocument(answerTimeout: .seconds(10))
        check("namespace demo {\nclass Widget {|", "    ", .cpp, provider)
        check("namespace demo {\nclass Widget {\n    int item;|};\n}", "", .cpp, provider)
        check("class Widget {\npublic:|", "    ", .cpp, provider)
        check("void f() {\n    auto items = std::vector<int>{|", "        ", .cpp, provider)
        check("void f() {\n    auto items = std::vector<int>{\n        1,|", nil, .cpp, provider)
        check("void f() {\n    auto items = std::vector<int>{\n      1,|\n    };\n}", "        ", .cpp, provider)
        check("void f() {\n    auto fn = []() {|", "        ", .cpp, provider)
        check("template <typename T,| typename U>\nstruct Pair {};", "    ", .cpp, provider)
        check("    auto value = R\"tag({\n    (|\n)tag\";", nil, .cpp, provider)
        check("void f() {\n    café(|", "        ", .cpp, provider)
        check("void f() {\n    cafê(|", "        ", .cpp, provider)
        check("void f() {\n    cafê();|", nil, .cpp, provider)
    }

    func testUpdatesReuseTheDocumentAfterUnicodeEdits() throws {
        let provider = SyntaxDocument(answerTimeout: .seconds(10))
        check("if café:|\n    work()", "    ", .python, provider)
        check("if cafê:|\n    work()", "    ", .python, provider)
        check("if cafê:\n    fun(é,|", "        ", .python, provider)
        check("if cafê:\n    fun(é,|", "        ", .python, provider)
        check("if cafê:\n    fun(é,|)", "    ", .python, provider)
        check("if cafê:|\n    work()", "    ", .python, provider)

        try XCTSkipUnless(SyntaxDocument.hasSwiftParser)
        check("switch café {\ncase .🍎:|\n}", "    ", .swift, provider)
        check("switch cafê {\ncase .🍏:|\n}", "    ", .swift, provider)
    }

    private func check(
        _ sample: String, _ indentation: String?, _ language: SyntaxDocument.Language,
        _ provider: SyntaxDocument, file: StaticString = #filePath, line: UInt = #line
    ) {
        let marker = sample.firstIndex(of: "|")!
        let before = sample[..<marker]
        let text = String(before) + sample[sample.index(after: marker)...]
        let caret = text.index(text.startIndex, offsetBy: before.count)
        XCTAssertEqual(provider.indentation(in: text, at: caret, language: language), indentation, file: file, line: line)
    }
}
