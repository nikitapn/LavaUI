import Foundation

/// LavaExplorer as the desktop's file picker: what an app asked for, and
/// what counts as an answer.
///
/// `FileDialog` in LavaUI starts `LavaExplorer --choose=…` and waits; the
/// explorer is the same window with a bar along the bottom — a name to save
/// under, which files to show, Open or Save and Cancel. The answer goes to a
/// file the caller named with `--output`, one path per line, never to
/// stdout: an app writes all sorts to stdout, and a stray line read back as a
/// chosen path is a file the user never picked.
public struct ChooserRequest: Equatable, Sendable {
    public enum Mode: String, Equatable, Sendable {
        case open
        case openMultiple = "open-multiple"
        case save
    }

    /// "Images | png, jpg": which files are shown. Folders always are — they
    /// are how you get to the files.
    public struct Filter: Equatable, Sendable {
        public var name: String
        /// Lower-cased, without dots. Empty shows everything.
        public var extensions: [String]

        public init(name: String, extensions: [String]) {
            self.name = name
            self.extensions = extensions
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " .*")).lowercased() }
                .filter { !$0.isEmpty }
        }

        public func shows(_ entry: FileEntry) -> Bool {
            if entry.isDirectory || extensions.isEmpty { return true }
            let ext = (entry.name as NSString).pathExtension.lowercased()
            return extensions.contains(ext)
        }

        /// `Name|ext,ext`, the form `--filter` takes.
        public static func parse(_ text: String) -> Filter? {
            let parts = text.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
                .map(String.init)
            guard parts.count == 2 else { return nil }
            return Filter(
                name: parts[0].trimmingCharacters(in: .whitespaces),
                extensions: parts[1].split(separator: ",").map(String.init)
            )
        }
    }

    public var mode: Mode
    public var title: String
    public var filters: [Filter]
    /// Save: the name offered.
    public var suggestedName: String?
    /// Where the answer is written.
    public var output: String?

    public init(
        mode: Mode, title: String? = nil, filters: [Filter] = [],
        suggestedName: String? = nil, output: String? = nil
    ) {
        self.mode = mode
        self.title = title ?? (mode == .save ? "Save File" : "Open File")
        self.filters = filters
        self.suggestedName = suggestedName
        self.output = output
    }

    /// Nil when the command line asks for no chooser — the explorer as itself.
    public static func parse(_ arguments: [String]) -> ChooserRequest? {
        var mode: Mode?
        var title: String?
        var filters: [Filter] = []
        var name: String?
        var output: String?
        for argument in arguments {
            guard argument.hasPrefix("--"), let eq = argument.firstIndex(of: "=") else { continue }
            let key = String(argument[argument.index(argument.startIndex, offsetBy: 2)..<eq])
            let value = String(argument[argument.index(after: eq)...])
            switch key {
            case "choose": mode = Mode(rawValue: value)
            case "title": title = value
            case "filter": if let filter = Filter.parse(value) { filters.append(filter) }
            case "filename": name = value
            case "output": output = value
            default: break
            }
        }
        guard let mode else { return nil }
        return ChooserRequest(
            mode: mode, title: title, filters: filters, suggestedName: name, output: output
        )
    }

    /// The files an Open answers with: the selected files, in list order.
    /// Folders are not an answer — Open on a folder goes into it. Nil when
    /// there is nothing to answer with yet.
    public func openAnswer(selected: [FileEntry]) -> [String]? {
        let files = selected.filter { !$0.isDirectory }.map(\.path)
        guard !files.isEmpty else { return nil }
        return mode == .openMultiple ? files : [files[0]]
    }

    /// Where a Save goes: `name` in `directory`, or why it cannot.
    public func saveTarget(name raw: String, in directory: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespaces)
        if let problem = NewFolder.problem(with: name) {
            throw FileAccessError(path: directory, message: problem)
        }
        guard !TrashPath.isTrash(directory) else {
            throw FileAccessError(path: directory, message: "Nothing can be saved into the Trash")
        }
        return CopyPaths.join(directory, name)
    }

    /// Writes the answer where the caller will look for it.
    public func deliver(_ paths: [String]) throws {
        guard let output else { return }
        try (paths.joined(separator: "\n") + "\n").write(
            toFile: output, atomically: true, encoding: .utf8
        )
    }
}

/// A `FileSource` that leaves out the files a chooser's filter does not
/// show. The filter is a reference so switching it needs no new source —
/// the session's is fixed for its life.
public struct FilteredSource: FileSource {
    public final class Filter: @unchecked Sendable {
        public var current: ChooserRequest.Filter?
        public init(_ current: ChooserRequest.Filter?) { self.current = current }
    }

    public var base: any FileSource
    public let filter: Filter

    public init(base: any FileSource, filter: Filter) {
        self.base = base
        self.filter = filter
    }

    public func entries(in directory: String) throws -> [FileEntry] {
        let all = try base.entries(in: directory)
        guard let current = filter.current else { return all }
        return all.filter(current.shows)
    }

    public func entry(at path: String) throws -> FileEntry { try base.entry(at: path) }
    public func exists(_ path: String) -> Bool { base.exists(path) }
}
