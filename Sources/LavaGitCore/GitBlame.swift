import CGit2
import Foundation

public struct GitBlameCommit: Sendable, Equatable {
    public let oid: String
    public let author: String
    public let email: String
    public let date: Date
    public let message: String

    public var shortOID: String { String(oid.prefix(8)) }
    public var subject: String { String(message.prefix { !$0.isNewline }) }

    public func authorLabel(userEmail: String?) -> String {
        if let userEmail, !userEmail.isEmpty, email.caseInsensitiveCompare(userEmail) == .orderedSame {
            return "You"
        }
        return author
    }

    public func hint(userEmail: String?, now: Date) -> String {
        "\(authorLabel(userEmail: userEmail)), \(BlameDate.relative(date, now: now)) • \(subject)"
    }
}

public enum BlameDate {
    public static func relative(_ date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        for (length, unit) in [(365 * 86400, "year"), (30 * 86400, "month"), (86400, "day"),
                               (3600, "hour"), (60, "minute")] where seconds >= length {
            let count = seconds / length
            let suffix = count == 1 ? "" : "s"
            return "\(count) \(unit)\(suffix) ago"
        }
        return "now"
    }

    public static func exact(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "d"
        let day = formatter.string(from: date)
        let number = Int(day) ?? 0
        let suffix: String
        switch number {
        case 1, 21, 31: suffix = "st"
        case 2, 22: suffix = "nd"
        case 3, 23: suffix = "rd"
        default: suffix = "th"
        }
        formatter.dateFormat = "MMMM d'\(suffix),' yyyy h:mm a"
        return formatter.string(from: date)
    }
}

/// Immutable attribution for a file at a particular commit.
public struct GitBlame: Sendable {
    struct Hunk: Sendable {
        let lines: Range<Int>
        let commit: GitBlameCommit
    }

    let hunks: [Hunk]
    public let userEmail: String?

    /// The commit responsible for a zero-based line of the committed file.
    public subscript(line: Int) -> GitBlameCommit? {
        var low = 0
        var high = hunks.count
        while low < high {
            let mid = low + (high - low) / 2
            let hunk = hunks[mid]
            if line < hunk.lines.lowerBound { high = mid }
            else if line >= hunk.lines.upperBound { low = mid + 1 }
            else { return hunk.commit }
        }
        return nil
    }
}

extension GitRepository {
    /// The current HEAD commit, or nil before the first commit.
    public func headOID() throws -> String? {
        try withRepository { repo in
            var oid = git_oid()
            guard git_reference_name_to_id(&oid, repo, "HEAD") == 0 else { return nil }
            return Self.hex(&oid)
        }
    }

    /// Pins blame to the same commit as the caller's baseline, even if HEAD moves
    /// while this runs. The caller can reuse commit metadata across files.
    public func blame(_ url: URL, at oid: String, commits: inout [String: GitBlameCommit]) throws -> GitBlame? {
        guard let path = relativePath(of: url) else { return nil }
        return try withRepository { repo in
            var options = git_blame_options()
            try LibGit.check("blame options") {
                git_blame_options_init(&options, UInt32(GIT_BLAME_OPTIONS_VERSION))
            }
            try LibGit.check("blame revision") { git_oid_fromstr(&options.newest_commit, oid) }
            let blame = try LibGit.check("blame") { git_blame_file(&$0, repo, path, &options) }
            defer { git_blame_free(blame) }

            var hunks: [GitBlame.Hunk] = []
            for index in 0..<git_blame_get_hunk_count(blame) {
                guard let hunk = git_blame_get_hunk_byindex(blame, index)?.pointee,
                      hunk.final_start_line_number > 0 else { continue }
                var commitID = hunk.final_commit_id
                let key = Self.hex(&commitID)
                let commit: GitBlameCommit
                if let cached = commits[key] {
                    commit = cached
                } else {
                    commit = try Self.blameCommit(key, id: &commitID, in: repo)
                    commits[key] = commit
                }
                let start = hunk.final_start_line_number - 1
                hunks.append(.init(lines: start..<(start + hunk.lines_in_hunk), commit: commit))
            }
            return GitBlame(hunks: hunks, userEmail: Self.userEmail(in: repo))
        }
    }

    private static func hex(_ oid: inout git_oid) -> String {
        // libgit2 owns a thread-local buffer, so copy before the next call.
        String(cString: git_oid_tostr_s(&oid))
    }

    private static func userEmail(in repo: OpaquePointer) -> String? {
        var config: OpaquePointer?
        guard git_repository_config(&config, repo) == 0, let config else { return nil }
        defer { git_config_free(config) }
        var buffer = git_buf()
        defer { git_buf_dispose(&buffer) }
        guard git_config_get_string_buf(&buffer, config, "user.email") == 0 else { return nil }
        return buffer.ptr.map { String(cString: $0) }
    }

    private static func blameCommit(_ key: String, id: inout git_oid, in repo: OpaquePointer) throws -> GitBlameCommit {
        let commit = try LibGit.check("blame commit") { git_commit_lookup(&$0, repo, &id) }
        defer { git_commit_free(commit) }
        let signature = git_commit_author(commit).pointee
        return GitBlameCommit(
            oid: key, author: signature.name.map { String(cString: $0) } ?? "",
            email: signature.email.map { String(cString: $0) } ?? "",
            date: Date(timeIntervalSince1970: TimeInterval(signature.when.time)),
            message: git_commit_message_raw(commit).map { String(cString: $0) } ?? ""
        )
    }
}
