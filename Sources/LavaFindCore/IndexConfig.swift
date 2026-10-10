import Foundation

/// `~/.config/lava/index.conf` as Settings edits it: the roots, added and
/// removed, and every other line left exactly as it was.
///
/// The file is the daemon's (`indexer/src/config.cpp` reads it, and reloads it
/// when it changes) and it is also a file people edit by hand, so an edit here
/// is a line inserted or a line taken out — never a rewrite that would drop a
/// comment or an `exclude` this page does not show.
public struct IndexConfig: Equatable, Sendable {
    public private(set) var lines: [String]

    public init(text: String) {
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        self.lines = lines
    }

    public var text: String { lines.joined(separator: "\n") + "\n" }

    /// The roots in file order, as absolute paths.
    public func roots(home: String) -> [String] {
        lines.compactMap { Self.root(in: $0, home: home) }
    }

    /// `hidden = yes` — whether names starting with a dot are indexed.
    public var indexesHidden: Bool {
        for line in lines.reversed() {
            guard let (key, value) = Self.keyValue(line), key == "hidden" else { continue }
            return value == "yes" || value == "true" || value == "1"
        }
        return false
    }

    /// Adds `path` after the last root (or at the end), written with `~` when
    /// it is under home, the way a person would. False when already there.
    @discardableResult
    public mutating func add(root path: String, home: String) -> Bool {
        let absolute = Self.normalize(path, home: home)
        guard !absolute.isEmpty, !roots(home: home).contains(absolute) else { return false }
        let line = "root = \(Self.tilde(absolute, home: home))"
        if let last = lines.lastIndex(where: { Self.root(in: $0, home: home) != nil }) {
            lines.insert(line, at: last + 1)
        } else {
            lines.append(line)
        }
        return true
    }

    /// Removes every line naming `path`. False when it was not a root.
    @discardableResult
    public mutating func remove(root path: String, home: String) -> Bool {
        let absolute = Self.normalize(path, home: home)
        let before = lines.count
        lines.removeAll { Self.root(in: $0, home: home) == absolute }
        return lines.count != before
    }

    /// What the daemon indexes when there is no file at all: the usual
    /// folders that exist. Mirrors `loadConfig` in indexer/src/config.cpp, so
    /// the first edit Settings makes starts from what was really indexed
    /// rather than from nothing.
    public static func defaults(home: String, exists: (String) -> Bool) -> IndexConfig {
        var text = """
        # What lava-index indexes. Edited by Settings → Search; edits by hand
        # are fine too, and apply as soon as the file is saved.

        """
        for folder in ["Documents", "Downloads", "Pictures", "Videos", "Music", "Desktop"] {
            if exists(home + "/" + folder) { text += "root = ~/\(folder)\n" }
        }
        return IndexConfig(text: text)
    }

    // MARK: Lines

    static func keyValue(_ line: String) -> (String, String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "=") else { return nil }
        let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces)
        let value = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        return (key, value)
    }

    static func root(in line: String, home: String) -> String? {
        guard let (key, value) = keyValue(line), key == "root" else { return nil }
        let path = normalize(value, home: home)
        return path.hasPrefix("/") ? path : nil
    }

    /// `~` expanded and trailing slashes gone — what the daemon compares.
    public static func normalize(_ path: String, home: String) -> String {
        var out = path.trimmingCharacters(in: .whitespaces)
        if out == "~" { out = home } else if out.hasPrefix("~/") { out = home + out.dropFirst() }
        while out.count > 1 && out.hasSuffix("/") { out.removeLast() }
        return out
    }

    static func tilde(_ path: String, home: String) -> String {
        FindFormat.tilde(path, home: home)
    }
}
