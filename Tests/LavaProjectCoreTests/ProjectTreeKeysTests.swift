import XCTest
@testable import LavaProjectCore

final class ProjectTreeKeysTests: XCTestCase {
    /// src/ (open)
    ///   app/ (open)
    ///     main.swift
    ///   empty/ (open, nothing in it)
    ///   util.swift
    /// docs/ (closed)
    /// README.md
    private let rows: [ProjectRow] = [
        row("src", dir: true, depth: 0, open: true),
        row("src/app", dir: true, depth: 1, open: true),
        row("src/app/main.swift", depth: 2),
        row("src/empty", dir: true, depth: 1, open: true),
        row("src/util.swift", depth: 1),
        row("docs", dir: true, depth: 0),
        row("README.md", depth: 0),
    ]

    private static func row(_ path: String, dir: Bool = false, depth: Int, open: Bool = false) -> ProjectRow {
        ProjectRow(node: ProjectNode(name: String(path.split(separator: "/").last!), path: path,
                                     isDirectory: dir),
                   depth: depth, isExpanded: open)
    }

    private func step(_ key: ProjectTreeKey, _ from: String?) -> ProjectTreeStep {
        ProjectTree.step(key, from: from, in: rows)
    }

    func testLeftClosesAnOpenFolderThenGoesToItsParent() {
        XCTAssertEqual(step(.left, "src/app"), .collapse("src/app"))
        XCTAssertEqual(step(.left, "src/app/main.swift"), .select("src/app"))
        XCTAssertEqual(step(.left, "src/util.swift"), .select("src"))
        // A closed folder at the top has nowhere to go.
        XCTAssertEqual(step(.left, "docs"), .none)
        XCTAssertEqual(step(.left, "README.md"), .none)
    }

    func testRightOpensAClosedFolderThenEntersIt() {
        XCTAssertEqual(step(.right, "docs"), .expand("docs"))
        XCTAssertEqual(step(.right, "src"), .select("src/app"))
        XCTAssertEqual(step(.right, "src/empty"), .none)
        XCTAssertEqual(step(.right, "README.md"), .none)
    }

    func testUpAndDownWalkTheVisibleRowsAndStopAtTheEnds() {
        XCTAssertEqual(step(.down, "src/app/main.swift"), .select("src/empty"))
        XCTAssertEqual(step(.up, "src/empty"), .select("src/app/main.swift"))
        XCTAssertEqual(step(.up, "src"), .none)
        XCTAssertEqual(step(.down, "README.md"), .none)
        XCTAssertEqual(step(.home, "docs"), .select("src"))
        XCTAssertEqual(step(.end, "src"), .select("README.md"))
        XCTAssertEqual(step(.pageDown(rows: 3), "src"), .select("src/empty"))
        XCTAssertEqual(step(.pageDown(rows: 30), "src"), .select("README.md"))
        XCTAssertEqual(step(.pageUp(rows: 30), "docs"), .select("src"))
    }

    func testNoSelectionStartsFromTheEndTheKeyComesFrom() {
        XCTAssertEqual(step(.down, nil), .select("src"))
        XCTAssertEqual(step(.right, nil), .select("src"))
        XCTAssertEqual(step(.up, nil), .select("README.md"))
        XCTAssertEqual(step(.end, "gone/away.txt"), .select("README.md"))
        XCTAssertEqual(ProjectTree.step(.down, from: nil, in: []), .none)
    }
}
