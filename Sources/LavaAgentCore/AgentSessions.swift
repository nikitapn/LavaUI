import Foundation

/// One saved conversation a coding agent can resume.
public struct AgentSession: Sendable, Equatable, Identifiable {
    public enum Agent: String, Sendable { case claude, codex }

    public let agent: Agent
    public let id: String
    /// What the session is called: the name the user gave it, else the one
    /// the agent made up, else its last prompt.
    public let title: String
    /// When it was last written to.
    public let date: Date
    /// The folder it ran in — where it has to be resumed from, since the CLI
    /// looks a session up by its working directory.
    public let directory: URL
    /// The file, for how big a context resuming it brings along.
    public let bytes: Int
    /// Where the conversation is written, for reading it as it grows.
    public let file: URL?

    public init(agent: Agent, id: String, title: String, date: Date, directory: URL, bytes: Int, file: URL? = nil) {
        self.agent = agent
        self.id = id
        self.title = title
        self.date = date
        self.directory = directory
        self.bytes = bytes
        self.file = file
    }
}

/// Claude Code's saved sessions: `~/.claude/projects/<folder>/<id>.jsonl`,
/// the folder being the working directory with every character that is not
/// a letter, digit or `-` turned into `-`.
public enum ClaudeSessions {
    /// `/home/a/b.c` → `-home-a-b-c`.
    public static func folderName(for directory: URL) -> String {
        let path = directory.standardizedFileURL.path
        return String(path.unicodeScalars.map { scalar -> Character in
            let c = Character(scalar)
            return (c.isASCII && (c.isLetter || c.isNumber)) || c == "-" ? c : "-"
        })
    }

    public static var defaultHome: URL {
        if let configured = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !configured.isEmpty {
            return URL(fileURLWithPath: configured, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
    }

    /// Sessions that ran in any of `directories`, newest first.
    ///
    /// Files run to tens of megabytes, so only the tail of each is read: the
    /// CLI appends a title record and the last prompt as it goes, and the
    /// newest of each is near the end.
    public static func list(in directories: [URL], home: URL = defaultHome, tailBytes: Int = 256 * 1024) -> [AgentSession] {
        var out: [AgentSession] = []
        var seen = Set<String>()
        for directory in directories {
            let folder = home.appendingPathComponent("projects", isDirectory: true)
                .appendingPathComponent(folderName(for: directory), isDirectory: true)
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { continue }
            for name in names where name.hasSuffix(".jsonl") {
                let id = String(name.dropLast(6))
                guard UUID(uuidString: id) != nil, seen.insert(id).inserted else { continue }
                let file = folder.appendingPathComponent(name)
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
                      let date = attributes[.modificationDate] as? Date else { continue }
                let bytes = (attributes[.size] as? NSNumber)?.intValue ?? 0
                guard let summary = summarize(file, size: bytes, tailBytes: tailBytes) else { continue }
                out.append(AgentSession(agent: .claude, id: id, title: summary.title, date: date,
                                        directory: summary.directory ?? directory, bytes: bytes, file: file))
            }
        }
        return out.sorted { $0.date > $1.date }
    }

    /// The most recently written session in `directory` — the one an agent
    /// working there is most likely in. Only that file's tail is read.
    public static func latest(in directory: URL, home: URL = defaultHome, tailBytes: Int = 256 * 1024) -> AgentSession? {
        let folder = home.appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(folderName(for: directory), isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return nil }
        var candidates: [(URL, Date, Int)] = []
        for name in names where name.hasSuffix(".jsonl") && UUID(uuidString: String(name.dropLast(6))) != nil {
            let file = folder.appendingPathComponent(name)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
                  let date = attributes[.modificationDate] as? Date else { continue }
            candidates.append((file, date, (attributes[.size] as? NSNumber)?.intValue ?? 0))
        }
        // Newest first, skipping files with no conversation in them.
        for (file, date, bytes) in candidates.sorted(by: { $0.1 > $1.1 }) {
            guard let summary = summarize(file, size: bytes, tailBytes: tailBytes) else { continue }
            return AgentSession(agent: .claude, id: String(file.lastPathComponent.dropLast(6)), title: summary.title,
                                date: date, directory: summary.directory ?? directory, bytes: bytes, file: file)
        }
        return nil
    }

    struct Summary {
        var title: String
        var directory: URL?
    }

    /// The title and folder from the end of a session file; nil for a file
    /// with no conversation in it (the CLI leaves those behind).
    static func summarize(_ file: URL, size: Int, tailBytes: Int) -> Summary? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let start = max(0, size - tailBytes)
        try? handle.seek(toOffset: UInt64(start))
        guard let data = try? handle.readToEnd() else { return nil }
        var lines = data.split(separator: UInt8(ascii: "\n"))
        // Started mid-line; that one is not JSON.
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        return summarize(lines: lines.map { Data($0) })
    }

    static func summarize(lines: [Data]) -> Summary? {
        var custom: String?, named: String?, generated: String?, prompt: String?
        var directory: URL?
        var conversed = false
        for line in lines {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let type = object["type"] as? String else { continue }
            switch type {
            case "custom-title": custom = (object["customTitle"] as? String) ?? custom
            case "agent-name": named = (object["agentName"] as? String) ?? named
            case "ai-title": generated = (object["aiTitle"] as? String) ?? generated
            case "last-prompt": prompt = (object["lastPrompt"] as? String) ?? prompt
            case "user", "assistant":
                conversed = true
                if let cwd = object["cwd"] as? String { directory = URL(fileURLWithPath: cwd, isDirectory: true) }
            default: break
            }
        }
        guard conversed || prompt != nil else { return nil }
        let title = [custom, named, generated, prompt.map(InlineChatPrompt.title)].compactMap { $0 }
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? "Untitled session"
        return Summary(title: title, directory: directory)
    }

    static func oneLine(_ text: String) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return flat.count > 120 ? String(flat.prefix(119)) + "…" : flat
    }
}
