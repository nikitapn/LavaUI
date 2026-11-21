import LavaGitCore
import XCTest
@testable import LavaProjectCore

final class SourceControlListTests: XCTestCase {
    private let entries = [
        GitStatusEntry(path: "z/edited.swift", kind: .tracked, unstaged: .modified),
        GitStatusEntry(path: "both.swift", kind: .tracked, staged: .modified, unstaged: .modified),
        GitStatusEntry(path: "new.swift", kind: .tracked, staged: .added),
        GitStatusEntry(path: "b.txt", originalPath: "a.txt", kind: .tracked, staged: .renamed),
        GitStatusEntry(path: "gone.swift", kind: .tracked, unstaged: .deleted),
        GitStatusEntry(path: "scratch.txt", kind: .untracked, unstaged: .added),
        GitStatusEntry(path: "clash.c", kind: .conflicted, staged: .updatedUnmerged, unstaged: .updatedUnmerged),
        GitStatusEntry(path: ".build/", kind: .ignored),
    ]

    func testGroupsAndLetters() {
        let list = SourceControlList(entries)
        XCTAssertEqual(list.groups, [.conflicts, .staged, .changes])
        XCTAssertEqual(list.conflicts.map(\.letter), ["!"])
        XCTAssertEqual(list.staged.map(\.path), ["b.txt", "both.swift", "new.swift"])
        XCTAssertEqual(list.staged.map(\.letter), ["R", "M", "A"])
        XCTAssertEqual(list.changes.map(\.path), ["both.swift", "gone.swift", "scratch.txt", "z/edited.swift"])
        XCTAssertEqual(list.changes.map(\.letter), ["M", "D", "U", "M"])
    }

    func testRenameNamesBothEnds() {
        let rename = SourceControlList(entries).staged.first { $0.path == "b.txt" }
        XCTAssertEqual(rename?.paths, ["b.txt", "a.txt"])
    }

    func testNameAndFolder() {
        let item = SourceControlList(entries).changes.first { $0.path == "z/edited.swift" }
        XCTAssertEqual(item?.name, "edited.swift")
        XCTAssertEqual(item?.folder, "z")
        XCTAssertEqual(SourceControlList(entries).changes.first?.folder, "")
    }

    func testRowsCollapseAGroupToItsHeader() {
        let rows = SourceControlList(entries).rows(collapsed: [.staged])
        XCTAssertEqual(rows.first, .header(.conflicts, count: 1))
        XCTAssertTrue(rows.contains(.header(.staged, count: 3)))
        XCTAssertFalse(rows.contains { if case .item(let i) = $0 { return i.group == .staged } else { return false } })
        XCTAssertEqual(rows.filter { if case .item = $0 { return true } else { return false } }.count, 5)
    }

    func testCleanTreeStillShowsChanges() {
        let list = SourceControlList([])
        XCTAssertTrue(list.isClean)
        XCTAssertEqual(list.rows(), [.header(.changes, count: 0)])
    }
}
