import Foundation

/// A git working tree, driven through the `git` command.
///
/// The command rather than libgit2: it is on every machine that has a
/// repository, it reads every repository format git itself does (split index,
/// sparse checkout, reftables, whatever comes next), and it adds no library to
/// keep in step with the system's OpenSSL. What it costs is a process per
/// question, a few milliseconds — fine for "what did this file look like at
/// HEAD", and the reason anything per-keystroke must diff in memory against a
/// text fetched once rather than ask git again.
///
/// Every call is blocking. Run them off the frame loop.
public struct GitRepository: Sendable, Equatable {
    /// The top of the working tree.
    public let root: URL
    /// The `git` binary used for every call.
    public let executable: URL

    /// Creates a handle on a known working tree, without checking it is one.
    public init(root: URL, executable: URL = GitRepository.defaultExecutable) {
        self.root = root.standardizedFileURL
        self.executable = executable
    }

    /// The working tree containing `url` (a file or a directory), or nil when
    /// it is in none or git is not installed.
    public static func containing(
        _ url: URL, executable: URL = GitRepository.defaultExecutable
    ) -> GitRepository? {
        var directory = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory)
            || !isDirectory.boolValue
        {
            directory = directory.deletingLastPathComponent()
        }
        guard let result = try? GitCommand.run(
                  executable, ["rev-parse", "--show-toplevel"], in: directory
              ),
              result.status == 0,
              let path = String(data: result.output, encoding: .utf8)?
                  .trimmingCharacters(in: .newlines),
              !path.isEmpty
        else { return nil }
        return GitRepository(root: URL(fileURLWithPath: path, isDirectory: true), executable: executable)
    }

    /// `git` from `PATH`, or `/usr/bin/git` when `PATH` does not have one.
    public static var defaultExecutable: URL {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent("git")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return URL(fileURLWithPath: "/usr/bin/git")
    }

    /// `url`'s path relative to `root`, as git spells it, or nil outside it.
    public func relativePath(of url: URL) -> String? {
        // Resolved, because a file opened through a symlinked directory is
        // still the file git knows by its real path.
        let file = url.standardizedFileURL.resolvingSymlinksInPath().path
        let top = root.resolvingSymlinksInPath().path
        let prefix = top.hasSuffix("/") ? top : top + "/"
        guard file.hasPrefix(prefix) else { return nil }
        return String(file.dropFirst(prefix.count))
    }

    /// Which version of a file to read.
    public enum Revision: Sendable, Equatable {
        /// The last commit.
        case head
        /// What is staged — the index.
        case index
        /// Any commit-ish git understands: a hash, a branch, `HEAD~2`.
        case commit(String)

        var spec: String {
            switch self {
            case .head: return "HEAD:"
            case .index: return ":"
            case .commit(let name): return "\(name):"
            }
        }
    }

    /// What `file` held at `revision`.
    public enum Contents: Sendable, Equatable {
        case text(String)
        /// It was not tracked there — a new file, or HEAD before the first commit.
        case absent
        /// Not valid UTF-8, so a text diff cannot show it.
        case binary
    }

    /// The contents of `url` at `revision`.
    public func contents(of url: URL, at revision: Revision = .head) throws -> Contents {
        guard let path = relativePath(of: url) else { return .absent }
        // `cat-file` takes the object name verbatim: no pathspec magic, no
        // textconv, no smudge filters. `show` would run filters, and a file
        // under LFS would come back as its real contents on one side and a
        // pointer on the other.
        let result = try GitCommand.run(
            executable, ["cat-file", "blob", revision.spec + path], in: root
        )
        guard result.status == 0 else { return .absent }
        guard let text = String(data: result.output, encoding: .utf8) else { return .binary }
        return .text(text)
    }

    /// The working tree's status: what is modified, staged, new or in conflict.
    public func status() throws -> [GitStatusEntry] {
        let result = try GitCommand.run(
            executable,
            ["status", "--porcelain=v2", "-z", "--untracked-files=all"],
            in: root
        )
        guard result.status == 0 else {
            throw GitError.failed(command: "status", message: result.errorText)
        }
        return GitStatusEntry.parse(result.output)
    }

    /// The current branch, or nil when HEAD is detached.
    public func branch() throws -> String? {
        let result = try GitCommand.run(executable, ["symbolic-ref", "--quiet", "--short", "HEAD"], in: root)
        guard result.status == 0 else { return nil }
        return String(data: result.output, encoding: .utf8)?.trimmingCharacters(in: .newlines)
    }
}

public enum GitError: Error, Equatable, CustomStringConvertible {
    case failed(command: String, message: String)
    case notRunnable(String)

    public var description: String {
        switch self {
        case .failed(let command, let message): return "git \(command): \(message)"
        case .notRunnable(let reason): return "git could not be run: \(reason)"
        }
    }
}

/// Runs git and collects what it printed.
enum GitCommand {
    struct Result {
        var status: Int32
        var output: Data
        var error: Data
        var errorText: String {
            String(decoding: error, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    static func run(_ executable: URL, _ arguments: [String], in directory: URL) throws -> Result {
        let process = Process()
        process.executableURL = executable
        // `-c core.quotepath=off` so a path with non-ASCII in it comes back as
        // itself rather than as octal escapes; `--no-optional-locks` so
        // asking for status never takes the index lock out from under a
        // `git commit` the user is running in a terminal at the same moment.
        process.arguments = ["--no-optional-locks", "-c", "core.quotepath=off"] + arguments
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["LC_ALL"] = "C"
        process.environment = environment

        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw GitError.notRunnable(error.localizedDescription)
        }
        // Both pipes drained at once: reading one to the end while git blocks
        // writing a full other one is a deadlock, and a large `cat-file` with
        // a warning on stderr is exactly that.
        final class Collected: @unchecked Sendable { var data = Data() }
        let errorData = Collected()
        let reader = error.fileHandleForReading
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errorData.data = reader.readDataToEndOfFile()
            group.leave()
        }
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        return Result(status: process.terminationStatus, output: outputData, error: errorData.data)
    }
}
