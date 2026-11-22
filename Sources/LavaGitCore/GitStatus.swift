import CGit2
import Foundation

/// One path in the working tree's status.
public struct GitStatusEntry: Equatable, Sendable {
    /// What happened to a path on one side (staged, or in the working tree),
    /// by the letter `git status --short` gives it.
    public enum Change: Character, Equatable, Sendable {
        case unmodified = "."
        case modified = "M"
        case typeChanged = "T"
        case added = "A"
        case deleted = "D"
        case renamed = "R"
        case copied = "C"
        case updatedUnmerged = "U"
    }

    public enum Kind: Equatable, Sendable {
        /// Tracked, and changed in the index, the working tree or both.
        case tracked
        /// Not tracked and not ignored.
        case untracked
        /// Both sides of a merge touched it and it is not resolved.
        case conflicted
        /// Matches an ignore pattern. A directory is reported once, with a
        /// trailing `/`, and nothing inside it is listed.
        case ignored
    }

    /// Relative to the repository root, `/`-separated.
    public var path: String
    /// Where it was renamed or copied from.
    public var originalPath: String?
    public var kind: Kind
    /// What is staged.
    public var staged: Change
    /// What is in the working tree and not staged.
    public var unstaged: Change

    public init(
        path: String, originalPath: String? = nil, kind: Kind,
        staged: Change = .unmodified, unstaged: Change = .unmodified
    ) {
        self.path = path
        self.originalPath = originalPath
        self.kind = kind
        self.staged = staged
        self.unstaged = unstaged
    }

    /// libgit2's record for a path, or nil for one that says nothing changed.
    init?(_ entry: git_status_entry) {
        let flags = entry.status.rawValue
        func has(_ flag: git_status_t) -> Bool { flags & flag.rawValue != 0 }
        // The staged side names the path as it is in the index, the
        // unstaged side as it is on disk; either is the path for a row.
        let staged = entry.head_to_index?.pointee
        let unstaged = entry.index_to_workdir?.pointee
        guard let delta = unstaged ?? staged,
              let newPath = delta.new_file.path ?? delta.old_file.path else { return nil }
        let path = String(cString: newPath)

        if has(GIT_STATUS_CONFLICTED) {
            self.init(path: path, kind: .conflicted, staged: .updatedUnmerged, unstaged: .updatedUnmerged)
            return
        }
        if has(GIT_STATUS_IGNORED) {
            self.init(path: path, kind: .ignored)
            return
        }
        if has(GIT_STATUS_WT_NEW), flags & Self.indexFlags == 0 {
            self.init(path: path, kind: .untracked, unstaged: .added)
            return
        }

        var stagedChange = Change.unmodified
        if has(GIT_STATUS_INDEX_NEW) { stagedChange = .added }
        else if has(GIT_STATUS_INDEX_MODIFIED) { stagedChange = .modified }
        else if has(GIT_STATUS_INDEX_DELETED) { stagedChange = .deleted }
        else if has(GIT_STATUS_INDEX_RENAMED) { stagedChange = .renamed }
        else if has(GIT_STATUS_INDEX_TYPECHANGE) { stagedChange = .typeChanged }

        var unstagedChange = Change.unmodified
        if has(GIT_STATUS_WT_MODIFIED) { unstagedChange = .modified }
        else if has(GIT_STATUS_WT_DELETED) { unstagedChange = .deleted }
        else if has(GIT_STATUS_WT_RENAMED) { unstagedChange = .renamed }
        else if has(GIT_STATUS_WT_TYPECHANGE) { unstagedChange = .typeChanged }

        guard stagedChange != .unmodified || unstagedChange != .unmodified else { return nil }
        var original: String?
        if stagedChange == .renamed, let staged, let old = staged.old_file.path {
            original = String(cString: old)
        }
        self.init(path: path, originalPath: original, kind: .tracked,
                  staged: stagedChange, unstaged: unstagedChange)
    }

    private static let indexFlags = GIT_STATUS_INDEX_NEW.rawValue | GIT_STATUS_INDEX_MODIFIED.rawValue
        | GIT_STATUS_INDEX_DELETED.rawValue | GIT_STATUS_INDEX_RENAMED.rawValue
        | GIT_STATUS_INDEX_TYPECHANGE.rawValue
}
