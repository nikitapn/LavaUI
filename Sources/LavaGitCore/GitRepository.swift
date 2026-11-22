import CGit2
import Foundation

/// A git working tree, through libgit2.
///
/// A library rather than the `git` command: a question is a few file reads
/// in this process instead of a fork and exec, which is what refreshing the
/// tree's letters after every save, or the gutter's copy of HEAD for every
/// file opened, wants. Anything per-keystroke still diffs in memory against a
/// text fetched once.
///
/// One exception goes through the command on purpose: a commit in a
/// repository that signs commits or has commit hooks. libgit2 runs neither,
/// and a commit that quietly skipped the user's `pre-commit` or came out
/// unsigned would be worse than the fork it saves — see `commit`.
///
/// Each call opens the repository afresh, so the index and refs are read as
/// they are now, not as a cached handle last saw them, and nothing is shared
/// between threads. Every call is blocking. Run them off the frame loop.
public struct GitRepository: Sendable, Equatable {
    /// The top of the working tree.
    public let root: URL
    /// The `git` binary, for the commits libgit2 cannot make faithfully.
    public let executable: URL

    /// Creates a handle on a known working tree, without checking it is one.
    public init(root: URL, executable: URL = GitRepository.defaultExecutable) {
        self.root = root.standardizedFileURL
        self.executable = executable
    }

    /// The working tree containing `url` (a file or a directory), or nil when
    /// it is in none, or only in a bare repository.
    public static func containing(
        _ url: URL, executable: URL = GitRepository.defaultExecutable
    ) -> GitRepository? {
        LibGit.initialize()
        var directory = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory)
            || !isDirectory.boolValue
        {
            directory = directory.deletingLastPathComponent()
        }
        var repo: OpaquePointer?
        guard git_repository_open_ext(&repo, directory.path, 0, nil) == 0, let repo else { return nil }
        defer { git_repository_free(repo) }
        guard let workdir = git_repository_workdir(repo) else { return nil }
        return GitRepository(
            root: URL(fileURLWithPath: String(cString: workdir), isDirectory: true),
            executable: executable
        )
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
    }

    /// What `file` held at `revision`.
    public enum Contents: Sendable, Equatable {
        case text(String)
        /// It was not tracked there — a new file, or HEAD before the first commit.
        case absent
        /// Not valid UTF-8, so a text diff cannot show it.
        case binary
    }

    /// The contents of `url` at `revision`: the blob as stored, with no
    /// filters run — a file under LFS is its pointer on both sides, and
    /// line endings are what the commit holds.
    public func contents(of url: URL, at revision: Revision = .head) throws -> Contents {
        guard let path = relativePath(of: url) else { return .absent }
        return try withRepository { repo in
            let blobID: git_oid
            switch revision {
            case .index:
                let index = try LibGit.check("index") { git_repository_index(&$0, repo) }
                defer { git_index_free(index) }
                guard let entry = git_index_get_bypath(index, path, 0) else { return .absent }
                blobID = entry.pointee.id
            case .head, .commit:
                let spec: String
                if case .commit(let name) = revision { spec = name } else { spec = "HEAD" }
                var object: OpaquePointer?
                guard git_revparse_single(&object, repo, spec) == 0, let object else { return .absent }
                defer { git_object_free(object) }
                var peeled: OpaquePointer?
                guard git_object_peel(&peeled, object, GIT_OBJECT_TREE) == 0, let tree = peeled else {
                    return .absent
                }
                defer { git_object_free(tree) }
                var found: OpaquePointer?
                guard git_tree_entry_bypath(&found, tree, path) == 0, let entry = found else { return .absent }
                defer { git_tree_entry_free(entry) }
                // A directory or a submodule at that path is not a file there.
                guard git_tree_entry_type(entry) == GIT_OBJECT_BLOB else { return .absent }
                blobID = git_tree_entry_id(entry).pointee
            }
            var id = blobID
            var found: OpaquePointer?
            guard git_blob_lookup(&found, repo, &id) == 0, let blob = found else { return .absent }
            defer { git_blob_free(blob) }
            let size = Int(git_blob_rawsize(blob))
            let data = size == 0 ? Data() : Data(bytes: git_blob_rawcontent(blob), count: size)
            guard let text = String(data: data, encoding: .utf8) else { return .binary }
            return .text(text)
        }
    }

    /// The working tree's status: what is modified, staged, new or in conflict.
    ///
    /// Untracked directories are listed file by file. With `ignored`, also
    /// what the ignore rules match — an ignored directory as one entry with a
    /// trailing `/`, rather than every file under it.
    ///
    /// Read-only: the index's cached file times are not refreshed, so asking
    /// never takes the index lock out from under a `git commit` the user is
    /// running in a terminal at the same moment.
    public func status(ignored: Bool = false) throws -> [GitStatusEntry] {
        try withRepository { repo in
            var options = git_status_options()
            git_status_options_init(&options, UInt32(GIT_STATUS_OPTIONS_VERSION))
            options.show = GIT_STATUS_SHOW_INDEX_AND_WORKDIR
            var flags = GIT_STATUS_OPT_INCLUDE_UNTRACKED.rawValue
                | GIT_STATUS_OPT_RECURSE_UNTRACKED_DIRS.rawValue
                | GIT_STATUS_OPT_RENAMES_HEAD_TO_INDEX.rawValue
            if ignored { flags |= GIT_STATUS_OPT_INCLUDE_IGNORED.rawValue }
            options.flags = flags
            let list = try LibGit.check("status") { git_status_list_new(&$0, repo, &options) }
            defer { git_status_list_free(list) }
            var out: [GitStatusEntry] = []
            for i in 0..<git_status_list_entrycount(list) {
                guard let entry = git_status_byindex(list, i)?.pointee,
                      let status = GitStatusEntry(entry) else { continue }
                out.append(status)
            }
            return out
        }
    }

    // MARK: - Changing things

    /// Stages `paths` — new, modified and deleted alike, as `git add -A`.
    /// Each path is a file, taken literally: `[1].txt` is that file, not a
    /// pattern. Staging a conflicted file marks it resolved.
    public func stage(_ paths: [String]) throws {
        guard !paths.isEmpty else { return }
        try withIndex("add") { _, index in
            for path in paths {
                let file = root.appendingPathComponent(path)
                if (try? file.checkResourceIsReachable()) == true || Self.isSymlink(file) {
                    try LibGit.check("add") { git_index_add_bypath(index, path) }
                } else {
                    try LibGit.check("add") { git_index_remove_bypath(index, path) }
                }
            }
        }
    }

    /// Takes `paths` out of the index, back to what HEAD has — leaving the
    /// working tree alone. Before the first commit there is no HEAD to go
    /// back to, so the files are simply untracked again.
    public func unstage(_ paths: [String]) throws {
        guard !paths.isEmpty else { return }
        try withIndex("restore") { repo, index in
            let tree = Self.headTree(repo)
            defer { if let tree { git_tree_free(tree) } }
            for path in paths {
                var found: OpaquePointer?
                if let tree, git_tree_entry_bypath(&found, tree, path) == 0, let entry = found {
                    defer { git_tree_entry_free(entry) }
                    // What `git reset` writes: HEAD's blob and mode, with no
                    // stat data, so the next status looks at the file afresh.
                    var source = git_index_entry()
                    source.mode = git_tree_entry_filemode(entry).rawValue
                    source.id = git_tree_entry_id(entry).pointee
                    try path.withCString { name in
                        source.path = name
                        try LibGit.check("restore") { git_index_add(index, &source) }
                    }
                } else {
                    try LibGit.check("restore") { git_index_remove_bypath(index, path) }
                }
            }
        }
    }

    /// Throws away unstaged changes to tracked `paths`: the working tree
    /// goes back to what the index has, so anything staged survives.
    /// Untracked files are not git's to restore — the caller removes those.
    public func discard(_ paths: [String]) throws {
        guard !paths.isEmpty else { return }
        try withRepository { repo in
            var options = git_checkout_options()
            git_checkout_options_init(&options, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))
            options.checkout_strategy = GIT_CHECKOUT_FORCE.rawValue
                | GIT_CHECKOUT_DISABLE_PATHSPEC_MATCH.rawValue
            try LibGit.withStrings(paths) { array in
                options.paths = array
                try LibGit.check("restore") { git_checkout_index(repo, nil, &options) }
            }
        }
    }

    /// Commits what is staged, or — with `all` — everything, untracked files
    /// included, as VS Code's "smart commit" does when nothing is staged.
    /// Returns the new commit's one-line summary.
    ///
    /// Concluding a merge commits with both parents and clears the merge
    /// state, as `git commit` does. When the repository signs commits
    /// (`commit.gpgsign`) or has a commit hook, the commit is made by the
    /// `git` command instead: libgit2 runs neither, and leaving them out
    /// silently is not a choice this should make for the user.
    @discardableResult
    public func commit(message: String, all: Bool = false) throws -> String {
        if all {
            try withIndex("add") { _, index in
                try LibGit.check("add") { git_index_add_all(index, nil, 0, nil, nil) }
                try LibGit.check("add") { git_index_update_all(index, nil, nil, nil) }
            }
        }
        if try needsCommand() {
            try GitCommand.check("commit", executable, ["commit", "-q", "-m", message], in: root)
            return try withRepository { try Self.summary(of: "HEAD", in: $0) }
        }
        return try withRepository { repo in
            // The cleanup `git commit -m` does: trailing whitespace, and
            // blank lines at the ends and in runs. Comments are kept — with
            // `-m` a `#` line is something the user typed.
            var cleaned = git_buf()
            defer { git_buf_dispose(&cleaned) }
            try LibGit.check("commit") { git_message_prettify(&cleaned, message, 0, 35) }
            guard cleaned.size > 0, let cleanedText = cleaned.ptr else {
                throw GitError.failed(command: "commit", message: "Aborting commit due to empty commit message.")
            }

            let index = try LibGit.check("commit") { git_repository_index(&$0, repo) }
            defer { git_index_free(index) }
            guard git_index_has_conflicts(index) == 0 else {
                throw GitError.failed(command: "commit", message: "Committing is not possible because you have unmerged files.")
            }
            var treeID = git_oid()
            try LibGit.check("commit") { git_index_write_tree(&treeID, index) }
            let tree = try LibGit.check("commit") { git_tree_lookup(&$0, repo, &treeID) }
            defer { git_tree_free(tree) }

            var parents: [OpaquePointer?] = []
            defer { parents.forEach { git_commit_free($0) } }
            var headID = git_oid()
            if git_reference_name_to_id(&headID, repo, "HEAD") == 0 {
                parents.append(try LibGit.check("commit") { git_commit_lookup(&$0, repo, &headID) })
            }
            let merging = git_repository_state(repo) == Int32(GIT_REPOSITORY_STATE_MERGE.rawValue)
            if merging {
                final class Heads { var ids: [git_oid] = [] }
                let heads = Heads()
                _ = git_repository_mergehead_foreach(repo, { id, payload in
                    Unmanaged<Heads>.fromOpaque(payload!).takeUnretainedValue().ids.append(id!.pointee)
                    return 0
                }, Unmanaged.passUnretained(heads).toOpaque())
                for var id in heads.ids {
                    parents.append(try LibGit.check("commit") { git_commit_lookup(&$0, repo, &id) })
                }
            }
            // Nothing staged: the tree is the parent's, or empty before the
            // first commit. A merge is a commit whatever its tree.
            if !merging {
                let unchanged = parents.first.map { git_oid_equal(git_commit_tree_id($0), &treeID) != 0 }
                    ?? (git_index_entrycount(index) == 0)
                if unchanged {
                    throw GitError.failed(command: "commit", message: "nothing to commit, working tree clean")
                }
            }

            var signature: UnsafeMutablePointer<git_signature>?
            guard git_signature_default(&signature, repo) >= 0 else { throw LibGit.error("commit") }
            defer { git_signature_free(signature) }
            var commitID = git_oid()
            try parents.withUnsafeMutableBufferPointer { buffer in
                let result = git_commit_create(
                    &commitID, repo, "HEAD", signature, signature, nil, cleanedText, tree,
                    buffer.count, buffer.baseAddress
                )
                guard result >= 0 else { throw LibGit.error("commit") }
            }
            if merging { git_repository_state_cleanup(repo) }
            return try Self.summary(of: "HEAD", in: repo)
        }
    }

    /// Whether HEAD points at a commit — false in a repository that has
    /// never been committed to.
    public func hasCommits() throws -> Bool {
        try withRepository { repo in
            var id = git_oid()
            return git_reference_name_to_id(&id, repo, "HEAD") == 0
        }
    }

    /// The current branch, or nil when HEAD is detached. Before the first
    /// commit, the branch the first commit will go on.
    public func branch() throws -> String? {
        try withRepository { repo in
            var found: OpaquePointer?
            guard git_reference_lookup(&found, repo, "HEAD") == 0, let head = found else { return nil }
            defer { git_reference_free(head) }
            guard git_reference_type(head) == GIT_REFERENCE_SYMBOLIC,
                  let target = git_reference_symbolic_target(head) else { return nil }
            let name = String(cString: target)
            let prefix = "refs/heads/"
            return name.hasPrefix(prefix) ? String(name.dropFirst(prefix.count)) : name
        }
    }

    // MARK: - Plumbing

    private func withRepository<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        LibGit.initialize()
        let repo = try LibGit.check("open") {
            git_repository_open_ext(&$0, root.path, UInt32(GIT_REPOSITORY_OPEN_NO_SEARCH.rawValue), nil)
        }
        defer { git_repository_free(repo) }
        return try body(repo)
    }

    /// Changes the index and writes it back, under git's own `index.lock`.
    private func withIndex(_ name: String, _ body: (OpaquePointer, OpaquePointer) throws -> Void) throws {
        try withRepository { repo in
            let index = try LibGit.check(name) { git_repository_index(&$0, repo) }
            defer { git_index_free(index) }
            try body(repo, index)
            try LibGit.check(name) { git_index_write(index) }
        }
    }

    private static func headTree(_ repo: OpaquePointer) -> OpaquePointer? {
        var object: OpaquePointer?
        guard git_revparse_single(&object, repo, "HEAD^{tree}") == 0 else { return nil }
        return object
    }

    private static func isSymlink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    /// `%h %s` — the abbreviated hash and the subject line.
    private static func summary(of spec: String, in repo: OpaquePointer) throws -> String {
        let object = try LibGit.check("log") { git_revparse_single(&$0, repo, spec) }
        defer { git_object_free(object) }
        var short = git_buf()
        defer { git_buf_dispose(&short) }
        try LibGit.check("log") { git_object_short_id(&short, object) }
        let hash = short.ptr.map { String(cString: $0) } ?? ""
        let subject = git_commit_summary(object).map { String(cString: $0) } ?? ""
        return "\(hash) \(subject)"
    }

    /// Whether a commit here has to run things libgit2 does not: signing,
    /// or one of the hooks `git commit` runs.
    private func needsCommand() throws -> Bool {
        try withRepository { repo in
            var config: OpaquePointer?
            guard git_repository_config_snapshot(&config, repo) == 0, let config else { return false }
            defer { git_config_free(config) }
            var sign: Int32 = 0
            if git_config_get_bool(&sign, config, "commit.gpgsign") == 0, sign != 0 { return true }

            var hooks: URL
            var configured = git_buf()
            defer { git_buf_dispose(&configured) }
            if git_config_get_path(&configured, config, "core.hooksPath") == 0, let path = configured.ptr {
                hooks = URL(fileURLWithPath: String(cString: path), relativeTo: root)
            } else {
                var item = git_buf()
                defer { git_buf_dispose(&item) }
                guard git_repository_item_path(&item, repo, GIT_REPOSITORY_ITEM_HOOKS) == 0,
                      let path = item.ptr else { return false }
                hooks = URL(fileURLWithPath: String(cString: path), isDirectory: true)
            }
            return ["pre-commit", "prepare-commit-msg", "commit-msg", "post-commit"].contains {
                FileManager.default.isExecutableFile(atPath: hooks.appendingPathComponent($0).path)
            }
        }
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

/// libgit2's global state and its error convention.
enum LibGit {
    private static let initialized: Bool = {
        git_libgit2_init()
        return true
    }()

    /// Once per process; libgit2 counts, so this never needs undoing.
    static func initialize() { _ = initialized }

    /// The last error libgit2 recorded on this thread, as `GitError`.
    static func error(_ name: String) -> GitError {
        let message = git_error_last().flatMap { $0.pointee.message.map { String(cString: $0) } }
        return .failed(command: name, message: message ?? "unknown error")
    }

    @discardableResult
    static func check(_ name: String, _ call: () -> Int32) throws -> Int32 {
        let result = call()
        guard result >= 0 else { throw error(name) }
        return result
    }

    /// For the `git_x_new(&out, …)` shape: the object, or the error.
    static func check(_ name: String, _ call: (inout OpaquePointer?) -> Int32) throws -> OpaquePointer {
        var out: OpaquePointer?
        guard call(&out) >= 0, let out else { throw error(name) }
        return out
    }

    /// `strings` as a `git_strarray` for the length of `body`.
    static func withStrings<T>(_ strings: [String], _ body: (git_strarray) throws -> T) rethrows -> T {
        var pointers = strings.map { strdup($0) }
        defer { pointers.forEach { free($0) } }
        return try pointers.withUnsafeMutableBufferPointer { buffer in
            try body(git_strarray(strings: buffer.baseAddress, count: buffer.count))
        }
    }
}

/// The `git` command, for the commits libgit2 cannot make faithfully.
enum GitCommand {
    static func check(_ name: String, _ executable: URL, _ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        let error = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = error
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw GitError.notRunnable(error.localizedDescription)
        }
        let message = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw GitError.failed(
                command: name,
                message: String(decoding: message, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }
}
