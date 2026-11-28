import XCTest
@testable import LavaProjectCore

final class ProjectTypeAheadTests: XCTestCase {
    private let rows: [ProjectRow] = ["docs", "README.md", "readme-old.txt", "src", "tests", "tools"].map {
        ProjectRow(node: ProjectNode(name: $0, path: $0, isDirectory: false), depth: 0, isExpanded: false)
    }

    func testAPrefixTypedQuicklyNarrowsDown() {
        var ahead = ProjectTypeAhead()
        XCTAssertEqual(ahead.type("r", at: 0, from: "docs", in: rows), "README.md")
        XCTAssertEqual(ahead.type("e", at: 0.2, from: "README.md", in: rows), "README.md")
        XCTAssertEqual(ahead.type("a", at: 0.4, from: "README.md", in: rows), "README.md")
        XCTAssertEqual(ahead.type("d", at: 0.6, from: "README.md", in: rows), "README.md")
        XCTAssertEqual(ahead.type("m", at: 0.8, from: "README.md", in: rows), "README.md")
        XCTAssertEqual(ahead.type("e", at: 1.0, from: "README.md", in: rows), "README.md")
        XCTAssertEqual(ahead.type("-", at: 1.2, from: "README.md", in: rows), "readme-old.txt")
    }

    func testTheSameLetterAgainStepsThroughAndWraps() {
        var ahead = ProjectTypeAhead()
        XCTAssertEqual(ahead.type("t", at: 0, from: nil, in: rows), "tests")
        XCTAssertEqual(ahead.type("t", at: 0.1, from: "tests", in: rows), "tools")
        XCTAssertEqual(ahead.type("t", at: 0.2, from: "tools", in: rows), "tests")
    }

    func testAPauseStartsOver() {
        var ahead = ProjectTypeAhead()
        XCTAssertEqual(ahead.type("s", at: 0, from: nil, in: rows), "src")
        XCTAssertEqual(ahead.type("d", at: 5, from: "src", in: rows), "docs")
        XCTAssertEqual(ahead.typed, "d")
    }

    func testNoMatchSaysSo() {
        var ahead = ProjectTypeAhead()
        XCTAssertNil(ahead.type("z", at: 0, from: "docs", in: rows))
    }
}
