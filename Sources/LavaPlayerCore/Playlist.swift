import Foundation

/// What is queued, and where we are in it.
///
/// Two shapes, from how the player was opened, and they differ in one way
/// that matters: whether reaching the end of a file starts the next one.
///
///   * **A list** — several files on the command line, or dropped at once.
///     The user said "these", so they play through.
///   * **A folder** — one file opened. Its neighbours are there for Next and
///     Previous, because the next thing anyone does after an episode is reach
///     for the following one; but a film that finishes and starts the
///     unrelated file beside it would be a surprise, so it stops.
public struct Playlist: Equatable, Sendable {
    public private(set) var entries: [String]
    public private(set) var index: Int?
    /// Whether the end of one entry starts the next. See the type.
    public let playsThrough: Bool

    public init(entries: [String] = [], index: Int? = nil, playsThrough: Bool = false) {
        self.entries = entries
        self.index = index.flatMap { entries.indices.contains($0) ? $0 : nil }
        self.playsThrough = playsThrough
    }

    public var current: String? { index.map { entries[$0] } }
    public var count: Int { entries.count }
    public var isEmpty: Bool { entries.isEmpty }
    /// One-based, for the title bar. Zero when empty.
    public var position: Int { index.map { $0 + 1 } ?? 0 }
    public var hasNext: Bool { index.map { $0 + 1 < entries.count } ?? false }
    public var hasPrevious: Bool { index.map { $0 > 0 } ?? false }

    /// Stops at the ends rather than wrapping: the episode after the last one
    /// is not the first one.
    public func stepped(by step: Int) -> Playlist {
        guard let index else { return self }
        let next = index + step
        guard entries.indices.contains(next) else { return self }
        return Playlist(entries: entries, index: next, playsThrough: playsThrough)
    }

    /// From a command line or a drop.
    ///
    /// One path is a position in its folder; several are the list itself.
    /// A directory on its own opens its first file.
    public static func from(paths: [String], using fs: MediaScanner = .real) -> Playlist {
        let absolute = paths.map(absolutePath)
        switch absolute.count {
        case 0:
            return Playlist()
        case 1:
            return around(path: absolute[0], using: fs)
        default:
            return Playlist(entries: absolute, index: 0, playsThrough: true)
        }
    }

    static func around(path: String, using fs: MediaScanner) -> Playlist {
        let directory = fs.isDirectory(path)
            ? path : (path as NSString).deletingLastPathComponent
        var entries = fs.mediaNames(directory)
            .sorted(by: naturalOrder)
            .map { (directory as NSString).appendingPathComponent($0) }
        if fs.isDirectory(path) {
            return Playlist(entries: entries, index: entries.isEmpty ? nil : 0)
        }
        // Named but not in the listing — an extension the scan does not know,
        // a race with a rename. Still what was asked for, so it is spliced in
        // where it sorts rather than replaced by a neighbour.
        if !entries.contains(path) {
            let name = (path as NSString).lastPathComponent
            let at = entries.firstIndex {
                naturalOrder(name, ($0 as NSString).lastPathComponent)
            } ?? entries.count
            entries.insert(path, at: at)
        }
        return Playlist(entries: entries, index: entries.firstIndex(of: path))
    }

    /// `Episode 2` before `Episode 10`, which byte order gets wrong.
    static func naturalOrder(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: [.numeric, .caseInsensitive]) == .orderedAscending
    }

    static func absolutePath(_ path: String) -> String {
        if path.hasPrefix("/") { return (path as NSString).standardizingPath }
        // A URL is passed through: mpv opens `https://…` itself.
        if path.contains("://") { return path }
        let cwd = FileManager.default.currentDirectoryPath
        return ((cwd as NSString).appendingPathComponent(path) as NSString)
            .standardizingPath
    }
}

/// The filesystem as `Playlist` needs it, so the tests can supply one.
public struct MediaScanner: Sendable {
    public var isDirectory: @Sendable (String) -> Bool
    public var mediaNames: @Sendable (String) -> [String]

    public init(
        isDirectory: @escaping @Sendable (String) -> Bool,
        mediaNames: @escaping @Sendable (String) -> [String]
    ) {
        self.isDirectory = isDirectory
        self.mediaNames = mediaNames
    }

    public static let real = MediaScanner(
        isDirectory: { path in
            var directory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &directory)
                && directory.boolValue
        },
        mediaNames: { directory in
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
            return names.filter { !$0.hasPrefix(".") && MediaFormats.isMedia(path: $0) }
        }
    )
}
