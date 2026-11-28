import XCTest
@testable import LavaLSPCore

final class ProblemListTests: XCTestCase {
    private func problem(_ path: String, _ line: Int, _ column: Int, _ severity: DiagnosticSeverity,
                         _ message: String) -> Problem {
        let at = LSPPosition(line: line, character: column)
        return Problem(path: path, range: LSPRange(start: at, end: at), severity: severity, message: message)
    }

    func testFilesByPathProblemsByPlaceWorstFirst() {
        let list = ProblemList([
            problem("/p/b.swift", 9, 0, .warning, "unused"),
            problem("/p/a.c", 4, 2, .warning, "w"),
            problem("/p/a.c", 4, 2, .error, "e"),
            problem("/p/a.c", 1, 0, .hint, "h"),
        ])
        XCTAssertEqual(list.files.map(\.path), ["/p/a.c", "/p/b.swift"])
        XCTAssertEqual(list.files[0].problems.map(\.message), ["h", "e", "w"])
        XCTAssertEqual(list.count, 4)
        XCTAssertEqual(list.errors, 1)
        XCTAssertEqual(list.warnings, 2)
    }

    func testRowsFoldByFileAndKeepIdsAcrossRefreshes() {
        let problems = [problem("/p/a.c", 1, 0, .error, "x"), problem("/p/b.c", 2, 3, .warning, "y")]
        let list = ProblemList(problems)
        let rows = list.rows(collapsed: [])
        XCTAssertEqual(rows.map(\.kind), [.file(0), .problem(file: 0, index: 0), .file(1), .problem(file: 1, index: 0)])
        XCTAssertEqual(list.rows(collapsed: ["/p/a.c"]).map(\.kind),
                       [.file(0), .file(1), .problem(file: 1, index: 0)])
        // A new problem elsewhere does not change the ids of the others.
        let more = ProblemList(problems + [problem("/p/a.c", 0, 0, .hint, "z")])
        XCTAssertEqual(Set(rows.map(\.id)).subtracting(more.rows(collapsed: []).map(\.id)), [])
    }

    func testIdenticalProblemsGetDistinctIds() {
        let same = problem("/p/a.c", 1, 0, .error, "x")
        let rows = ProblemList([same, same]).rows(collapsed: [])
        XCTAssertEqual(Set(rows.map(\.id)).count, 3)
    }

    func testLocationIsOneBased() {
        XCTAssertEqual(problem("/a", 0, 0, .error, "").location, "Ln 1, Col 1")
        XCTAssertEqual(problem("/a", 11, 4, .error, "").location, "Ln 12, Col 5")
    }

    func testDisplayPathIsRelativeToTheRoot() {
        XCTAssertEqual(ProblemList.displayPath("/p/src/a.c", root: "/p").folder, "src")
        XCTAssertEqual(ProblemList.displayPath("/p/a.c", root: "/p/").folder, "")
        XCTAssertEqual(ProblemList.displayPath("/elsewhere/a.c", root: "/p").folder, "/elsewhere")
        XCTAssertEqual(ProblemList.displayPath("/p/src/a.c", root: nil).name, "a.c")
    }
}
