import Foundation

/// The bulk-rename window's toolbar: edits to the buffer of new names.
///
/// Each one rewrites the lines as they stand, not the original names, so
/// they compose with each other and with typing — a replace, then a case
/// change, then one line fixed by hand. None of them knows about the disk;
/// what the result would do is `BulkRename.plan`'s question.
public enum RenameTransform: Equatable, Sendable {
    /// Every match of `find` in a name. As a regular expression, `$1` in
    /// `with` is the first group.
    case replace(find: String, with: String, regex: Bool, ignoreCase: Bool)
    case lowercase
    case uppercase
    /// The first letter of each word up, the rest down.
    case titlecase
    /// `{name}` is the name as it stands, `{n}` its place in the list from 1,
    /// `{n:3}` the same padded with zeros to three digits.
    case number(template: String)

    public struct Invalid: Error, Equatable, Sendable {
        public var message: String
    }

    /// `lines` transformed. With `keepExtensions` only the part before the
    /// extension is touched — `isDirectory` (by line, false past its end)
    /// says which lines have none to keep, as `CopyNaming.split` decides.
    public func apply(
        to lines: [String], keepExtensions: Bool, isDirectory: [Bool] = []
    ) throws -> [String] {
        let rewrite = try rewriter()
        return lines.enumerated().map { index, line in
            let directory = index < isDirectory.count && isDirectory[index]
            let (stem, ext) = keepExtensions
                ? CopyNaming.split(line, isDirectory: directory)
                : (line, "")
            // An empty line stays empty: a number on it would turn "you
            // forgot this one" into a name.
            if line.isEmpty { return line }
            return rewrite(stem, index) + (ext.isEmpty ? "" : "." + ext)
        }
    }

    private func rewriter() throws -> (String, Int) -> String {
        switch self {
        case .lowercase: return { name, _ in name.lowercased() }
        case .uppercase: return { name, _ in name.uppercased() }
        case .titlecase: return { name, _ in name.capitalized }
        case .replace(let find, let with, let regex, let ignoreCase):
            guard !find.isEmpty else { return { name, _ in name } }
            if !regex {
                let options: String.CompareOptions = ignoreCase ? [.caseInsensitive] : []
                return { name, _ in name.replacingOccurrences(of: find, with: with, options: options) }
            }
            let expression: NSRegularExpression
            do {
                expression = try NSRegularExpression(
                    pattern: find, options: ignoreCase ? [.caseInsensitive] : []
                )
            } catch {
                throw Invalid(message: "That is not a regular expression")
            }
            return { name, _ in
                expression.stringByReplacingMatches(
                    in: name, range: NSRange(name.startIndex..., in: name), withTemplate: with
                )
            }
        case .number(let template):
            let tokens = try Self.parse(template)
            return { name, index in
                tokens.map { token in
                    switch token {
                    case .text(let text): text
                    case .name: name
                    case .number(let width):
                        String(repeating: "0", count: max(0, width - String(index + 1).count))
                            + String(index + 1)
                    }
                }.joined()
            }
        }
    }

    private enum Token { case text(String), name, number(width: Int) }

    private static func parse(_ template: String) throws -> [Token] {
        var tokens: [Token] = []
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "{") {
            if open > rest.startIndex { tokens.append(.text(String(rest[..<open]))) }
            guard let close = rest[open...].firstIndex(of: "}") else {
                throw Invalid(message: "A \u{201C}{\u{201D} without a \u{201C}}\u{201D}")
            }
            let field = rest[rest.index(after: open)..<close]
            if field == "name" {
                tokens.append(.name)
            } else if field == "n" {
                tokens.append(.number(width: 0))
            } else if field.hasPrefix("n:"), let width = Int(field.dropFirst(2)), (0...12).contains(width) {
                tokens.append(.number(width: width))
            } else {
                throw Invalid(message: "\u{201C}{\(field)}\u{201D} is not {name}, {n} or {n:3}")
            }
            rest = rest[rest.index(after: close)...]
        }
        if !rest.isEmpty { tokens.append(.text(String(rest))) }
        return tokens
    }
}
