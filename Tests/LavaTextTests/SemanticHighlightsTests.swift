import XCTest
@testable import LavaText

final class SemanticHighlightsTests: XCTestCase {
    private func span(_ range: Range<Int>, _ style: Int) -> HighlightSpan {
        HighlightSpan(range: range, styleIndex: style)
    }

    func testServerSpansWinInsideAndLexerSpansStandOutside() {
        // A lexer span 0..<20 (say a doc comment) with two server spans in it,
        // and a lexer span the server does not touch.
        let semantic = SemanticHighlights(lines: [3: [span(12..<15, 5), span(4..<8, 4)]])
        let base = [span(0..<20, 2), span(22..<25, 0)]
        XCTAssertEqual(semantic.overlay(base, line: 3), [
            span(0..<4, 2), span(4..<8, 4), span(8..<12, 2), span(12..<15, 5),
            span(15..<20, 2), span(22..<25, 0),
        ])
    }

    func testGapsTakeTheServerSpanAndOtherLinesAreUntouched() {
        let semantic = SemanticHighlights(lines: [0: [span(4..<9, 4)]])
        let base = [span(0..<3, 0)]
        XCTAssertEqual(semantic.overlay(base, line: 0), [span(0..<3, 0), span(4..<9, 4)])
        XCTAssertEqual(semantic.overlay(base, line: 1), base)
    }

    func testASpanCoveringALexerSpanReplacesIt() {
        let semantic = SemanticHighlights(lines: [0: [span(2..<10, 5)]])
        XCTAssertEqual(semantic.overlay([span(3..<6, 1), span(10..<12, 3)], line: 0),
                       [span(2..<10, 5), span(10..<12, 3)])
    }
}
