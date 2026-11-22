import CGit2
import Foundation

/// A local branch, as the branch picker lists it.
public struct GitBranch: Sendable, Equatable {
    public let name: String
    /// Checked out in this working tree.
    public let isHead: Bool
    /// `origin/main`, when the branch tracks one.
    public let upstream: String?
    /// Commits on this branch and not on its upstream, and the other way.
    /// Zero for both without an upstream.
    public let ahead: Int
    public let behind: Int
    /// The tip's subject line.
    public let subject: String
    /// The tip's commit time, for putting the recent branches first.
    public let date: Date
}

/// One working tree of a repository: the main one, or one `git worktree add`
/// made.
public struct GitWorktree: Sendable, Equatable {
    /// The folder's name for a linked worktree; the main one is called by
    /// its folder too.
    public let name: String
    public let root: URL
    /// The branch it has checked out; nil while detached.
    public let branch: String?
    public let isMain: Bool
    public let isLocked: Bool

    public init(name: String, root: URL, branch: String?, isMain: Bool, isLocked: Bool) {
        self.name = name
        self.root = root
        self.branch = branch
        self.isMain = isMain
        self.isLocked = isLocked
    }
}

public enum GitCheckoutError: Error, Equatable, CustomStringConvertible {
    /// Files with changes the checkout would overwrite — what `git switch`
    /// refuses with "Your local changes … would be overwritten".
    case wouldOverwrite([String])
    /// A branch can be checked out in one working tree at a time.
    case checkedOutElsewhere(branch: String, worktree: URL)
    /// A merge, rebase or cherry-pick is in progress.
    case operationInProgress

    public var description: String {
        switch self {
        case .wouldOverwrite(let paths):
            let shown = paths.prefix(5).joined(separator: ", ")
            let more = paths.count > 5 ? " and \(paths.count - 5) more" : ""
            return "Your changes to \(shown)\(more) would be overwritten. Commit or discard them first."
        case .checkedOutElsewhere(let branch, let worktree):
            return "\(branch) is checked out in \(worktree.path)."
        case .operationInProgress:
            return "Finish or abort the merge or rebase in progress first."
        }
    }
}

extension GitRepository {
    /// Local branches, the one checked out first and the rest newest first.
    public func branches() throws -> [GitBranch] {
        let head = try branch()
        return try withRepository { repo in
            let iterator = try LibGit.check("branch") { git_branch_iterator_new(&$0, repo, GIT_BRANCH_LOCAL) }
            defer { git_branch_iterator_free(iterator) }
            var out: [GitBranch] = []
            var found: OpaquePointer?
            var type = GIT_BRANCH_LOCAL
            while git_branch_next(&found, &type, iterator) == 0, let ref = found {
                defer { git_reference_free(ref) }
                found = nil
                var cName: UnsafePointer<CChar>?
                guard git_branch_name(&cName, ref) == 0, let cName else { continue }
                let name = String(cString: cName)
                guard let tip = git_reference_target(ref) else { continue }

                var subject = ""
                var date = Date(timeIntervalSince1970: 0)
                var commit: OpaquePointer?
                if git_commit_lookup(&commit, repo, tip) == 0, let commit {
                    subject = git_commit_summary(commit).map { String(cString: $0) } ?? ""
                    date = Date(timeIntervalSince1970: TimeInterval(git_commit_time(commit)))
                    git_commit_free(commit)
                }

                var upstreamName: String?
                var ahead = 0, behind = 0
                var upstream: OpaquePointer?
                if git_branch_upstream(&upstream, ref) == 0, let upstream {
                    defer { git_reference_free(upstream) }
                    var cUpstream: UnsafePointer<CChar>?
                    if git_branch_name(&cUpstream, upstream) == 0, let cUpstream {
                        upstreamName = String(cString: cUpstream)
                    }
                    if let theirs = git_reference_target(upstream) {
                        var a = 0, b = 0
                        if git_graph_ahead_behind(&a, &b, repo, tip, theirs) == 0 {
                            ahead = a
                            behind = b
                        }
                    }
                }
                out.append(GitBranch(name: name, isHead: name == head, upstream: upstreamName,
                                     ahead: ahead, behind: behind, subject: subject, date: date))
            }
            return out.sorted {
                if $0.isHead != $1.isHead { return $0.isHead }
                if $0.date != $1.date { return $0.date > $1.date }
                return $0.name < $1.name
            }
        }
    }

    /// Every working tree of this repository, the main one first. A linked
    /// worktree whose folder is gone (`git worktree prune` would remove it)
    /// is left out: there is nothing to switch to.
    public func worktrees() throws -> [GitWorktree] {
        try withRepository { repo in
            guard let common = git_repository_commondir(repo) else { return [] }
            var main: OpaquePointer?
            guard git_repository_open_ext(&main, common, UInt32(GIT_REPOSITORY_OPEN_NO_SEARCH.rawValue), nil) == 0,
                  let main else { throw LibGit.error("worktree") }
            defer { git_repository_free(main) }

            var out: [GitWorktree] = []
            if git_repository_is_bare(main) == 0, let workdir = git_repository_workdir(main) {
                let root = URL(fileURLWithPath: String(cString: workdir), isDirectory: true).standardizedFileURL
                out.append(GitWorktree(name: root.lastPathComponent, root: root,
                                       branch: Self.branchName(of: main), isMain: true, isLocked: false))
            }

            var names = git_strarray()
            guard git_worktree_list(&names, main) == 0 else { return out }
            defer { git_strarray_dispose(&names) }
            for i in 0..<names.count {
                guard let cName = names.strings[i] else { continue }
                var found: OpaquePointer?
                guard git_worktree_lookup(&found, main, cName) == 0, let worktree = found else { continue }
                defer { git_worktree_free(worktree) }
                guard git_worktree_validate(worktree) == 0, let cPath = git_worktree_path(worktree) else { continue }
                let root = URL(fileURLWithPath: String(cString: cPath), isDirectory: true).standardizedFileURL
                var branch: String?
                var opened: OpaquePointer?
                if git_repository_open_from_worktree(&opened, worktree) == 0, let opened {
                    branch = Self.branchName(of: opened)
                    git_repository_free(opened)
                }
                out.append(GitWorktree(name: root.lastPathComponent, root: root, branch: branch,
                                       isMain: false, isLocked: git_worktree_is_locked(nil, worktree) > 0))
            }
            return out
        }
    }

    /// Checks `name` out in this working tree, the way `git switch` does:
    /// changes that the switch does not touch come along, and nothing is
    /// written at all if any change would be overwritten — the files are in
    /// the error instead.
    public func checkout(branch name: String) throws {
        if try branch() == name { return }
        // Asked before anything else: libgit2 would happily check a branch
        // out twice, and git refuses for good reason — a commit in one tree
        // moves the other's HEAD under its index.
        if let other = try worktrees().first(where: { $0.branch == name }) {
            throw GitCheckoutError.checkedOutElsewhere(branch: name, worktree: other.root)
        }
        try withRepository { repo in
            guard git_repository_state(repo) == Int32(GIT_REPOSITORY_STATE_NONE.rawValue) else {
                throw GitCheckoutError.operationInProgress
            }
            let ref = try LibGit.check("checkout") { git_branch_lookup(&$0, repo, name, GIT_BRANCH_LOCAL) }
            defer { git_reference_free(ref) }
            let commit = try LibGit.check("checkout") { git_reference_peel(&$0, ref, GIT_OBJECT_COMMIT) }
            defer { git_object_free(commit) }

            let conflicts = ConflictList()
            var options = git_checkout_options()
            git_checkout_options_init(&options, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))
            options.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue
            options.notify_flags = GIT_CHECKOUT_NOTIFY_CONFLICT.rawValue
            options.notify_cb = { _, path, _, _, _, payload in
                if let path, let payload {
                    Unmanaged<ConflictList>.fromOpaque(payload).takeUnretainedValue().paths.append(String(cString: path))
                }
                return 0
            }
            let result = withExtendedLifetime(conflicts) {
                options.notify_payload = Unmanaged.passUnretained(conflicts).toOpaque()
                return git_checkout_tree(repo, commit, &options)
            }
            // A conflict is found before the first file is written, so the
            // working tree is as it was.
            if result == GIT_ECONFLICT.rawValue || !conflicts.paths.isEmpty {
                throw GitCheckoutError.wouldOverwrite(conflicts.paths.sorted())
            }
            guard result == 0 else { throw LibGit.error("checkout") }
            try LibGit.check("checkout") { git_repository_set_head(repo, "refs/heads/" + name) }
        }
    }

    /// HEAD's branch in an open repository, nil while detached.
    static func branchName(of repo: OpaquePointer) -> String? {
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

private final class ConflictList {
    var paths: [String] = []
}
