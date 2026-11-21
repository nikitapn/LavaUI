import Foundation
import XCTest
@testable import LavaGitCore

final class GitStatusParseTests: XCTestCase {
    func testParsesEveryRecordKind() {
        let records = [
            "1 .M N... 100644 100644 100644 aaaa bbbb Sources/a file.swift",
            "1 A. N... 000000 100644 100644 0000 cccc new.txt",
            "2 R. N... 100644 100644 100644 dddd dddd R100 renamed.txt",
            "old name.txt",
            "u UU N... 100644 100644 100644 100644 e f g both.txt",
            "? untracked/x.txt",
            "! ignored.o",
        ]
        let data = Data((records.joined(separator: "\0") + "\0").utf8)
        let entries = GitStatusEntry.parse(data)
        XCTAssertEqual(entries, [
            GitStatusEntry(path: "Sources/a file.swift", kind: .tracked, unstaged: .modified),
            GitStatusEntry(path: "new.txt", kind: .tracked, staged: .added),
            GitStatusEntry(path: "renamed.txt", originalPath: "old name.txt", kind: .tracked, staged: .renamed),
            GitStatusEntry(
                path: "both.txt", kind: .conflicted, staged: .updatedUnmerged, unstaged: .updatedUnmerged
            ),
            GitStatusEntry(path: "untracked/x.txt", kind: .untracked, unstaged: .added),
            GitStatusEntry(path: "ignored.o", kind: .ignored),
        ])
    }

    func testEmptyOutputIsClean() {
        XCTAssertEqual(GitStatusEntry.parse(Data()), [])
    }
}

/// Against a real repository in a temporary directory, through the real
/// `git`. Skipped where there is none.
final class GitRepositoryTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        let git = GitRepository.defaultExecutable
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: git.path), "no git")
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lava-git-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try git_("init", "-q")
        try "one\ntwo\n".write(to: directory.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try git_("add", "a.txt")
        try git_("commit", "-q", "-m", "first")
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func git_(_ arguments: String...) throws {
        let process = Process()
        process.executableURL = GitRepository.defaultExecutable
        // An identity of its own, and no user or system config: a signing
        // hook in someone's ~/.gitconfig must not decide whether this passes.
        process.arguments = ["-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                             "-c", "commit.gpgsign=false"] + arguments
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        process.environment = environment
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(arguments)")
    }

    func testFindsTheRootFromAFileAndASubdirectory() throws {
        let sub = directory.appendingPathComponent("deep/er", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let fromFile = GitRepository.containing(directory.appendingPathComponent("a.txt"))
        let fromSub = GitRepository.containing(sub)
        XCTAssertEqual(fromFile?.root.resolvingSymlinksInPath(), directory.resolvingSymlinksInPath())
        XCTAssertEqual(fromSub?.root.resolvingSymlinksInPath(), directory.resolvingSymlinksInPath())
        XCTAssertNil(GitRepository.containing(URL(fileURLWithPath: "/")))
    }

    func testContentsAtHeadAndIndex() throws {
        let repo = try XCTUnwrap(GitRepository.containing(directory))
        let file = directory.appendingPathComponent("a.txt")
        try "one\nTWO\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(try repo.contents(of: file), .text("one\ntwo\n"))

        try git_("add", "a.txt")
        XCTAssertEqual(try repo.contents(of: file, at: .index), .text("one\nTWO\n"))
        XCTAssertEqual(try repo.contents(of: file, at: .head), .text("one\ntwo\n"))

        let fresh = directory.appendingPathComponent("fresh.txt")
        try "x".write(to: fresh, atomically: true, encoding: .utf8)
        XCTAssertEqual(try repo.contents(of: fresh), .absent)
    }

    func testStatusAndBranch() throws {
        let repo = try XCTUnwrap(GitRepository.containing(directory))
        try "changed".write(to: directory.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "new".write(to: directory.appendingPathComponent("b c.txt"), atomically: true, encoding: .utf8)
        let status = try repo.status()
        XCTAssertEqual(Set(status.map(\.path)), ["a.txt", "b c.txt"])
        XCTAssertEqual(status.first { $0.path == "a.txt" }?.unstaged, .modified)
        XCTAssertEqual(status.first { $0.path == "b c.txt" }?.kind, .untracked)
        XCTAssertNotNil(try repo.branch())
    }

    func testIgnoredDirectoryIsOneEntry() throws {
        let repo = try XCTUnwrap(GitRepository.containing(directory))
        try ".build/\n".write(to: directory.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        let build = directory.appendingPathComponent(".build/deep", isDirectory: true)
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        for i in 0..<5 {
            try "x".write(to: build.appendingPathComponent("\(i).o"), atomically: true, encoding: .utf8)
        }
        let ignored = try repo.status(ignored: true).filter { $0.kind == .ignored }
        XCTAssertEqual(ignored.map(\.path), [".build/"])
        XCTAssertTrue(try repo.status().allSatisfy { $0.kind != .ignored })
    }

    /// `commit` runs git with the user's own config, so the repository gets
    /// an identity and no signing of its own.
    private func localIdentity() throws {
        try git_("config", "user.name", "Test")
        try git_("config", "user.email", "test@example.invalid")
        try git_("config", "commit.gpgsign", "false")
    }

    private func write(_ text: String, _ name: String) throws {
        try text.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func testStageUnstageAndCommit() throws {
        try localIdentity()
        let repo = try XCTUnwrap(GitRepository.containing(directory))
        try write("one\nTWO\n", "a.txt")
        // A name git would read as a pattern without `:(literal)`.
        try write("x", "[1].txt")
        try repo.stage(["a.txt", "[1].txt"])
        var status = try repo.status()
        XCTAssertEqual(status.first { $0.path == "a.txt" }?.staged, .modified)
        XCTAssertEqual(status.first { $0.path == "[1].txt" }?.staged, .added)

        try repo.unstage(["[1].txt"])
        status = try repo.status()
        XCTAssertEqual(status.first { $0.path == "[1].txt" }?.kind, .untracked)

        let summary = try repo.commit(message: "change \"a\"\n\nwith a body")
        XCTAssertTrue(summary.hasSuffix("change \"a\""), summary)
        XCTAssertEqual(try repo.contents(of: directory.appendingPathComponent("a.txt")), .text("one\nTWO\n"))
        // The unstaged file was not swept into the commit.
        XCTAssertEqual(try repo.status().map(\.path), ["[1].txt"])
    }

    func testCommitAllTakesUntrackedToo() throws {
        try localIdentity()
        let repo = try XCTUnwrap(GitRepository.containing(directory))
        try write("changed", "a.txt")
        try write("new", "b.txt")
        try repo.commit(message: "everything", all: true)
        XCTAssertEqual(try repo.status(), [])
    }

    func testDiscardRestoresFromTheIndexAndKeepsWhatIsStaged() throws {
        let repo = try XCTUnwrap(GitRepository.containing(directory))
        try write("staged\n", "a.txt")
        try repo.stage(["a.txt"])
        try write("staged\nand more\n", "a.txt")
        try repo.discard(["a.txt"])
        let text = try String(contentsOf: directory.appendingPathComponent("a.txt"), encoding: .utf8)
        XCTAssertEqual(text, "staged\n")
        XCTAssertEqual(try repo.status().first?.staged, .modified)
    }

    func testUnstageBeforeTheFirstCommit() throws {
        let fresh = directory.appendingPathComponent("fresh", isDirectory: true)
        try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = GitRepository.defaultExecutable
        process.arguments = ["init", "-q"]
        process.currentDirectoryURL = fresh
        try process.run()
        process.waitUntilExit()
        try "x".write(to: fresh.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        let repo = GitRepository(root: fresh)
        XCTAssertFalse(try repo.hasCommits())
        try repo.stage(["f.txt"])
        XCTAssertEqual(try repo.status().first?.staged, .added)
        try repo.unstage(["f.txt"])
        XCTAssertEqual(try repo.status().first?.kind, .untracked)
    }

    func testFailureSaysWhy() throws {
        let repo = try XCTUnwrap(GitRepository.containing(directory))
        XCTAssertThrowsError(try repo.commit(message: "nothing staged")) { error in
            guard case GitError.failed(let command, _) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(command, "commit")
        }
    }
}
