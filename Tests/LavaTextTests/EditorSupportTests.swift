import XCTest

@testable import LavaText

final class HighlightingTests: XCTestCase {
    private let keyword = HighlightRule(pattern: #"\b(IF|THEN|END_IF)\b"#, styleIndex: 1, priority: 5)
    private let number = HighlightRule(pattern: #"\b\d+\b"#, styleIndex: 2, priority: 3)
    private let comment = HighlightRule(pattern: #"//.*$"#, styleIndex: 3, priority: 10)

    func testMatchesAKeyword() {
        let h = SyntaxHighlighter(rules: [keyword])
        let spans = h.spans(in: "IF x")
        XCTAssertEqual(spans, [HighlightSpan(range: 0..<2, styleIndex: 1)])
    }

    func testSeparateRulesProduceSeparateSpans() {
        let h = SyntaxHighlighter(rules: [keyword, number])
        let spans = h.spans(in: "IF 42")
        XCTAssertEqual(spans.count, 2)
        XCTAssertEqual(spans[0].styleIndex, 1)
        XCTAssertEqual(spans[1].styleIndex, 2)
    }

    /// A keyword inside a comment must read as comment — that is what priority
    /// is for, and getting it backwards is the classic highlighter bug.
    func testHigherPriorityWinsOnOverlap() {
        let h = SyntaxHighlighter(rules: [keyword, comment])
        let spans = h.spans(in: "// IF x")
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans[0].styleIndex, 3)
        XCTAssertEqual(spans[0].range, 0..<7)
    }

    func testNoRulesYieldsNoSpans() {
        XCTAssertTrue(SyntaxHighlighter(rules: []).spans(in: "IF x").isEmpty)
    }

    func testEmptyLineYieldsNoSpans() {
        XCTAssertTrue(SyntaxHighlighter(rules: [keyword]).spans(in: "").isEmpty)
    }

    /// A bad pattern should cost only its own rule.
    func testInvalidPatternIsIgnoredRatherThanFatal() {
        let h = SyntaxHighlighter(rules: [
            HighlightRule(pattern: "[unclosed", styleIndex: 9),
            keyword,
        ])
        XCTAssertEqual(h.spans(in: "IF x").first?.styleIndex, 1)
    }

    /// Spans are character offsets, so multi-byte text must not shift them.
    func testSpansAreCharacterOffsetsNotUTF16() {
        let h = SyntaxHighlighter(rules: [HighlightRule(pattern: "x", styleIndex: 1)])
        let spans = h.spans(in: "é x")
        XCTAssertEqual(spans.first?.range, 2..<3)
    }
}

final class TextSearchTests: XCTestCase {
    func testFindsAllOccurrences() {
        var s = TextSearch()
        s.find("ab", in: "ab cd ab")
        XCTAssertEqual(s.count, 2)
        XCTAssertEqual(s.matches.first, 0..<2)
        XCTAssertEqual(s.matches.last, 6..<8)
    }

    func testIsCaseInsensitiveByDefault() {
        var s = TextSearch()
        s.find("AB", in: "ab")
        XCTAssertEqual(s.count, 1)
    }

    func testCaseSensitiveSearchRespectsCase() {
        var s = TextSearch()
        s.find("AB", in: "ab", caseSensitive: true)
        XCTAssertEqual(s.count, 0)
    }

    func testOverlappingOccurrencesAreNotDoubleCounted() {
        var s = TextSearch()
        s.find("aa", in: "aaaa")
        XCTAssertEqual(s.count, 2, "editors report non-overlapping matches")
    }

    /// Opening find should jump forward from the caret, not back to the top.
    func testInitialMatchIsTheOneAtOrAfterTheCaret() {
        var s = TextSearch()
        s.find("ab", in: "ab cd ab", near: 3)
        XCTAssertEqual(s.current, 6..<8)
    }

    func testNextAdvancesThenWrapsToTheStart() {
        var s = TextSearch()
        s.find("ab", in: "ab cd ab")
        XCTAssertEqual(s.current, 0..<2)
        s.next()
        XCTAssertEqual(s.current, 6..<8)
        s.next()
        XCTAssertEqual(s.current, 0..<2, "past the last match, wrap to the first")
    }

    func testPreviousWrapsBackwards() {
        var s = TextSearch()
        s.find("ab", in: "ab cd ab", near: 0)
        s.previous()
        XCTAssertEqual(s.current, 6..<8)
    }

    func testEmptyQueryIsInactive() {
        var s = TextSearch()
        s.find("", in: "abc")
        XCTAssertFalse(s.isActive)
        XCTAssertNil(s.current)
    }

    func testMatchOffsetsAreCharactersNotBytes() {
        var s = TextSearch()
        s.find("x", in: "éé x")
        XCTAssertEqual(s.matches.first, 3..<4)
    }
}
