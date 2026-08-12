import Foundation

/// How often each application has been launched from a Lava shell.
///
/// Rofi keeps a small on-disk cache of launch counts and sorts the empty
/// query by that: the apps you actually use float to the top, and the rest
/// of the wall stays alphabetical underneath. Same idea here — one file,
/// one integer per desktop-entry id, most-used first.
///
/// The format is deliberately the same shape as rofi's `*.druncache`
/// (`count id` per line) so a curious `cat` is readable and a migration
/// from one launcher to the other is a copy rather than a converter. The
/// id is our `DesktopEntry.id` (filename without `.desktop`), which is
/// also what a window's `app_id` usually reports.
public struct LaunchHistory: Sendable {
    /// Counts keyed by desktop-entry id.
    private var counts: [String: Int]

    public init(counts: [String: Int] = [:]) {
        self.counts = counts
    }

    /// Where the cache lives. Under `XDG_CACHE_HOME` when set, otherwise
    /// `~/.cache`, matching every other desktop tool.
    public static var defaultPath: String {
        let env = ProcessInfo.processInfo.environment
        if let cache = env["XDG_CACHE_HOME"], !cache.isEmpty {
            return cache + "/lava-launcher.druncache"
        }
        let home = env["HOME"] ?? NSHomeDirectory()
        return home + "/.cache/lava-launcher.druncache"
    }

    /// How many times `id` has been launched, or 0 if never.
    public func count(for id: String) -> Int {
        counts[id] ?? 0
    }

    /// One more launch of `id`. Call this *before* the process dies — a
    /// launcher that records after `quit` never gets the chance.
    public mutating func record(_ id: String) {
        guard !id.isEmpty else { return }
        counts[id, default: 0] += 1
    }

    // MARK: - Persistence

    /// Reads the cache, or an empty history when the file is missing or
    /// unreadable. A corrupt line is skipped rather than poisoning the rest.
    public static func load(from path: String = defaultPath) -> LaunchHistory {
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8)
        else {
            return LaunchHistory()
        }
        var counts: [String: Int] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 2,
                  let n = Int(parts[0]), n > 0
            else { continue }
            // Join the rest so an id that somehow contains a space still
            // round-trips; rofi's own files never do, but the cost is free.
            let id = parts.dropFirst().joined(separator: " ")
            // Tolerate a trailing `.desktop` from a hand-copied rofi cache.
            let key = id.hasSuffix(".desktop")
                ? String(id.dropLast(".desktop".count))
                : id
            guard !key.isEmpty else { continue }
            counts[key, default: 0] += n
        }
        return LaunchHistory(counts: counts)
    }

    /// Writes the cache, creating the parent directory when needed.
    ///
    /// Sorted by count descending so a human opening the file sees the same
    /// order the launcher does. Atomic via a temp file in the same directory
    /// — a crash mid-write must not leave a half-empty history that forgets
    /// every launch the user ever made.
    public func save(to path: String = defaultPath) {
        let directory = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true
        )
        let lines = counts
            .filter { $0.value > 0 && !$0.key.isEmpty }
            .sorted {
                if $0.value != $1.value { return $0.value > $1.value }
                return $0.key < $1.key
            }
            .map { "\($0.value) \($0.key)" }
            .joined(separator: "\n")
        let body = lines.isEmpty ? "" : lines + "\n"
        let data = Data(body.utf8)
        let temp = path + ".tmp-\(ProcessInfo.processInfo.processIdentifier)"
        do {
            try data.write(to: URL(fileURLWithPath: temp), options: .atomic)
            // `atomic` already writes via a temp next to the destination on
            // Apple platforms; on Linux Foundation's atomic is a direct
            // write. Rename ourselves so a partial file is never the final
            // name either way.
            if FileManager.default.fileExists(atPath: path) {
                try FileManager.default.removeItem(atPath: path)
            }
            try FileManager.default.moveItem(atPath: temp, toPath: path)
        } catch {
            try? FileManager.default.removeItem(atPath: temp)
            FileHandle.standardError.write(
                Data("launch history: \(error.localizedDescription)\n".utf8)
            )
        }
    }

    // MARK: - Ordering

    /// Entries ordered the way an empty launcher query should look: most
    /// launched first, never-launched alphabetical at the bottom. Stable for
    /// equal counts so the wall does not reshuffle for no reason.
    public func ranked(_ entries: [DesktopEntry]) -> [DesktopEntry] {
        entries.sorted { a, b in
            let ca = count(for: a.id)
            let cb = count(for: b.id)
            if ca != cb { return ca > cb }
            return a.name.lowercased() < b.name.lowercased()
        }
    }
}

extension DesktopEntry {
    /// `search`, with launch count as the tiebreaker after match score.
    ///
    /// Empty query still means "everything", but ordered by `history` rather
    /// than by name alone — that is the whole point of keeping a history.
    public static func search(
        _ query: String,
        in entries: [DesktopEntry],
        history: LaunchHistory
    ) -> [DesktopEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return history.ranked(entries) }
        return entries.compactMap { entry -> (DesktopEntry, Int, Int)? in
            guard let score = entry.matchScore(trimmed) else { return nil }
            return (entry, score, history.count(for: entry.id))
        }
        .sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            if $0.2 != $1.2 { return $0.2 > $1.2 }
            return $0.0.name.lowercased() < $1.0.name.lowercased()
        }
        .map(\.0)
    }
}
