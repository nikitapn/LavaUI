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

    // Matching runs over UTF-8 bytes and offsets are reported in characters,
    // so every case below is one where the two disagree. See `locate`.

    func testMultiByteNeedleReportsCharacterOffsets() {
        var s = TextSearch()
        s.find("日本", in: "aé日本語日本", caseSensitive: true)
        XCTAssertEqual(s.matches, [2..<4, 5..<7])
    }

    func testEmojiNeedleIsOneMatchNotSeveral() {
        var s = TextSearch()
        s.find("👩‍👩‍👧‍👦", in: "a 👩‍👩‍👧‍👦 b 👩‍👩‍👧‍👦", caseSensitive: true)
        XCTAssertEqual(s.count, 2)
        XCTAssertEqual(s.matches.first, 2..<3, "a ZWJ sequence is one character")
        XCTAssertEqual(s.matches.last, 6..<7)
    }

    /// `"\r\n"` is two bytes and one grapheme, so a CRLF buffer is the case
    /// where the all-ASCII shortcut must not be taken.
    func testCRLFBufferReportsCharacterOffsets() {
        var s = TextSearch()
        s.find("b", in: "a\r\nb\r\nb", caseSensitive: true)
        XCTAssertEqual(s.matches, [2..<3, 4..<5])
    }

    func testNeedleAtTheVeryStartAndEnd() {
        var s = TextSearch()
        s.find("é", in: "édé", caseSensitive: true)
        XCTAssertEqual(s.matches, [0..<1, 2..<3])
    }

    /// The needle's bytes occur inside a multi-byte character but not at a
    /// character boundary — reporting it would hand the editor a range it
    /// cannot select.
    func testByteMatchInsideACharacterIsNotAMatch() {
        // U+65E5 日 is E6 97 A5; U+E5 å is C3 A5. The trailing A5 byte is
        // shared, and a naive byte scan would find "å" inside "日".
        var s = TextSearch()
        s.find("å", in: "日", caseSensitive: true)
        XCTAssertEqual(s.count, 0)
    }

    func testManyMatchesInALargeBufferStayLinear() {
        // Not a timing assertion — it is a shape assertion. The previous
        // implementation measured from `startIndex` per match, so this input
        // (50,000 matches) did not finish rather than finishing slowly.
        let text = String(repeating: "ERROR line of ordinary length here\n", count: 50_000)
        var s = TextSearch()
        s.find("ERROR", in: text, caseSensitive: true)
        XCTAssertEqual(s.count, 50_000)
        XCTAssertEqual(s.matches.first, 0..<5)
        XCTAssertEqual(s.matches.last, (text.count - 35)..<(text.count - 30))
    }
}
