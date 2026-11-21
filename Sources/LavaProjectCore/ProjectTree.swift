import Foundation
import LavaExplorerCore

/// One file or folder in a project, named by its path from the project root.
public struct ProjectNode: Equatable, Hashable, Sendable {
    public var name: String
    /// `/`-separated, relative to the root; the root itself is `""`.
    public var path: String
    public var isDirectory: Bool

    public init(name: String, path: String, isDirectory: Bool) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
    }
}

/// One visible line of the tree.
public struct ProjectRow: Equatable, Identifiable, Sendable {
    public var node: ProjectNode
    /// The path within the open project, stable when selection or expansion changes.
    public var id: String { node.path }
    /// 0 for the root's own children.
    public var depth: Int
    public var isExpanded: Bool
}

/// The folder an editor has open, as far as anyone has looked into it.
///
/// Lazy: a folder is listed when it is first expanded and never before, so
/// opening a project with a `node_modules` or a build tree costs the root and
/// nothing else. What has been listed stays listed while collapsed — expanding
/// it again is instant, and `refresh` re-reads exactly the folders that are
/// being watched.
public struct ProjectTree: Sendable {
    public let root: URL
    /// Names never shown. `.git` is the repository's own storage, not the
    /// project's; everything else — dotfiles included — is something people
    /// edit.
    public var hidden: Set<String> = [".git"]
    public private(set) var listings: [String: [ProjectNode]] = [:]
    /// Expanded folders, by path. The root is always open.
    public private(set) var expanded: Set<String> = [""]

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    /// The URL of a path in the tree.
    public func url(of path: String) -> URL {
        path.isEmpty ? root : root.appendingPathComponent(path)
    }

    /// `url`'s path in the tree, or nil outside it.
    public func path(of url: URL) -> String? {
        let file = url.standardizedFileURL.path
        let top = root.path
        if file == top { return "" }
        let prefix = top.hasSuffix("/") ? top : top + "/"
        guard file.hasPrefix(prefix) else { return nil }
        return String(file.dropFirst(prefix.count))
    }

    // MARK: - Reading the disk

    /// Reads one folder: folders first, then files, each in natural order.
    /// Nil when it cannot be read — gone, or not ours to read.
    public static func list(
        _ directory: URL, path: String, hidden: Set<String>
    ) -> [ProjectNode]? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return nil
        }
        var folders: [ProjectNode] = []
        var files: [ProjectNode] = []
        for name in names where !hidden.contains(name) {
            var isDirectory: ObjCBool = false
            let full = directory.appendingPathComponent(name).path
            // Follows symlinks: a link to a folder opens like one. A loop is
            // harmless here, because nothing is listed until it is clicked.
            guard FileManager.default.fileExists(atPath: full, isDirectory: &isDirectory) else {
                // A dangling link still has a name worth seeing.
                files.append(ProjectNode(name: name, path: join(path, name), isDirectory: false))
                continue
            }
            let node = ProjectNode(name: name, path: join(path, name), isDirectory: isDirectory.boolValue)
            if node.isDirectory { folders.append(node) } else { files.append(node) }
        }
        folders.sort { FileName.compare($0.name, $1.name) }
        files.sort { FileName.compare($0.name, $1.name) }
        return folders + files
    }

    static func join(_ parent: String, _ name: String) -> String {
        parent.isEmpty ? name : parent + "/" + name
    }

    /// Lists `path` if it has not been, and reports whether anything changed.
    @discardableResult
    public mutating func load(_ path: String) -> Bool {
        guard listings[path] == nil else { return false }
        return reload(path)
    }

    /// Re-reads `path` whether or not it was listed. A folder that has gone
    /// takes its listing, and everything under it, with it.
    @discardableResult
    public mutating func reload(_ path: String) -> Bool {
        guard let nodes = Self.list(url(of: path), path: path, hidden: hidden) else {
            let had = listings[path] != nil
            forget(path)
            return had
        }
        guard listings[path] != nodes else { return false }
        // Folders that vanished from this one are forgotten with it, so a
        // folder deleted and recreated comes back collapsed and re-read.
        let kept = Set(nodes.filter(\.isDirectory).map(\.path))
        for old in listings[path] ?? [] where old.isDirectory && !kept.contains(old.path) {
            forget(old.path)
        }
        listings[path] = nodes
        return true
    }

    private mutating func forget(_ path: String) {
        let prefix = path + "/"
        listings = listings.filter { $0.key != path && !$0.key.hasPrefix(prefix) }
        if !path.isEmpty {
            expanded = expanded.filter { $0 != path && !$0.hasPrefix(prefix) }
        }
    }

    // MARK: - Opening and closing

    /// Opens or closes a folder, listing it on the way in.
    public mutating func toggle(_ path: String) {
        setExpanded(path, !expanded.contains(path))
    }

    public mutating func setExpanded(_ path: String, _ open: Bool) {
        guard !path.isEmpty else { return }
        if open {
            expanded.insert(path)
            load(path)
        } else {
            expanded.remove(path)
        }
    }

    /// Opens every folder above `path`, so that it is on a visible row.
    public mutating func reveal(_ path: String) {
        let parts = path.split(separator: "/")
        guard parts.count > 1 else { load(""); return }
        var current = ""
        load("")
        for part in parts.dropLast() {
            current = Self.join(current, String(part))
            setExpanded(current, true)
        }
    }

    /// Puts back a set of expanded folders, as saved by a previous session,
    /// listing each that still exists. Parents before children, so a folder
    /// whose parent is gone is dropped rather than shown at the wrong place.
    public mutating func restore(expanded saved: Set<String>) {
        load("")
        for path in saved.sorted(by: { $0.count < $1.count }) where !path.isEmpty {
            let parent = path.split(separator: "/").dropLast().joined(separator: "/")
            guard parent.isEmpty || expanded.contains(parent),
                  listings[parent]?.contains(where: { $0.path == path && $0.isDirectory }) == true
            else { continue }
            setExpanded(path, true)
        }
    }

    // MARK: - Showing

    /// The visible rows, top to bottom.
    public var rows: [ProjectRow] {
        var out: [ProjectRow] = []
        func walk(_ path: String, depth: Int) {
            for node in listings[path] ?? [] {
                let open = node.isDirectory && expanded.contains(node.path)
                out.append(ProjectRow(node: node, depth: depth, isExpanded: open))
                if open { walk(node.path, depth: depth + 1) }
            }
        }
        walk("", depth: 0)
        return out
    }

    /// Every folder whose contents are on screen: what a watcher should watch.
    public var visibleFolders: [String] {
        expanded.filter { path in
            guard listings[path] != nil else { return false }
            // Open but under a closed parent is not on screen.
            var parent = path
            while let slash = parent.lastIndex(of: "/") {
                parent = String(parent[..<slash])
                if !expanded.contains(parent) { return false }
            }
            return true
        }.sorted()
    }
}
