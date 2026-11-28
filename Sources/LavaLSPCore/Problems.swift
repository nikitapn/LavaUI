import Foundation

/// One diagnostic in the Problems panel, from a language server or an
/// extension: where it is, how bad, and what it says.
///
/// The range keeps the encoding its columns were counted in — UTF-16 for
/// most servers, UTF-8 bytes for an extension — so it is turned into
/// characters only against the text it lands in, by `DocumentPositions`.
public struct Problem: Equatable, Sendable {
    /// Absolute path of the file.
    public var path: String
    public var range: LSPRange
    public var encoding: PositionEncoding
    public var severity: DiagnosticSeverity
    public var message: String
    /// Who said so: `clang`, `swiftc`, an extension's command title.
    public var source: String?

    public init(
        path: String, range: LSPRange, encoding: PositionEncoding = .utf16,
        severity: DiagnosticSeverity, message: String, source: String? = nil
    ) {
        self.path = path
        self.range = range
        self.encoding = encoding
        self.severity = severity
        self.message = message
        self.source = source
    }

    /// `Ln 12, Col 5`, one-based, as a status bar counts.
    public var location: String {
        "Ln \(range.start.line + 1), Col \(range.start.character + 1)"
    }
}

extension DiagnosticSeverity: Comparable {
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Every problem the editor knows of, as the panel lists them: a heading
/// per file, its problems under it by position.
///
/// Files are in path order, so the list does not reshuffle as servers
/// publish one file after another; within a file, by line and column, and
/// the worse first where two share a place.
public struct ProblemList: Equatable, Sendable {
    public struct File: Equatable, Sendable {
        public var path: String
        public var problems: [Problem]
        public var errors: Int { problems.count { $0.severity == .error } }
        public var warnings: Int { problems.count { $0.severity == .warning } }
    }

    /// A row of the panel, with an identity that survives a refresh — a
    /// file's path, a problem's path, place and message — so the selection
    /// and the folding stay put as the servers republish.
    public struct Row: Equatable, Sendable, Identifiable {
        public enum Kind: Equatable, Sendable {
            case file(Int)
            case problem(file: Int, index: Int)
        }

        public let id: String
        public let kind: Kind
    }

    public private(set) var files: [File]

    public init(_ problems: [Problem]) {
        let grouped = Dictionary(grouping: problems, by: \.path)
        files = grouped.keys.sorted().map { path in
            let sorted = grouped[path]!.sorted { a, b in
                if a.range.start != b.range.start { return a.range.start < b.range.start }
                if a.severity != b.severity { return a.severity < b.severity }
                return a.message < b.message
            }
            return File(path: path, problems: sorted)
        }
    }

    public var count: Int { files.reduce(0) { $0 + $1.problems.count } }
    public var errors: Int { files.reduce(0) { $0 + $1.errors } }
    public var warnings: Int { files.reduce(0) { $0 + $1.warnings } }

    /// The rows, without the problems of files in `collapsed` (paths).
    public func rows(collapsed: Set<String>) -> [Row] {
        var rows: [Row] = []
        for (f, file) in files.enumerated() {
            rows.append(Row(id: file.path, kind: .file(f)))
            guard !collapsed.contains(file.path) else { continue }
            // Two identical diagnostics on one spot (two servers agreeing,
            // a header seen twice) still need distinct ids.
            var seen: [String: Int] = [:]
            for (p, problem) in file.problems.enumerated() {
                let base = "\(file.path)\n\(problem.range.start.line):\(problem.range.start.character)\n\(problem.message)"
                let n = seen[base, default: 0]
                seen[base] = n + 1
                rows.append(Row(id: n == 0 ? base : "\(base)\n\(n)", kind: .problem(file: f, index: p)))
            }
        }
        return rows
    }

    public func problem(_ row: Row) -> Problem? {
        guard case .problem(let f, let p) = row.kind else { return nil }
        return files[f].problems[p]
    }

    /// `name` and the folder it is in, relative to `root` when it is under
    /// it — what a heading shows.
    public static func displayPath(_ path: String, root: String?) -> (name: String, folder: String) {
        let url = URL(fileURLWithPath: path)
        var folder = url.deletingLastPathComponent().path
        if let root, !root.isEmpty {
            let base = root.hasSuffix("/") ? root : root + "/"
            if folder + "/" == base { folder = "" }
            else if folder.hasPrefix(base) { folder = String(folder.dropFirst(base.count)) }
        }
        return (url.lastPathComponent, folder)
    }
}
