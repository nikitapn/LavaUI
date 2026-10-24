import Foundation

/// Files going to or from a server, sorted out before anything moves.
///
/// The same split as `CopyPlan`: which names are already taken is a question
/// for the user before the first byte, not something to find out halfway.
/// Only the top level is planned. What is inside a folder goes where the
/// folder goes, and a folder that is already there is merged into.
public struct RemoteTransferPlan: Equatable, Sendable {
    public enum Direction: Equatable, Sendable {
        /// Local files into a folder on a server.
        case upload(into: RemoteURL)
        /// A server's files into a local folder.
        case download(into: String)
    }

    public struct Item: Equatable, Sendable {
        /// A local path for an upload, a remote address for a download.
        public var source: String
        public var name: String
        public var isDirectory: Bool
        /// Bytes, when known — a file's size; nil for a folder.
        public var size: Int64?
        public var clashes: Bool
    }

    public var direction: Direction
    public var items: [Item]
    /// Names already in the destination, for `CopyNaming.keepBoth`.
    public var taken: Set<String>

    public var clashes: [Item] { items.filter(\.clashes) }

    /// The destination as a title, for the status line.
    public var destinationTitle: String {
        switch direction {
        case .upload(let folder): return folder.name
        case .download(let folder): return (folder as NSString).lastPathComponent
        }
    }

    /// Local paths into `folder`, against what the server last listed there.
    public static func upload(
        _ paths: [String], into folder: RemoteURL, existing: [FileEntry],
        entry: (String) -> FileEntry? = { try? LocalFileSource().entry(at: $0) }
    ) -> RemoteTransferPlan {
        var plan = RemoteTransferPlan(
            direction: .upload(into: folder), items: [],
            taken: Set(existing.map(\.name))
        )
        var names = Set<String>()
        for path in paths {
            guard let found = entry(path), names.insert(found.name).inserted else { continue }
            plan.items.append(Item(
                source: found.path, name: found.name, isDirectory: found.isDirectory,
                size: found.isDirectory ? nil : found.size,
                clashes: plan.taken.contains(found.name)
            ))
        }
        return plan
    }

    /// A server's rows into the local `folder`.
    public static func download(
        _ entries: [FileEntry], into folder: String,
        exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> RemoteTransferPlan {
        var plan = RemoteTransferPlan(direction: .download(into: folder), items: [], taken: [])
        var names = Set<String>()
        for entry in entries where names.insert(entry.name).inserted {
            let taken = exists(CopyPaths.join(folder, entry.name))
            if taken { plan.taken.insert(entry.name) }
            plan.items.append(Item(
                source: entry.path, name: entry.name, isDirectory: entry.isDirectory,
                size: entry.isDirectory ? nil : entry.size, clashes: taken
            ))
        }
        return plan
    }

    /// The name `item` goes in under for `choice`, or nil to leave it out.
    public func destinationName(of item: Item, _ choice: ClashChoice) -> String? {
        guard item.clashes else { return item.name }
        switch choice {
        case .skip: return nil
        case .replace: return item.name
        case .keepBoth:
            return CopyNaming.keepBoth(item.name, isDirectory: item.isDirectory, in: "/") {
                taken.contains(($0 as NSString).lastPathComponent)
            }
        }
    }
}

/// How a transfer went.
public struct RemoteTransferOutcome: Equatable, Sendable {
    public var done = 0
    public var skipped = 0
    public var cancelled = false
    public var failures: [FileAccessError] = []
    /// The first failure that was the server's to explain — a login refused
    /// mid-way, say — for the window to act on.
    public var error: RemoteError?

    public init() {}
}

/// Where a remote file is put to be opened: under the user's cache, by
/// server and path, so opening it twice opens one copy.
public enum RemoteCache {
    public static func path(for file: RemoteURL, cacheRoot: String) -> String {
        let server = file.server.prefix
            .replacingOccurrences(of: "://", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        // `~` is a folder name like any other down here.
        return cacheRoot + "/" + server + file.path
    }

    /// `$XDG_CACHE_HOME/lava-explorer/remote`, or `~/.cache/…`.
    public static var root: String {
        let env = ProcessInfo.processInfo.environment
        let base = env["XDG_CACHE_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? RemoteCache.home + "/.cache"
        return base + "/lava-explorer/remote"
    }

    /// `$HOME`, the way curl and every XDG lookup read it, and only then the
    /// password database. `NSHomeDirectory()` goes straight to the latter on
    /// Linux, so a session started with another home — a test, `sudo -E` —
    /// would have written into the user's own.
    public static var home: String {
        let env = ProcessInfo.processInfo.environment
        return env["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
    }
}
