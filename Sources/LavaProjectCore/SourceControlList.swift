import LavaGitCore

/// What the Source Control panel lists, worked out from git's status: the
/// staged changes, then the rest — VS Code's two groups.
///
/// One status entry can be in both: a file staged and then edited again has a
/// staged change *and* an unstaged one, and each group shows its half.
public struct SourceControlList: Equatable, Sendable {
    public enum Group: String, Sendable {
        case staged
        case changes
        /// Conflicts get a group of their own, first: they block a commit,
        /// and are the one thing in the list that has to be dealt with.
        case conflicts

        public var title: String {
            switch self {
            case .staged: return "Staged Changes"
            case .changes: return "Changes"
            case .conflicts: return "Merge Changes"
            }
        }
    }

    public struct Item: Equatable, Sendable {
        /// Repository-relative, `/`-separated.
        public var path: String
        public var originalPath: String?
        public var group: Group
        /// The change on this group's side.
        public var change: GitStatusEntry.Change
        public var isUntracked: Bool

        public var name: Substring { path.split(separator: "/").last ?? Substring(path) }
        /// The folder, for showing dimmed beside the name; empty at the top.
        public var folder: String {
            guard let slash = path.lastIndex(of: "/") else { return "" }
            return String(path[..<slash])
        }

        /// The letter VS Code puts at the end of the row.
        public var letter: String {
            if group == .conflicts { return "!" }
            if isUntracked { return "U" }
            switch change {
            case .added: return "A"
            case .deleted: return "D"
            case .renamed: return "R"
            case .copied: return "C"
            case .typeChanged: return "T"
            case .updatedUnmerged: return "!"
            case .modified, .unmodified: return "M"
            }
        }

        /// The paths a stage or unstage has to name: a rename is both ends.
        public var paths: [String] {
            [path] + (originalPath.map { [$0] } ?? [])
        }
    }

    public private(set) var conflicts: [Item] = []
    public private(set) var staged: [Item] = []
    public private(set) var changes: [Item] = []

    public init() {}

    public init(_ entries: [GitStatusEntry]) {
        for entry in entries {
            switch entry.kind {
            case .ignored:
                continue
            case .conflicted:
                conflicts.append(Item(path: entry.path, group: .conflicts,
                                      change: .updatedUnmerged, isUntracked: false))
            case .untracked:
                changes.append(Item(path: entry.path, group: .changes,
                                    change: .added, isUntracked: true))
            case .tracked:
                if entry.staged != .unmodified {
                    staged.append(Item(path: entry.path, originalPath: entry.originalPath,
                                       group: .staged, change: entry.staged, isUntracked: false))
                }
                if entry.unstaged != .unmodified {
                    changes.append(Item(path: entry.path, group: .changes,
                                        change: entry.unstaged, isUntracked: false))
                }
            }
        }
        // By path, as git itself and VS Code list them.
        let byPath: (Item, Item) -> Bool = { $0.path < $1.path }
        conflicts.sort(by: byPath)
        staged.sort(by: byPath)
        changes.sort(by: byPath)
    }

    public func items(_ group: Group) -> [Item] {
        switch group {
        case .conflicts: return conflicts
        case .staged: return staged
        case .changes: return changes
        }
    }

    /// Groups to show, in order: a group with nothing in it is not shown,
    /// except Changes, which says "nothing" when everything is committed.
    public var groups: [Group] {
        var out: [Group] = []
        if !conflicts.isEmpty { out.append(.conflicts) }
        if !staged.isEmpty { out.append(.staged) }
        out.append(.changes)
        return out
    }

    public var isClean: Bool { conflicts.isEmpty && staged.isEmpty && changes.isEmpty }

    /// One line of the panel: a group's header, or a file in it.
    public enum Row: Equatable, Identifiable, Sendable {
        case header(Group, count: Int)
        case item(Item)

        /// Stable while the status refreshes, so the list keeps the row's
        /// node — and the renderer its hover. Carries the group: a file
        /// staged and then edited again is a row in each.
        public var id: String {
            switch self {
            case .header(let group, _): return "h:" + group.rawValue
            case .item(let item): return item.group.rawValue + ":" + item.path
            }
        }
    }

    /// The rows to draw, with the groups in `collapsed` showing only their
    /// header.
    public func rows(collapsed: Set<Group> = []) -> [Row] {
        var out: [Row] = []
        for group in groups {
            let items = items(group)
            out.append(.header(group, count: items.count))
            if !collapsed.contains(group) { out += items.map(Row.item) }
        }
        return out
    }
}
