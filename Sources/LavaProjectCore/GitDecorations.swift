import LavaGitCore

/// What git says about one row of the tree.
public enum GitMark: Int, Comparable, Sendable {
    // Raw values rank how loudly a folder reports what is under it: one
    // conflict anywhere beneath outranks any number of edits.
    case ignored = 0
    case untracked
    case added
    case renamed
    case deleted
    case modified
    case conflicted

    public static func < (a: GitMark, b: GitMark) -> Bool { a.rawValue < b.rawValue }

    /// The letter shown beside a file, as `git status -s` and every editor
    /// with git in it write it. Nil for ignored, which is shown dimmed instead.
    public var letter: String? {
        switch self {
        case .ignored: return nil
        case .untracked: return "U"
        case .added: return "A"
        case .renamed: return "R"
        case .deleted: return "D"
        case .modified: return "M"
        case .conflicted: return "!"
        }
    }

    init?(_ entry: GitStatusEntry) {
        switch entry.kind {
        case .conflicted: self = .conflicted
        case .untracked: self = .untracked
        case .ignored: self = .ignored
        case .tracked:
            let sides = [entry.staged, entry.unstaged]
            if sides.contains(.deleted) {
                self = .deleted
            } else if sides.contains(.modified) || sides.contains(.typeChanged) {
                self = .modified
            } else if sides.contains(.added) {
                self = .added
            } else if sides.contains(.renamed) || sides.contains(.copied) {
                self = .renamed
            } else {
                return nil
            }
        }
    }
}

/// Git's status, keyed by path in the project tree, with every folder
/// carrying the loudest mark of anything beneath it — so a change three
/// folders down shows on the collapsed folder at the top.
public struct GitDecorations: Sendable, Equatable {
    private var files: [String: GitMark] = [:]
    private var folders: [String: GitMark] = [:]
    /// Ignored directories (git reports each once, not its contents).
    private var ignoredFolders: Set<String> = []

    public init() {}

    /// `repositoryPath` is where the repository's root is, as a path in the
    /// project tree: `""` when they are the same folder, `"vendor/lib"` when
    /// the repository is inside the project. Nil when the project is inside
    /// the repository instead, and then `projectPath` says where:
    /// `"Sources"` when the editor opened that folder of a larger checkout.
    public init(
        entries: [GitStatusEntry], repositoryPath: String? = "", projectPath: String = ""
    ) {
        for entry in entries {
            guard let mark = GitMark(entry) else { continue }
            var path = entry.path
            let isFolder = path.hasSuffix("/")
            if isFolder { path.removeLast() }
            // Into the tree's terms: under the repository's place in the
            // project, or out from under the project's place in the repository.
            if let repositoryPath {
                path = ProjectTree.join(repositoryPath, path)
            } else if !projectPath.isEmpty {
                let prefix = projectPath + "/"
                guard path.hasPrefix(prefix) else { continue }
                path = String(path.dropFirst(prefix.count))
            }
            if mark == .ignored {
                if isFolder { ignoredFolders.insert(path) } else { files[path] = mark }
                continue
            }
            if isFolder {
                // An untracked folder git did not open up (it does with
                // `--untracked-files=all`, but not every caller asks for that).
                folders[path] = max(folders[path] ?? mark, mark)
            } else {
                files[path] = max(files[path] ?? mark, mark)
            }
            var parent = path
            while let slash = parent.lastIndex(of: "/") {
                parent = String(parent[..<slash])
                folders[parent] = max(folders[parent] ?? mark, mark)
            }
        }
    }

    /// The mark for a row: its own for a file, the loudest beneath it for a
    /// folder, and `.ignored` for anything inside an ignored folder.
    public func mark(for node: ProjectNode) -> GitMark? {
        if isIgnored(node.path) { return .ignored }
        return node.isDirectory ? folders[node.path] : files[node.path]
    }

    private func isIgnored(_ path: String) -> Bool {
        if files[path] == .ignored || ignoredFolders.contains(path) { return true }
        var parent = path
        while let slash = parent.lastIndex(of: "/") {
            parent = String(parent[..<slash])
            if ignoredFolders.contains(parent) { return true }
        }
        return false
    }

    public var isEmpty: Bool { files.isEmpty && folders.isEmpty && ignoredFolders.isEmpty }
}
