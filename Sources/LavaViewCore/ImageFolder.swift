import Foundation

/// The pictures next to the one that was opened, and where we are in them.
///
/// A viewer is opened on a *file* and used on a *directory*: the argument says
/// which picture, and everything after that is Left and Right through its
/// neighbours. So the collection is derived from the file's parent rather than
/// asked for separately, and the file that was named keeps its position in the
/// list even if the scan cannot see it (a broken symlink, a race with a
/// deletion) — losing your place because the folder listing disagreed would be
/// the worst possible answer to "open this".
public struct ImageFolder: Equatable, Sendable {
    /// Absolute paths, in natural order.
    public private(set) var entries: [String]
    /// Index into `entries`, or nil when there is nothing to show.
    public private(set) var index: Int?

    public init(entries: [String] = [], index: Int? = nil) {
        self.entries = entries
        self.index = index.flatMap { entries.indices.contains($0) ? $0 : nil }
    }

    public var current: String? {
        guard let index else { return nil }
        return entries[index]
    }

    public var count: Int { entries.count }
    public var isEmpty: Bool { entries.isEmpty }

    /// One-based position, for the status bar. Zero when empty.
    public var position: Int { index.map { $0 + 1 } ?? 0 }

    // MARK: - Building

    /// Scans the directory containing `path` (or `path` itself, when it is a
    /// directory) and lands on the named file.
    public static func around(
        path: String, using fs: FileScanner = .real
    ) -> ImageFolder {
        let absolute = absolutePath(path)
        let directory = fs.isDirectory(absolute)
            ? absolute
            : (absolute as NSString).deletingLastPathComponent

        var names = fs.imageNames(directory)
        names.sort(by: NaturalOrder.compare)
        var entries = names.map { (directory as NSString).appendingPathComponent($0) }

        // A file that was named but is not in the listing is still what the
        // user asked for. Splice it in rather than opening its neighbour.
        var landing = entries.firstIndex(of: absolute)
        if landing == nil, !fs.isDirectory(absolute), fs.exists(absolute) {
            let name = (absolute as NSString).lastPathComponent
            let at = entries.firstIndex {
                NaturalOrder.compare(name, ($0 as NSString).lastPathComponent)
            } ?? entries.count
            entries.insert(absolute, at: at)
            landing = at
        }

        return ImageFolder(entries: entries, index: landing ?? (entries.isEmpty ? nil : 0))
    }

    /// The union of several arguments — `lavaview a.png b.png` — with no
    /// directory walk. Explicit arguments *are* the collection; a user who
    /// listed three files does not want the other four hundred in the folder.
    public static func explicit(paths: [String]) -> ImageFolder {
        let entries = paths.map(absolutePath).filter(ImageFormats.isImage(path:))
        return ImageFolder(entries: entries, index: entries.isEmpty ? nil : 0)
    }

    // MARK: - Moving

    /// Wraps at both ends, which is what "cycle" means and what every viewer
    /// with a Next button does. A single-image collection stays put.
    public func advanced(by step: Int) -> ImageFolder {
        guard let index, entries.count > 1, step != 0 else { return self }
        let n = entries.count
        let next = ((index + step) % n + n) % n
        return ImageFolder(entries: entries, index: next)
    }

    public func jumped(to target: Int) -> ImageFolder {
        guard !entries.isEmpty else { return self }
        return ImageFolder(
            entries: entries, index: min(max(0, target), entries.count - 1)
        )
    }

    /// Drops an entry that turned out not to be readable, landing on what
    /// would have come next. Without this, Right on a directory holding one
    /// corrupt file among many stops there and cannot get past it.
    public func removing(_ path: String) -> ImageFolder {
        guard let at = entries.firstIndex(of: path) else { return self }
        var next = entries
        next.remove(at: at)
        guard !next.isEmpty else { return ImageFolder() }
        return ImageFolder(entries: next, index: min(at, next.count - 1))
    }

    /// Re-reads the directory, keeping the current picture selected if it is
    /// still there. For the Reload command and for a folder written to while
    /// it is open.
    public func rescanned(using fs: FileScanner = .real) -> ImageFolder {
        guard let current else { return self }
        let fresh = ImageFolder.around(path: current, using: fs)
        return fresh.isEmpty ? ImageFolder() : fresh
    }

    static func absolutePath(_ path: String) -> String {
        let ns = path as NSString
        guard !ns.isAbsolutePath else { return ns.standardizingPath }
        let cwd = FileManager.default.currentDirectoryPath
        return ((cwd as NSString).appendingPathComponent(path) as NSString)
            .standardizingPath
    }
}

/// The three filesystem questions `ImageFolder` asks, behind a seam.
///
/// Only so the tests can answer them from a table. A directory walk is the one
/// part of this that cannot be checked without either a real folder on disk or
/// a stand-in, and a real folder makes the ordering tests depend on what a
/// temp directory happens to contain.
public struct FileScanner: Sendable {
    public var isDirectory: @Sendable (String) -> Bool
    public var exists: @Sendable (String) -> Bool
    /// Image file *names* directly inside a directory, unsorted.
    public var imageNames: @Sendable (String) -> [String]

    public init(
        isDirectory: @escaping @Sendable (String) -> Bool,
        exists: @escaping @Sendable (String) -> Bool,
        imageNames: @escaping @Sendable (String) -> [String]
    ) {
        self.isDirectory = isDirectory
        self.exists = exists
        self.imageNames = imageNames
    }

    public static let real = FileScanner(
        isDirectory: { path in
            var isDir: ObjCBool = false
            let there = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
            return there && isDir.boolValue
        },
        exists: { FileManager.default.fileExists(atPath: $0) },
        imageNames: { directory in
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
            // Hidden files are excluded on purpose: a folder of photographs
            // often carries a `.thumbnails` cache, and walking into it from
            // the Next key would be baffling.
            return names.filter { !$0.hasPrefix(".") && ImageFormats.isImage(path: $0) }
        }
    )
}
