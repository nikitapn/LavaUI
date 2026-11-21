import Foundation
import LavaProjectCore
import XCTest

final class EditorWorkspaceTests: XCTestCase {
    func testWorkspaceMovesWithCheckout() throws {
        let source = URL(fileURLWithPath: "/old/repo/.editor/Project.lava-workspace")
        let moved = URL(fileURLWithPath: "/new/repo/.editor/Project.lava-workspace")
        let position = EditorSessionSnapshot.Position(
            scrollX: 5, scrollY: 18.5, anchor: 42, focus: 46, topOffset: 25, topFraction: 0.5
        )
        let snapshot = EditorSessionSnapshot(
            files: [.init(path: "/old/repo/src/main#.swift", position: position, tabState: .pinned),
                    .init(path: "/old/repo/.editor/notes %25.txt", tabState: .preview),
                    .init(path: "/old/repo-other/notes.txt")],
            activePath: "/old/repo/src/main#.swift", fontSize: 14, projectRoot: "/old/repo",
            expandedFolders: ["src", "src/tests"], showsSidebar: false, sidebarFraction: 0.3
        )

        let data = try EditorWorkspace.encode(snapshot, at: source)
        let stored = try JSONDecoder().decode(EditorSessionSnapshot.self, from: data)
        XCTAssertEqual(stored.projectRoot, "..")
        XCTAssertEqual(stored.files.map(\.tabState), [.pinned, .preview, nil])
        XCTAssertEqual(stored.activePath, "../src/main#.swift")
        XCTAssertEqual(stored.files.map(\.path),
                       ["../src/main#.swift", "notes %25.txt", "/old/repo-other/notes.txt"])
        XCTAssertEqual(try EditorWorkspace.decode(data, at: source), snapshot)

        var expected = snapshot
        expected.projectRoot = "/new/repo"
        expected.activePath = "/new/repo/src/main#.swift"
        expected.files[0].path = "/new/repo/src/main#.swift"
        expected.files[1].path = "/new/repo/.editor/notes %25.txt"
        XCTAssertEqual(try EditorWorkspace.decode(data, at: moved), expected)
    }

    func testProjectAtWorkspaceDirectoryUsesDot() throws {
        let url = URL(fileURLWithPath: "/repo/Dev.lava-workspace")
        let snapshot = EditorSessionSnapshot(projectRoot: "/repo")
        let data = try EditorWorkspace.encode(snapshot, at: url)
        XCTAssertEqual(try JSONDecoder().decode(EditorSessionSnapshot.self, from: data).projectRoot, ".")
        XCTAssertEqual(try EditorWorkspace.decode(data, at: url), snapshot)
    }

    func testOlderWorkspaceMayOmitFieldsAndPositions() throws {
        let url = URL(fileURLWithPath: "/repo/Dev.lava-workspace")
        let folderOnly = Data(#"{"projectRoot":"."}"#.utf8)
        XCTAssertEqual(try EditorWorkspace.decode(folderOnly, at: url),
                       EditorSessionSnapshot(projectRoot: "/repo"))

        let files = Data(#"{"files":[{"path":"a.swift"},{"path":"b.swift","position":{"anchor":7}}]}"#.utf8)
        XCTAssertEqual(try EditorWorkspace.decode(files, at: url).files, [
            .init(path: "/repo/a.swift"),
            .init(path: "/repo/b.swift", position: .init(anchor: 7, focus: 7)),
        ])
        XCTAssertThrowsError(try EditorWorkspace.decode(Data("[]".utf8), at: url))
    }

    func testImplicitSessionStillDecodesAbsolutePathsAndOldPositions() throws {
        let data = Data(#"{"files":[{"path":"/repo/a.swift","position":{"scrollX":0,"scrollY":4.5,"anchor":2,"focus":3}}],"activePath":"/repo/a.swift"}"#.utf8)
        let snapshot = try JSONDecoder().decode(EditorSessionSnapshot.self, from: data)
        XCTAssertEqual(snapshot.activePath, "/repo/a.swift")
        XCTAssertEqual(snapshot.files.first?.tabState ?? .open, .open)
        XCTAssertEqual(snapshot.files.first?.position, .init(scrollY: 4.5, anchor: 2, focus: 3))
    }

    func testImplicitSessionRoundTripsTabStates() throws {
        let snapshot = EditorSessionSnapshot(files: [
            .init(path: "/repo/pinned.swift", tabState: .pinned),
            .init(path: "/repo/preview.swift", tabState: .preview),
            .init(path: "/repo/open.swift", tabState: .open),
        ])
        let data = try JSONEncoder().encode(snapshot)
        XCTAssertEqual(try JSONDecoder().decode(EditorSessionSnapshot.self, from: data), snapshot)
    }

    func testRecentPathsAreStandardizedDeduplicatedAndCapped() {
        let paths = ["/repo/./src", "/repo/temp/../src", "relative"]
            + (0..<12).map { "/repo/\($0)" }
        let recent = RecentProjectPaths.normalized(paths)
        XCTAssertEqual(recent, ["/repo/src"] + (0..<9).map { "/repo/\($0)" })
        let reopened = RecentProjectPaths.recording(URL(fileURLWithPath: "/repo/4/."), in: recent)
        XCTAssertEqual(reopened, ["/repo/4"] + recent.filter { $0 != "/repo/4" })
        XCTAssertEqual(RecentProjectPaths.recording(URL(fileURLWithPath: "/new"), in: recent),
                       ["/new"] + Array(recent.prefix(9)))
    }
}
