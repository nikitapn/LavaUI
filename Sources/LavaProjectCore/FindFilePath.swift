import Foundation

/// The directory and the name being completed in an editable minibuffer path.
public struct FindFilePath: Equatable, Sendable {
    public let prefix: String
    public let query: String

    public init(_ text: String) {
        if let slash = text.lastIndex(of: "/") {
            let end = text.index(after: slash)
            prefix = String(text[..<end])
            query = String(text[end...])
        } else {
            prefix = ""
            query = text
        }
    }

    /// The last restart wins, including when an entire path is pasted.
    public static func restarting(_ text: String, after previousText: String = "") -> String {
        let unchanged = zip(text, previousText).prefix { $0 == $1 }.count
        let changedStart = text.index(text.startIndex, offsetBy: unchanged)
        var start = text.startIndex
        var previous: Character?
        for index in text.indices {
            if index >= changedStart, text[index] == "/" {
                if previous == "/" { start = index }
                if previous == "~" { start = text.index(before: index) }
            }
            previous = text[index]
        }
        return String(text[start...])
    }

    public static func abbreviated(_ path: String, home: String) -> String {
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    public static func directoryText(_ directory: URL, home: String) -> String {
        let path = abbreviated(directory.standardizedFileURL.path, home: home)
        return path.hasSuffix("/") ? path : path + "/"
    }

    public func directory(relativeTo base: URL, home: String) -> URL {
        resolve(prefix, relativeTo: base, home: home)
    }

    public func destination(relativeTo base: URL, home: String) -> URL {
        resolve(prefix + query, relativeTo: base, home: home)
    }

    public func completing(_ name: String, directory: Bool) -> String {
        prefix + name + (directory ? "/" : "")
    }

    /// At the end of a directory path, Backspace removes the whole component.
    public func parentText(home: String) -> String? {
        guard query.isEmpty, !prefix.isEmpty, prefix != "/" else { return nil }
        if prefix == "~/" {
            let parent = URL(fileURLWithPath: home).deletingLastPathComponent()
            return Self.directoryText(parent, home: home)
        }
        return FindFilePath(String(prefix.dropLast())).prefix
    }

    private func resolve(_ path: String, relativeTo base: URL, home: String) -> URL {
        if path == "~" || path.hasPrefix("~/") {
            return URL(fileURLWithPath: home + path.dropFirst()).standardizedFileURL
        }
        if path.hasPrefix("/") { return URL(fileURLWithPath: path).standardizedFileURL }
        guard !path.isEmpty else { return base }
        return base.appendingPathComponent(path).standardizedFileURL
    }
}
