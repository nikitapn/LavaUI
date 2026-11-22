import Foundation
import XCTest
@testable import LavaGitCore

/// Against a real repository in a temporary directory. libgit2 answers;
/// the real `git` sets each scene up, so the two are checked against each
/// other. Skipped where there is no `git`.
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
        try git_(arguments, expect: 0)
    }

    private func git_(_ arguments: [String], expect: Int32?) throws {
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
        if let expect { XCTAssertEqual(process.terminationStatus, expect, "git \(arguments)") }
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

    func testRenameIsStagedWithItsOrigin() throws {
        let repo = try XCTUnwrap(GitRepository.containing(directory))
        try git_("mv", "a.txt", "moved.txt")
        XCTAssertEqual(try repo.status(), [
            GitStatusEntry(path: "moved.txt", originalPath: "a.txt", kind: .tracked, staged: .renamed),
        ])
        try repo.unstage(["moved.txt", "a.txt"])
        let status = try repo.status()
        XCTAssertEqual(status.first { $0.path == "a.txt" }?.unstaged, .deleted)
        XCTAssertEqual(status.first { $0.path == "moved.txt" }?.kind, .untracked)
    }

    func testStagingADeletionAndABinaryFile() throws {
        let repo = try XCTUnwrap(GitRepository.containing(directory))
        try FileManager.default.removeItem(at: directory.appendingPathComponent("a.txt"))
        let blob = directory.appendingPathComponent("blob.bin")
        try Data([0xff, 0xfe, 0x00, 0x80]).write(to: blob)
        try repo.stage(["a.txt", "blob.bin"])
        let status = try repo.status()
        XCTAssertEqual(status.first { $0.path == "a.txt" }?.staged, .deleted)
        XCTAssertEqual(status.first { $0.path == "blob.bin" }?.staged, .added)
        XCTAssertEqual(try repo.contents(of: blob, at: .index), .binary)
    }

    func testContentsAtACommitByName() throws {
        try localIdentity()
        let repo = try XCTUnwrap(GitRepository.containing(directory))
        try write("second\n", "a.txt")
        try repo.commit(message: "second", all: true)
        let file = directory.appendingPathComponent("a.txt")
        XCTAssertEqual(try repo.contents(of: file, at: .commit("HEAD~1")), .text("one\ntwo\n"))
        XCTAssertEqual(try repo.contents(of: file, at: .commit("no-such-branch")), .absent)
        // A directory is not a file at HEAD.
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("d"), withIntermediateDirectories: true)
        try write("x", "d/f.txt")
        try repo.commit(message: "dir", all: true)
        XCTAssertEqual(try repo.contents(of: directory.appendingPathComponent("d")), .absent)
    }

    func testMessageIsCleanedLikeDashM() throws {
        try localIdentity()
        let repo = try XCTUnwrap(GitRepository.containing(directory))
        try write("x", "a.txt")
        let summary = try repo.commit(message: "\n\n  subject  \n\n\n# kept\n", all: true)
        XCTAssertTrue(summary.hasSuffix("  subject"), summary)
        XCTAssertThrowsError(try repo.commit(message: " \n ", all: false))
    }

    /// Both sides changed one line: a conflict, staged as resolved, then
    /// committed with both parents and the merge state gone.
    func testConflictResolvedAndMergeCommitted() throws {
        try localIdentity()
        let repo = try XCTUnwrap(GitRepository.containing(directory))
        let base = try XCTUnwrap(repo.branch())
        try git_("checkout", "-q", "-b", "other")
        try write("one\nTHEIRS\n", "a.txt")
        try git_("commit", "-q", "-am", "theirs")
        try git_("checkout", "-q", base)
        try write("one\nOURS\n", "a.txt")
        try git_("commit", "-q", "-am", "ours")
        try git_(["merge", "-q", "other"], expect: nil)

        XCTAssertEqual(try repo.status(), [
            GitStatusEntry(path: "a.txt", kind: .conflicted, staged: .updatedUnmerged, unstaged: .updatedUnmerged),
        ])
        XCTAssertThrowsError(try repo.commit(message: "too soon"))
        try write("one\nBOTH\n", "a.txt")
        try repo.stage(["a.txt"])
        try repo.commit(message: "merged")

        XCTAssertEqual(try repo.status(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git/MERGE_HEAD").path))
        let parents = Process()
        let out = Pipe()
        parents.executableURL = GitRepository.defaultExecutable
        parents.arguments = ["rev-list", "--parents", "-n", "1", "HEAD"]
        parents.currentDirectoryURL = directory
        parents.standardOutput = out
        try parents.run()
        parents.waitUntilExit()
        let words = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: " ")
        XCTAssertEqual(words.count, 3, "a merge commit has two parents")
    }

    /// A hook is something libgit2 would skip, so the commit goes through
    /// `git` — and a hook that refuses stops it.
    func testCommitHookRunsThroughGit() throws {
        try localIdentity()
        let repo = try XCTUnwrap(GitRepository.containing(directory))
        let hook = directory.appendingPathComponent(".git/hooks/pre-commit")
        try FileManager.default.createDirectory(
            at: hook.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\necho refused by hook >&2\nexit 1\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        try write("x", "a.txt")
        XCTAssertThrowsError(try repo.commit(message: "blocked", all: true)) { error in
            XCTAssertTrue("\(error)".contains("refused by hook"), "\(error)")
        }
        try "#!/bin/sh\nexit 0\n".write(to: hook, atomically: true, encoding: .utf8)
        let summary = try repo.commit(message: "allowed")
        XCTAssertTrue(summary.hasSuffix(" allowed"), summary)
    }

    func testBranchBeforeTheFirstCommitAndDetached() throws {
        let repo = try XCTUnwrap(GitRepository.containing(directory))
        let base = try XCTUnwrap(repo.branch())
        try git_("checkout", "-q", "--detach")
        XCTAssertNil(try repo.branch())
        try git_("checkout", "-q", base)
        try git_("checkout", "-q", "--orphan", "fresh")
        XCTAssertEqual(try repo.branch(), "fresh")
        XCTAssertFalse(try repo.hasCommits())
    }
}
