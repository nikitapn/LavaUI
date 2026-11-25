import XCTest
import LavaText

@testable import LavaUI

final class EditorIndentationTests: XCTestCase {
    func testEnterInheritsLogicalLineIndentation() throws {
        try checkEnter("func example() {\n\t  work()|", inserts: "\n\t  ")
        try checkEnter("    |work()", inserts: "\n    ", indentation: .inherit)
        try checkEnter("    work()|", inserts: "\n", indentation: .none)
    }

    func testSwiftOpeningBraceAddsOneLevel() throws {
        try checkEnter("func example() {|", inserts: "\n    ")
        try checkEnter("    if ready { // Retry later|", inserts: "\n        ")
        try checkEnter("\tif ready {|", inserts: "\n\t\t")
        try checkEnter("    if ready { run() }|", inserts: "\n    ")
    }

    func testSwiftBracesInCommentsAndStringsDoNotAddALevel() throws {
        try checkEnter("    // {|", inserts: "\n    ")
        try checkEnter("    let unfinished = \"{|", inserts: "\n    ")
        try checkEnter("    /*\n     {|", inserts: "\n     ")
        try checkEnter("    let example = \"\"\"\n    {|", inserts: "\n    ")
    }

    func testProviderUsesTheInsertionPointAndFallback() throws {
        try checkEnter("    call(|", inserts: "\n        ", indentation: .provider { text, caret, unit in
            XCTAssertEqual(text[..<caret], "    call(")
            return unit + unit
        })
        try checkEnter("    work()|", inserts: "\n    ", indentation: .provider { _, _, _ in nil })
    }

    func testTabAndEnterUseTheConfiguredIndentation() throws {
        let spaces = EditorIndentationFormat(tabSize: 2, insertSpaces: true)
        let tabs = EditorIndentationFormat(tabSize: 2, insertSpaces: false)
        try checkEnter("|", inserts: "  ", format: spaces, key: KeyCode.tab)
        try checkEnter("|", inserts: "\t", format: tabs, key: KeyCode.tab)
        try checkEnter("    if ready {|", inserts: "\n      ", format: spaces)
        try checkEnter("if ready {|", inserts: "\n\t", format: tabs)
    }

    func testInheritedWhitespaceIsNeverRewritten() throws {
        let spaces = EditorIndentationFormat(tabSize: 2, insertSpaces: true)
        let tabs = EditorIndentationFormat(tabSize: 2, insertSpaces: false)
        // A Makefile recipe under "insert spaces" stays a tab.
        try checkEnter("\tswift build|", inserts: "\n\t", indentation: .inherit, format: spaces)
        try checkEnter("   work()|", inserts: "\n   ", indentation: .inherit, format: tabs)
        // A level on a tab-led line is a tab, whatever the format says.
        try checkEnter("\tif ready {|", inserts: "\n\t\t", format: spaces)
        try checkEnter("  if ready {|", inserts: "\n  \t", format: tabs)
        try checkEnter("  call(|", inserts: "\n    ", indentation: .provider { _, _, unit in
            "  " + unit
        }, format: spaces)
    }

    private func checkEnter(
        _ sample: String, inserts: String, indentation: EditorIndentation = .braces,
        format: EditorIndentationFormat? = nil, key: Int32 = KeyCode.enter,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let marker = try XCTUnwrap(sample.firstIndex(of: "|"), file: file, line: line)
        let prefix = sample[..<marker]
        let suffix = sample[sample.index(after: marker)...]
        let original = String(prefix) + suffix
        var text = original
        let binding = Binding(get: { text }, set: { text = $0 })
        let view = EditorView(
            text: binding, highlighter: SyntaxHighlighter(lexer: CodeLexer(.swift)),
            indentation: indentation, indentationFormat: format
        )
        let leaf = try XCTUnwrap(view.mountPrimitive() as? LeafNode, file: file, line: line)
        leaf.editing.setCursor(leaf.editing.index(atOffset: prefix.count))
        leaf.focusSelf(binding: binding, onSubmit: nil)
        defer { FocusManager.clear() }
        XCTAssertTrue(FocusManager.handle(KeyEvent(key: key, mods: 0)), file: file, line: line)
        XCTAssertEqual(text, String(prefix) + inserts + suffix, file: file, line: line)
        XCTAssertEqual(leaf.editing.offset(of: leaf.editing.focus), prefix.count + inserts.count, file: file, line: line)
        XCTAssertTrue(FocusManager.handle(KeyEvent(key: KeyCode.z, mods: KeyMods.control)), file: file, line: line)
        XCTAssertEqual(text, original, file: file, line: line)
    }
}
