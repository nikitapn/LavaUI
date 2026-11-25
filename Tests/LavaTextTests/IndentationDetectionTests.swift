import LavaText
import XCTest

final class IndentationDetectionTests: XCTestCase {
    func testNoIndentedLineIsNoEvidence() {
        XCTAssertNil(DetectedIndentation.detect(in: ""))
        XCTAssertNil(DetectedIndentation.detect(in: "one\ntwo\n\nthree"))
    }

    func testTabIndentedFiles() {
        let makefile = "all: build\n\nbuild:\n\tswift build\n\tswift test\n"
        XCTAssertEqual(DetectedIndentation.detect(in: makefile), .init(insertSpaces: false, tabSize: nil))
        let c = "int main(void) {\n\tif (x) {\n\t\trun();\n\t}\n}\n"
        XCTAssertEqual(DetectedIndentation.detect(in: c), .init(insertSpaces: false, tabSize: nil))
    }

    func testSpaceWidthIsTheCommonStep() {
        let two = "a {\n  b {\n    c\n    d {\n      e\n    }\n  }\n}\n"
        XCTAssertEqual(DetectedIndentation.detect(in: two), .init(insertSpaces: true, tabSize: 2))
        let four = "def f():\n    if x:\n        g()\n        h()\n    return 1\n"
        XCTAssertEqual(DetectedIndentation.detect(in: four), .init(insertSpaces: true, tabSize: 4))
    }

    func testDoubleDedentsDoNotOutvoteTheLevel() {
        // Two steps of 2 in and one of 4 out: 2 must win, not tie-break to 4.
        let text = "a\n  b\n    c\nd\n  e\n    f\ng\n"
        XCTAssertEqual(DetectedIndentation.detect(in: text)?.tabSize, 2)
    }

    func testBlankLinesAndCommentContinuationsAreIgnored() {
        let text = "class A {\n    /**\n     * Doc.\n     */\n    func f() {\n\n        g()\n    }\n}\n"
        XCTAssertEqual(DetectedIndentation.detect(in: text), .init(insertSpaces: true, tabSize: 4))
    }

    func testSpacesWithoutAStepKeepTheConfiguredWidth() {
        XCTAssertEqual(DetectedIndentation.detect(in: "x\n y\n  z\n"), .init(insertSpaces: true, tabSize: nil))
    }

    func testMajorityDecidesMixedFiles() {
        let text = "a\n\tb\n\tc\n    d\n"
        XCTAssertEqual(DetectedIndentation.detect(in: text)?.insertSpaces, false)
    }

    func testLineLimit() {
        let text = "a\n" + String(repeating: "\tb\n", count: 5)
        XCTAssertNil(DetectedIndentation.detect(in: text, lineLimit: 1))
    }
}
