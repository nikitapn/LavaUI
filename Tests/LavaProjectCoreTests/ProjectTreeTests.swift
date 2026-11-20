import Foundation
import LavaGitCore
import XCTest
@testable import LavaProjectCore

final class ProjectTreeTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lava-tree-\(UUID().uuidString)", isDirectory: true)
        for folder in ["src/deep", "docs", ".git/objects", ".github"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(folder), withIntermediateDirectories: true
            )
        }
        for file in ["file10.txt", "file2.txt", "README.md", ".gitignore", "src/a.swift", "src/deep/b.swift"] {
            try "x".write(to: root.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func names(_ tree: ProjectTree) -> [String] {
        tree.rows.map { String(repeating: "  ", count: $0.depth) + $0.node.name }
    }

    func testRootListsFoldersFirstInNaturalOrderWithoutGit() {
        var tree = ProjectTree(root: root)
        tree.load("")
        XCTAssertEqual(names(tree), [
            ".github", "docs", "src", ".gitignore", "file2.txt", "file10.txt", "README.md",
        ])
    }

    func testExpandingListsLazilyAndCollapsingKeepsTheListing() {
        var tree = ProjectTree(root: root)
        tree.load("")
        XCTAssertNil(tree.listings["src"])
        tree.toggle("src")
        XCTAssertEqual(names(tree).filter { $0.hasPrefix("  ") }, ["  deep", "  a.swift"])
        tree.toggle("src")
        XCTAssertFalse(names(tree).contains("  a.swift"))
        XCTAssertNotNil(tree.listings["src"], "a collapsed folder keeps what it read")
    }

    func testRevealOpensEveryParent() {
        var tree = ProjectTree(root: root)
        tree.reveal("src/deep/b.swift")
        XCTAssertTrue(names(tree).contains("    b.swift"))
        XCTAssertEqual(tree.visibleFolders, ["", "src", "src/deep"])
        tree.toggle("src")
        // `deep` is still expanded, but under a closed parent nobody sees it.
        XCTAssertEqual(tree.visibleFolders, [""])
    }

    func testReloadNoticesNewAndDeletedEntries() throws {
        var tree = ProjectTree(root: root)
        tree.reveal("src/deep/b.swift")
        try "y".write(to: root.appendingPathComponent("src/new.swift"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: root.appendingPathComponent("src/deep"))
        XCTAssertTrue(tree.reload("src"))
        XCTAssertEqual(names(tree).filter { $0.hasPrefix("  ") }, ["  a.swift", "  new.swift"])
        XCTAssertNil(tree.listings["src/deep"])
        XCTAssertFalse(tree.expanded.contains("src/deep"))
        XCTAssertFalse(tree.reload("src"), "nothing changed the second time")
    }

    func testRestoreDropsFoldersThatAreGone() {
        var tree = ProjectTree(root: root)
        tree.restore(expanded: ["src", "src/deep", "gone", "gone/child"])
        XCTAssertEqual(tree.expanded, ["", "src", "src/deep"])
    }

    func testPathMapping() {
        let tree = ProjectTree(root: root)
        XCTAssertEqual(tree.path(of: root.appendingPathComponent("src/a.swift")), "src/a.swift")
        XCTAssertEqual(tree.path(of: root), "")
        XCTAssertNil(tree.path(of: URL(fileURLWithPath: "/etc/hosts")))
    }
}

final class GitDecorationsTests: XCTestCase {
    private func node(_ path: String, folder: Bool = false) -> ProjectNode {
        ProjectNode(name: String(path.split(separator: "/").last ?? ""), path: path, isDirectory: folder)
    }

    private let entries = [
        GitStatusEntry(path: "src/a.swift", kind: .tracked, unstaged: .modified),
        GitStatusEntry(path: "src/deep/new.swift", kind: .untracked, unstaged: .added),
        GitStatusEntry(path: "docs/x.md", kind: .conflicted, staged: .updatedUnmerged, unstaged: .updatedUnmerged),
        GitStatusEntry(path: "staged.txt", kind: .tracked, staged: .added),
        GitStatusEntry(path: ".build/", kind: .ignored),
    ]

    func testFilesAndTheFoldersAboveThem() {
        let marks = GitDecorations(entries: entries)
        XCTAssertEqual(marks.mark(for: node("src/a.swift")), .modified)
        XCTAssertEqual(marks.mark(for: node("staged.txt")), .added)
        XCTAssertEqual(marks.mark(for: node("src/deep/new.swift")), .untracked)
        // The louder of a modification and an untracked file below it.
        XCTAssertEqual(marks.mark(for: node("src", folder: true)), .modified)
        XCTAssertEqual(marks.mark(for: node("src/deep", folder: true)), .untracked)
        XCTAssertEqual(marks.mark(for: node("docs", folder: true)), .conflicted)
        XCTAssertNil(marks.mark(for: node("README.md")))
    }

    func testEverythingInsideAnIgnoredFolderIsIgnored() {
        let marks = GitDecorations(entries: entries)
        XCTAssertEqual(marks.mark(for: node(".build", folder: true)), .ignored)
        XCTAssertEqual(marks.mark(for: node(".build/debug/x.o")), .ignored)
        XCTAssertNil(marks.mark(for: node(".buildx")))
    }

    func testProjectInsideTheRepository() {
        let marks = GitDecorations(entries: entries, repositoryPath: nil, projectPath: "src")
        XCTAssertEqual(marks.mark(for: node("a.swift")), .modified)
        XCTAssertEqual(marks.mark(for: node("deep", folder: true)), .untracked)
        XCTAssertNil(marks.mark(for: node("staged.txt")), "outside the project")
    }

    func testRepositoryInsideTheProject() {
        let marks = GitDecorations(entries: entries, repositoryPath: "vendor/lib")
        XCTAssertEqual(marks.mark(for: node("vendor/lib/src/a.swift")), .modified)
        XCTAssertEqual(marks.mark(for: node("vendor", folder: true)), .conflicted)
    }
}
