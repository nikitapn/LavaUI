import Foundation
import Glibc

public struct ProjectSearchOptions: Equatable, Sendable {
    public var query = ""
    public var caseSensitive = false
    public var wholeWord = false
    public var regularExpression = false
    public var include = ""
    public var exclude = ""

    public init() {}

    var arguments: [String] { arguments(paths: ["."]) }

    /// `paths` are relative to the search root. Naming a file searches it even
    /// when an ignore file would have skipped it during a walk.
    func arguments(paths: [String]) -> [String] {
        // Keep the byte offsets in the same UTF-8 the editor opens, including
        // a BOM if present. --crlf makes the regex end anchor work on CRLF.
        var args = ["--json", "--no-config", "--no-require-git", "--hidden",
                    "--glob", "!.git", "--crlf", "--encoding", "none",
                    caseSensitive ? "--case-sensitive" : "--ignore-case"]
        if wholeWord { args.append("--word-regexp") }
        if !regularExpression { args.append("--fixed-strings") }
        return args + ["-e", query, "--"] + paths
    }
}

struct ProjectSearchGlobs {
    let includes: [[Substring]]
    let excludes: [[Substring]]

    init(_ options: ProjectSearchOptions) {
        includes = Self.parse(options.include)
        excludes = Self.parse(options.exclude)
    }

    private static func parse(_ input: String) -> [[Substring]] {
        input.split(separator: ",").compactMap { part in
            var pattern = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if pattern.hasPrefix("./") { pattern.removeFirst(2) }
            if pattern.hasSuffix("/") { pattern += "**" }
            let components = pattern.split(separator: "/")
            return components.isEmpty ? nil : components
        }
    }

    func accepts(_ path: String) -> Bool {
        // Positive rg globs override .gitignore. Apply both fields to the
        // paths rg found after honoring ignore files, even outside a repo.
        let parts = path.split(separator: "/")
        return (includes.isEmpty || includes.contains { Self.matches($0, parts) })
            && !excludes.contains { Self.matches($0, parts) }
    }

    private static func matches(_ pattern: [Substring], _ path: [Substring]) -> Bool {
        if pattern.count == 1 {
            return path.contains { fnmatch(String(pattern[0]), String($0), 0) == 0 }
        }
        // A matching directory applies to its descendants. A ** component
        // can span zero or more directory levels.
        var positions = Set([0])
        for component in pattern {
            if component == "**" {
                guard let first = positions.min() else { return false }
                positions = Set(first...path.count)
            } else {
                let glob = String(component)
                positions = Set(positions.compactMap { index in
                    guard index < path.count, fnmatch(glob, String(path[index]), 0) == 0 else { return nil }
                    return index + 1
                })
            }
        }
        return !positions.isEmpty
    }
}

public struct ProjectSearchLine: Sendable {
    public let number: Int
    /// Character columns in the source line and in the bounded preview.
    public let matches: [Range<Int>]
    public let preview: String
    public let highlights: [Range<Int>]
    private let sourceHash: Int

    init(number: Int, text: String, matches: [Range<Int>]) {
        self.number = number
        self.matches = matches
        sourceHash = text.hashValue

        let first = matches[0].lowerBound
        let leading = text.prefix(while: \.isWhitespace).count
        let start = max(min(leading, first), first - 16)
        let excerpt = text.dropFirst(start).prefix(136)
        let end = start + excerpt.count
        let left = start > leading
        let right = excerpt.endIndex != text.endIndex
        preview = (left ? "…" : "") + excerpt + (right ? "…" : "")
        let shift = (left ? 1 : 0) - start
        highlights = matches.compactMap { range in
            if range.isEmpty {
                guard (start...end).contains(range.lowerBound) else { return nil }
                let point = range.lowerBound + shift
                return point..<point
            }
            let overlap = range.clamped(to: start..<end)
            guard !overlap.isEmpty else { return nil }
            return (overlap.lowerBound + shift)..<(overlap.upperBound + shift)
        }
    }

    /// A result is from disk. Check the destination line in the live buffer
    /// before selecting, since a save or an unsaved edit can move the hit.
    public func selection(in buffer: String, match: Int = 0) -> Range<Int>? {
        guard matches.indices.contains(match) else { return nil }
        let hit = matches[match]
        var start = buffer.startIndex
        var offset = 0
        var line = 1
        var position = 0
        for index in buffer.indices {
            let character = buffer[index]
            if character == "\n" || character == "\r\n" {
                if line == number {
                    return selection(in: buffer[start..<index], offset: offset, hit: hit)
                }
                line += 1
                start = buffer.index(after: index)
                offset = position + 1
            }
            position += 1
        }
        guard line == number else { return nil }
        return selection(in: buffer[start...], offset: offset, hit: hit)
    }

    private func selection(in line: Substring, offset: Int, hit: Range<Int>) -> Range<Int>? {
        guard String(line).hashValue == sourceHash else { return nil }
        return (offset + hit.lowerBound)..<(offset + hit.upperBound)
    }
}

public struct ProjectSearchFile: Sendable {
    public let path: String
    public internal(set) var lines: [ProjectSearchLine] = []
    public internal(set) var count = 0
}

public struct ProjectSearchResult: Sendable {
    public internal(set) var files: [ProjectSearchFile] = []
    public internal(set) var count = 0
    public internal(set) var capped = false

    public init() {}

    /// This result with each path in `files` answered by the file given for it
    /// instead — an unsaved buffer's matches over what is on disk, or a fresh
    /// read of one file over a stale one. A file with no lines removes the
    /// path. `capped` stays as it was, plus whether the total is now past
    /// `limit`: a capped walk stopped early, and nothing here can say what it
    /// would have found.
    public func replacing(
        _ files: [String: ProjectSearchFile], limit: Int = ProjectSearchEngine.matchLimit
    ) -> ProjectSearchResult {
        guard !files.isEmpty else { return self }
        var out = ProjectSearchResult()
        out.files = self.files.filter { files[$0.path] == nil }
            + files.values.filter { !$0.lines.isEmpty }
        out.files.sort { $0.path < $1.path }
        out.count = out.files.reduce(0) { $0 + $1.count }
        out.capped = capped || out.count > limit
        return out
    }

    /// This result with `paths` answered by `fresh` — a search of just those
    /// files — including the ones `fresh` found nothing in, which are dropped.
    public func rereading(_ paths: [String], from fresh: ProjectSearchResult) -> ProjectSearchResult {
        let found = Dictionary(fresh.files.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        return replacing(Dictionary(paths.map { ($0, found[$0] ?? ProjectSearchFile(path: $0)) },
                                    uniquingKeysWith: { first, _ in first }))
    }
}

/// An open document's text, standing in for its file while it has unsaved
/// edits. `path` is relative to the search root, as results name files.
public struct ProjectSearchBuffer: Sendable, Equatable {
    public let path: String
    public let text: String

    public init(path: String, text: String) {
        self.path = path
        self.text = text
    }
}

struct ProjectSearchOutput {
    private struct Event: Decodable {
        let type: String
        let data: Match?
    }

    private struct Match: Decodable {
        let path: Bytes?
        let lines: Bytes?
        let line_number: Int?
        let submatches: [Span]?
    }

    private struct Span: Decodable {
        let start: Int
        let end: Int
    }

    private struct Bytes: Decodable {
        let text: String?
        let bytes: String?

        var utf8: String? {
            if let text { return text }
            guard let bytes, let data = Data(base64Encoded: bytes) else { return nil }
            return String(data: data, encoding: .utf8)
        }
    }

    private let decoder = JSONDecoder()
    private let globs: ProjectSearchGlobs
    private let limit: Int
    private var indices: [String: Int] = [:]
    private(set) var result = ProjectSearchResult()

    init(options: ProjectSearchOptions, limit: Int) {
        globs = ProjectSearchGlobs(options)
        self.limit = max(0, limit)
    }

    func finish() -> ProjectSearchResult {
        var sorted = result
        sorted.files.sort { $0.path < $1.path }
        return sorted
    }

    mutating func consume(_ json: Data) throws {
        let event = try decoder.decode(Event.self, from: json)
        guard event.type == "match", let record = event.data,
              var path = record.path?.utf8, var text = record.lines?.utf8,
              let number = record.line_number, let spans = record.submatches else { return }
        if path.hasPrefix("./") { path.removeFirst(2) }
        guard globs.accepts(path) else { return }
        if text.last == "\n" || text.last == "\r\n" { text.removeLast() }

        var index = text.startIndex
        var byte = 0, column = 0
        func advance(to target: Int) -> Int {
            while index < text.endIndex {
                let next = text.index(after: index)
                let boundary = byte + text.utf8.distance(from: index, to: next)
                if boundary > target { break }
                index = next
                byte = boundary
                column += 1
            }
            return column
        }

        var matches: [Range<Int>] = []
        let length = text.utf8.count
        for span in spans where span.start >= 0 && span.end >= span.start && span.end <= length {
            guard result.count + matches.count < limit else {
                result.capped = true
                break
            }
            // A regex can match only a scalar in an emoji or combining
            // sequence. Widen to the editor's selectable grapheme boundaries.
            let lower = advance(to: span.start)
            let upper = span.start == span.end ? lower : advance(to: span.end) + (byte < span.end ? 1 : 0)
            matches.append(lower..<upper)
        }
        guard !matches.isEmpty else { return }
        let file: Int
        if let existing = indices[path] {
            file = existing
        } else {
            file = result.files.count
            indices[path] = file
            result.files.append(ProjectSearchFile(path: path))
        }
        result.files[file].lines.append(ProjectSearchLine(number: number, text: text, matches: matches))
        result.files[file].count += matches.count
        result.count += matches.count
    }
}
