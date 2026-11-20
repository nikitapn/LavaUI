import Foundation

/// One path from `git status --porcelain=v2 -z`.
public struct GitStatusEntry: Equatable, Sendable {
    /// What happened to a path on one side (staged, or in the working tree).
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

    /// Parses the NUL-separated output. Lines it does not understand — a newer
    /// git's additions, branch headers — are skipped rather than failing the
    /// whole status.
    public static func parse(_ data: Data) -> [GitStatusEntry] {
        var fields = data.split(separator: 0, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }[...]
        var out: [GitStatusEntry] = []
        while let record = fields.popFirst() {
            guard let tag = record.first else { continue }
            switch tag {
            case "1", "2", "u":
                // Fixed fields, then the path, which may itself hold spaces:
                // split only as far as the field count says.
                let fixed = tag == "1" ? 8 : tag == "2" ? 9 : 10
                let parts = record.split(separator: " ", maxSplits: fixed, omittingEmptySubsequences: false)
                guard parts.count == fixed + 1 else { continue }
                let xy = Array(parts[1])
                guard xy.count == 2 else { continue }
                var entry = GitStatusEntry(
                    path: String(parts[fixed]),
                    kind: tag == "u" ? .conflicted : .tracked,
                    staged: Change(rawValue: xy[0]) ?? .modified,
                    unstaged: Change(rawValue: xy[1]) ?? .modified
                )
                // A rename's original path is the next NUL-separated field.
                if tag == "2" { entry.originalPath = fields.popFirst() }
                out.append(entry)
            case "?":
                out.append(GitStatusEntry(
                    path: String(record.dropFirst(2)), kind: .untracked, unstaged: .added
                ))
            default:
                continue
            }
        }
        return out
    }
}
