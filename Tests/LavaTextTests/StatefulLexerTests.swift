import XCTest

@testable import LavaText

/// Minimal `/* ... */` block-comment lexer: `state` is "am I inside a
/// comment", which is exactly the thing a per-line `HighlightRule` cannot
/// express (a comment opened two lines up is invisible to a rule matched
/// against only the current line).
private struct BlockCommentLexer: StatefulLexer {
    static var initialState: Bool { false }

    func highlight(_ line: String, state: Bool) -> (spans: [HighlightSpan], nextState: Bool) {
        var spans: [HighlightSpan] = []
        var inComment = state
        var runStart: String.Index? = inComment ? line.startIndex : nil
        var i = line.startIndex

        func offset(_ idx: String.Index) -> Int { line.distance(from: line.startIndex, to: idx) }

        while i < line.endIndex {
            if !inComment, line[i...].hasPrefix("/*") {
                inComment = true
                runStart = i
                i = line.index(i, offsetBy: 2)
                continue
            }
            if inComment, line[i...].hasPrefix("*/") {
                let end = line.index(i, offsetBy: 2)
                if let start = runStart {
                    spans.append(HighlightSpan(range: offset(start)..<offset(end), styleIndex: 0))
                }
                inComment = false
                runStart = nil
                i = end
                continue
            }
            i = line.index(after: i)
        }
        if inComment, let start = runStart {
            spans.append(HighlightSpan(range: offset(start)..<line.count, styleIndex: 0))
        }
        return (spans, inComment)
    }
}

private final class CallCounter { var count = 0 }

/// Same lexer, instrumented — lets a test assert *how much work* an update
/// did, not just that the result was correct.
private struct CountingBlockCommentLexer: StatefulLexer {
    let counter: CallCounter
    static var initialState: Bool { false }

    func highlight(_ line: String, state: Bool) -> (spans: [HighlightSpan], nextState: Bool) {
        counter.count += 1
        return BlockCommentLexer().highlight(line, state: state)
    }
}

final class StatefulLexerTests: XCTestCase {
    func testRuleListHighlighterIsNotStateful() {
        XCTAssertFalse(SyntaxHighlighter(rules: []).isStateful)
    }

    func testLexerHighlighterIsStateful() {
        XCTAssertTrue(SyntaxHighlighter(lexer: BlockCommentLexer()).isStateful)
    }

    func testCommentOpenedOnOneLineColorsTheNextLineEntirely() {
        let highlighter = SyntaxHighlighter(lexer: BlockCommentLexer())
        let (firstSpans, state1) = highlighter.highlight("code /* start", state: highlighter.initialState)
        XCTAssertEqual(firstSpans, [HighlightSpan(range: 5..<13, styleIndex: 0)])

        let (secondSpans, state2) = highlighter.highlight("all comment, no markers", state: state1)
        XCTAssertEqual(secondSpans, [HighlightSpan(range: 0..<23, styleIndex: 0)])

        let (thirdSpans, state3) = highlighter.highlight("end */ code", state: state2)
        XCTAssertEqual(thirdSpans, [HighlightSpan(range: 0..<6, styleIndex: 0)])
        XCTAssertEqual(state3 as? Bool, false)
    }

    func testCacheProducesSameResultAsManualChaining() {
        let highlighter = SyntaxHighlighter(lexer: BlockCommentLexer())
        let lines: [Substring] = ["a /* open", "still in", "close */ b"]

        var cache = SyntaxHighlighter.Cache()
        cache.update(lines: lines, with: highlighter)

        var state = highlighter.initialState
        for (row, line) in lines.enumerated() {
            let (expected, next) = highlighter.highlight(String(line), state: state)
            XCTAssertEqual(cache.spans(atRow: row), expected, "row \(row)")
            state = next
        }
    }

    func testCacheReusesUnchangedPrefixAndConvergesEarly() {
        let counter = CallCounter()
        let highlighter = SyntaxHighlighter(lexer: CountingBlockCommentLexer(counter: counter))
        var cache = SyntaxHighlighter.Cache()

        cache.update(lines: ["one", "two", "three", "four", "five"], with: highlighter)
        XCTAssertEqual(counter.count, 5, "first build lexes every line")

        counter.count = 0
        // Same line count, one line edited in the middle. Nothing before it
        // changed (prefix reuse) and the edited line's outgoing state is
        // identical to before — outside a comment either way — so line 4
        // immediately converges without being re-lexed.
        cache.update(lines: ["one", "two", "THREE", "four", "five"], with: highlighter)
        XCTAssertEqual(counter.count, 1, "only the changed line should re-lex")
    }

    func testCacheRelexesDownstreamWhenStateActuallyChanges() {
        let counter = CallCounter()
        let highlighter = SyntaxHighlighter(lexer: CountingBlockCommentLexer(counter: counter))
        var cache = SyntaxHighlighter.Cache()

        cache.update(lines: ["one", "two", "three"], with: highlighter)
        counter.count = 0

        // Opening a comment on line 0 changes what every line below starts
        // with, so nothing downstream can converge early — all three
        // must re-lex, and line 2 is left uncommented purely by coincidence
        // (no closer), i.e. the whole file is now "in comment".
        cache.update(lines: ["one /*", "two", "three"], with: highlighter)
        XCTAssertEqual(counter.count, 3)
        XCTAssertEqual(cache.spans(atRow: 2), [HighlightSpan(range: 0..<5, styleIndex: 0)])
    }

    func testCacheHandlesInsertedLineWithoutMisalignment() {
        let highlighter = SyntaxHighlighter(lexer: BlockCommentLexer())
        var cache = SyntaxHighlighter.Cache()
        cache.update(lines: ["a", "/* open", "still open"], with: highlighter)

        // Insert a line before the comment opens — every index below shifts,
        // and the cache must not compare stale content at the same index.
        cache.update(lines: ["new", "a", "/* open", "still open"], with: highlighter)

        var state = highlighter.initialState
        let lines: [Substring] = ["new", "a", "/* open", "still open"]
        for (row, line) in lines.enumerated() {
            let (expected, next) = highlighter.highlight(String(line), state: state)
            XCTAssertEqual(cache.spans(atRow: row), expected, "row \(row)")
            state = next
        }
    }

    func testCacheOnNonStatefulHighlighterStaysEmpty() {
        let highlighter = SyntaxHighlighter(rules: [HighlightRule(pattern: "x", styleIndex: 0)])
        var cache = SyntaxHighlighter.Cache()
        cache.update(lines: ["x", "y"], with: highlighter)
        XCTAssertEqual(cache.spans(atRow: 0), [])
        XCTAssertEqual(cache.spans(atRow: 1), [])
    }
}
