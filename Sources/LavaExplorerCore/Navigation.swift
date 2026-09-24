import Foundation

/// A folder as it was when it was left: which rows were selected and how far
/// down the list was scrolled. What Back puts back.
public struct FolderVisit: Equatable, Sendable {
    public var path: String
    public var selection: FileSelection
    public var scrollOffset: Float

    public init(path: String, selection: FileSelection = FileSelection(), scrollOffset: Float = 0) {
        self.path = path
        self.selection = selection
        self.scrollOffset = scrollOffset
    }
}

/// Where we are, and the two stacks that make Back and Forward mean something.
///
/// A visit pushes the current path and clears the future — the same rule as a
/// browser. Reloading the folder you are already in is not a visit: it would
/// fill the back stack with copies of here.
///
/// Each entry on the stacks remembers the folder as it was left — selection
/// and scroll — so Back from a child lands on the row it was opened from,
/// where it was on screen, rather than at the top of the parent.
public struct FolderHistory: Equatable, Sendable {
    public private(set) var path: String
    private var backward: [FolderVisit]
    private var forward: [FolderVisit]

    public init(path: String) {
        self.path = Self.normalize(path)
        self.backward = []
        self.forward = []
    }

    public var canGoBack: Bool { !backward.isEmpty }
    public var canGoForward: Bool { !forward.isEmpty }
    /// The Trash is not inside anything.
    public var canGoUp: Bool { path != "/" && !TrashPath.isTrash(path) }

    /// Move to `next` if it is a different folder, remembering `leaving` as
    /// the state of the folder being left. Returns whether anything changed,
    /// so a caller that reloads on same-path can tell the two apart.
    @discardableResult
    public mutating func visit(_ next: String, leaving: FolderVisit? = nil) -> Bool {
        let next = Self.normalize(next)
        guard next != path else { return false }
        backward.append(here(leaving))
        forward.removeAll()
        path = next
        return true
    }

    /// Returns the folder gone back to, as it was left.
    @discardableResult
    public mutating func goBack(leaving: FolderVisit? = nil) -> FolderVisit? {
        guard let previous = backward.popLast() else { return nil }
        forward.append(here(leaving))
        path = previous.path
        return previous
    }

    @discardableResult
    public mutating func goForward(leaving: FolderVisit? = nil) -> FolderVisit? {
        guard let next = forward.popLast() else { return nil }
        backward.append(here(leaving))
        path = next.path
        return next
    }

    /// Up is a visit to the parent. The folder being left is what the parent
    /// should have selected, and the caller does that — the history only
    /// says where it went.
    public mutating func goUp(leaving: FolderVisit? = nil) {
        guard canGoUp else { return }
        let parent = (path as NSString).deletingLastPathComponent
        _ = visit(parent.isEmpty ? "/" : parent, leaving: leaving)
    }

    private func here(_ state: FolderVisit?) -> FolderVisit {
        guard var state else { return FolderVisit(path: path) }
        state.path = path
        return state
    }

    /// `~`, `.`, `..`, and duplicate slashes become one absolute path.
    public static func normalize(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        // An address, not a path: standardizing would make it "trash:".
        if TrashPath.isTrash(trimmed) { return TrashPath.uri }
        let expanded = (trimmed as NSString).expandingTildeInPath
        let standardized = (expanded as NSString).standardizingPath
        return standardized.isEmpty ? "/" : standardized
    }

    /// What to open when the process is handed an argument.
    ///
    /// A directory is a place. A file is a place (its parent) and a selection.
    /// A missing path still has a parent — the user may have typed a name they
    /// are about to create, and landing in the folder they meant is better
    /// than bouncing home.
    public static func landing(
        argument: String, source: any FileSource
    ) -> (directory: String, select: String?) {
        let path = normalize(argument)
        if let entry = try? source.entry(at: path) {
            if entry.isDirectory { return (path, nil) }
            let parent = (path as NSString).deletingLastPathComponent
            return (parent.isEmpty ? "/" : parent, path)
        }
        if source.exists(path) {
            return (path, nil)
        }
        let parent = (path as NSString).deletingLastPathComponent
        return (parent.isEmpty ? "/" : parent, nil)
    }
}

/// The shortcuts down the left, in the order Thunar puts them.
public struct Place: Equatable, Sendable, Identifiable {
    public var title: String
    public var path: String
    public var id: String { path }

    public init(title: String, path: String) {
        self.title = title
        self.path = FolderHistory.normalize(path)
    }
}

public enum Places {
    /// Home, the XDG user directories that actually exist, the machine, and
    /// the Trash.
    ///
    /// Missing folders are skipped rather than shown greyed: a place that
    /// cannot be opened is a lie, and this app has no "create this folder"
    /// yet. Home and Computer always stay — they are how you recover when
    /// everything else is gone.
    public static func standard(
        home: String = NSHomeDirectory(),
        userDirs: String? = nil,
        exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> [Place] {
        let home = FolderHistory.normalize(home)
        let dirs = parseUserDirs(userDirs ?? readUserDirs(home: home), home: home)
        var places: [Place] = [Place(title: "Home", path: home)]
        let named: [(String, String)] = [
            ("Desktop", "XDG_DESKTOP_DIR"),
            ("Documents", "XDG_DOCUMENTS_DIR"),
            ("Downloads", "XDG_DOWNLOAD_DIR"),
            ("Pictures", "XDG_PICTURES_DIR"),
            ("Music", "XDG_MUSIC_DIR"),
            ("Videos", "XDG_VIDEOS_DIR"),
        ]
        for (title, key) in named {
            let fallback = (home as NSString).appendingPathComponent(title)
            let path = dirs[key] ?? fallback
            guard path != home, exists(path) else { continue }
            if places.contains(where: { $0.path == path }) { continue }
            places.append(Place(title: title, path: path))
        }
        places.append(Place(title: "Computer", path: "/"))
        places.append(Place(title: "Trash", path: TrashPath.uri))
        return places
    }

    /// `~/.config/user-dirs.dirs` as `XDG_*_DIR` → absolute path.
    public static func parseUserDirs(_ text: String, home: String) -> [String: String] {
        var out: [String: String] = [:]
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq])
            var value = String(line[line.index(after: eq)...])
            if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            value = value.replacingOccurrences(of: "$HOME", with: home)
            value = value.replacingOccurrences(of: "${HOME}", with: home)
            out[key] = FolderHistory.normalize(value)
        }
        return out
    }

    private static func readUserDirs(home: String) -> String {
        let path = (home as NSString).appendingPathComponent(".config/user-dirs.dirs")
        return (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }
}
