import Foundation

public struct LanguageServerConfig: Codable, Sendable, Equatable {
    public var name: String
    public var command: [String]
    public var languages: [String]
    public var rootMarkers: [String]
    public var initializationOptions: JSON?
    public var settings: JSON?

    public init(name: String, command: [String], languages: [String], rootMarkers: [String] = [],
                initializationOptions: JSON? = nil, settings: JSON? = nil) {
        self.name = name
        self.command = command
        self.languages = languages
        self.rootMarkers = rootMarkers
        self.initializationOptions = initializationOptions
        self.settings = settings
    }

    /// First matching language wins. Pass the editor's language ID when it differs from the extension.
    public static func select(for file: URL, in workspaceRoot: URL, configs: [Self],
                              language: String? = nil) async -> (config: Self, root: URL)? {
        await withCheckedContinuation { result in
            DispatchQueue.global(qos: .utility).async {
                result.resume(returning: match(file, workspaceRoot, configs, language))
            }
        }
    }

    /// Which server takes a file when more than one could — clangd and
    /// sourcekit-lsp both serve C, C++ and Objective-C:
    ///
    /// 1. one whose compile database lists the file — the build that
    ///    compiles it knows its flags (meson's `build/compile_commands.json`
    ///    for the compositor and canvas);
    /// 2. otherwise the one with the nearest project marker — a C target of
    ///    a SwiftPM package belongs to sourcekit-lsp, which reads the
    ///    package's build settings and runs clangd itself with them. Plain
    ///    clangd had none, and missed every target's `include` folder;
    /// 3. otherwise the first that serves the language, as before.
    ///
    /// `.git` marks a root but claims nothing: every server has it. A
    /// header is never in a compile database, so a database claims it when
    /// it lists a file in the header's folder or the one above.
    private static func match(_ file: URL, _ workspaceRoot: URL, _ configs: [Self],
                              _ language: String?) -> (config: Self, root: URL)? {
        let language = (language ?? file.pathExtension).lowercased()
        let candidates = configs.filter { $0.languages.contains { $0.lowercased() == language } }
        guard let first = candidates.first else { return nil }
        let file = file.standardizedFileURL
        let ancestors = Self.ancestors(of: file)

        // 1. A compile database that lists it.
        for config in candidates {
            for directory in ancestors {
                for marker in config.rootMarkers where marker.hasSuffix("compile_commands.json") {
                    let database = directory.appendingPathComponent(marker)
                    if CompileDatabases.covers(file, database: database) { return (config, directory) }
                }
            }
        }
        // 2. The nearest marker that says what kind of project this is.
        var best: (config: Self, root: URL, depth: Int)?
        for config in candidates {
            let markers = config.rootMarkers.filter { !Self.weakMarkers.contains($0) && !$0.hasSuffix("compile_commands.json") }
            for (depth, directory) in ancestors.enumerated() where best.map({ depth < $0.depth }) ?? true {
                if markers.contains(where: { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }) {
                    best = (config, directory, depth)
                    break
                }
            }
        }
        if let best { return (best.config, best.root) }
        // 3. The first, rooted where any of its markers is.
        for directory in ancestors where first.rootMarkers.contains(where: {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        }) {
            return (first, directory)
        }
        return (first, workspaceRoot)
    }

    /// Markers every kind of project has, which say where a root is but not
    /// whose it is.
    static let weakMarkers: Set<String> = [".git", ".hg", ".svn"]

    /// The file's folder and every folder above it, nearest first.
    private static func ancestors(of file: URL) -> [URL] {
        var out: [URL] = []
        var directory = file.deletingLastPathComponent()
        while true {
            out.append(directory)
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { break }
            directory = parent
        }
        return out
    }
}

/// What compile databases list, read once per file and kept until it
/// changes: meson's is hundreds of entries and a lookup happens per file
/// opened, never per keystroke.
enum CompileDatabases {
    private struct Entry {
        let modified: Date
        let files: Set<String>
        let folders: Set<String>
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: Entry] = [:]

    /// Whether `database` lists `file` — or, for a header, a file in the
    /// header's folder or the one above it.
    static func covers(_ file: URL, database: URL) -> Bool {
        guard let entry = entry(for: database) else { return false }
        let path = file.path
        if entry.files.contains(path) { return true }
        guard isHeader(file) else { return false }
        let folder = file.deletingLastPathComponent()
        return entry.folders.contains(folder.path)
            || entry.folders.contains(folder.deletingLastPathComponent().path)
    }

    static func isHeader(_ file: URL) -> Bool {
        ["h", "hh", "hpp", "hxx", "inl", "ipp"].contains(file.pathExtension.lowercased())
    }

    private static func entry(for database: URL) -> Entry? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: database.path),
              let modified = attributes[.modificationDate] as? Date else { return nil }
        if let cached = lock.withLock({ cache[database.path] }), cached.modified == modified { return cached }
        guard let data = try? Data(contentsOf: database),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        var files = Set<String>()
        var folders = Set<String>()
        for item in list {
            guard let name = item["file"] as? String else { continue }
            let base = (item["directory"] as? String).map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? database.deletingLastPathComponent()
            let url = (name.hasPrefix("/") ? URL(fileURLWithPath: name) : base.appendingPathComponent(name))
                .standardizedFileURL
            files.insert(url.path)
            // Every folder from the file's up: a header asks about its own
            // folder and the one above, wherever the sources sit below them.
            var folder = url.deletingLastPathComponent()
            for _ in 0..<2 {
                folders.insert(folder.path)
                folder = folder.deletingLastPathComponent()
            }
        }
        let entry = Entry(modified: modified, files: files, folders: folders)
        lock.withLock { cache[database.path] = entry }
        return entry
    }
}
