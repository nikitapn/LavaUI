import XCTest
@testable import LavaProjectCore

final class ProjectTreeMoveTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("project-move-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("src/app/deep"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("src/app/main.swift"))
        try Data().write(to: root.appendingPathComponent("src/app/deep/x.swift"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testARenamedFolderStaysOpenWithItsContents() throws {
        var tree = ProjectTree(root: root)
        tree.restore(expanded: ["src", "src/app", "src/app/deep"])
        try FileManager.default.moveItem(at: root.appendingPathComponent("src/app"),
                                         to: root.appendingPathComponent("src/core"))
        tree.moved("src/app", to: "src/core")
        XCTAssertEqual(tree.rows.map(\.node.path), [
            "src", "src/core", "src/core/deep", "src/core/deep/x.swift", "src/core/main.swift",
        ])
        XCTAssertTrue(tree.rows.allSatisfy { !$0.node.isDirectory || $0.isExpanded })
    }

    func testParentOfAPath() {
        XCTAssertEqual(ProjectTree.parent(of: "a/b/c"), "a/b")
        XCTAssertEqual(ProjectTree.parent(of: "a"), "")
    }
}
