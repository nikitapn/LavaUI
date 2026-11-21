import Foundation

/// Searches text that is not on disk — an open document's unsaved buffer —
/// the way the ripgrep walk reads a file, so that its lines can stand in for
/// the file's: one line at a time, `\n` or `\r\n` ending a line, columns in
/// characters, the same include and exclude globs.
///
/// The pattern goes through Swift's regex engine rather than ripgrep's.
/// Literal searches, case and whole word agree; a regular expression that
/// uses syntax only one of the two accepts is the gap, and is reported by
/// throwing rather than by quietly finding nothing.
public enum ProjectSearchText {
    /// The buffer's matches, or nil when the walk would not have reported
    /// `path` at all: outside the globs, or inside `.git`.
    ///
    /// Stops one match past `limit`, so that `ProjectSearchResult.replacing`
    /// sees a total over the limit and says the search was cut short.
    public static func search(
        _ buffer: ProjectSearchBuffer, options: ProjectSearchOptions,
        limit: Int = ProjectSearchEngine.matchLimit
    ) throws -> ProjectSearchFile? {
        guard !options.query.isEmpty else { return nil }
        let path = buffer.path
        guard path != ".git", !path.hasPrefix(".git/"),
              ProjectSearchGlobs(options).accepts(path) else { return nil }
        let regex = try makeRegex(options)

        var file = ProjectSearchFile(path: path)
        let text = buffer.text
        let utf8 = text.utf8
        var number = 1
        var lineStart = utf8.startIndex

        // Indices into the UTF-8 view are indices into the string, and a line
        // break is a grapheme boundary on both sides, so slicing the string at
        // them never splits a character.
        func searchLine(upTo end: String.Index) -> Bool {
            let line = text[lineStart..<end]
            var matches: [Range<Int>] = []
            var cursor = line.startIndex
            var column = 0
            for match in line.matches(of: regex) {
                if file.count + matches.count > limit { break }
                column += line.distance(from: cursor, to: match.range.lowerBound)
                cursor = match.range.lowerBound
                let width = line.distance(from: match.range.lowerBound, to: match.range.upperBound)
                matches.append(column..<(column + width))
            }
            if !matches.isEmpty {
                file.lines.append(ProjectSearchLine(number: number, text: String(line), matches: matches))
                file.count += matches.count
            }
            return file.count <= limit
        }

        var index = utf8.startIndex
        while index < utf8.endIndex {
            if utf8[index] == 0x0a {
                var end = index
                if end > lineStart, utf8[utf8.index(before: end)] == 0x0d {
                    end = utf8.index(before: end)
                }
                guard searchLine(upTo: end) else { return file }
                lineStart = utf8.index(after: index)
                number += 1
            }
            index = utf8.index(after: index)
        }
        // A final newline ends the last line; it does not start an empty one.
        if lineStart < utf8.endIndex { _ = searchLine(upTo: utf8.endIndex) }
        return file
    }

    static func makeRegex(_ options: ProjectSearchOptions) throws -> Regex<AnyRegexOutput> {
        var pattern = options.regularExpression ? options.query : escape(options.query)
        if options.wholeWord { pattern = "\\b(?:" + pattern + ")\\b" }
        // Simple word boundaries are ripgrep's: between a word character and
        // anything else. Swift's default follows UAX #29, which disagrees
        // around apostrophes and punctuation inside words.
        return try Regex(pattern)
            .ignoresCase(!options.caseSensitive)
            .wordBoundaryKind(.simple)
    }

    private static func escape(_ literal: String) -> String {
        var out = ""
        for character in literal {
            if "\\.^$|?*+()[]{}".contains(character) { out.append("\\") }
            out.append(character)
        }
        return out
    }
}
