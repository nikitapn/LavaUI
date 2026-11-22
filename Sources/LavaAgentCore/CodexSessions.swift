import Foundation

extension AgentEvent {
    /// Parses one line of `codex exec --json`. One line can mean two things —
    /// a finished message is a new block *and* its text, since Codex sends
    /// each message whole rather than streaming it.
    public static func codex(_ line: Data) -> [AgentEvent] {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = object["type"] as? String else { return [] }
        switch type {
        case "thread.started":
            guard let thread = object["thread_id"] as? String else { return [] }
            return [.started(session: thread, model: "")]
        case "item.started":
            // Commands are announced as they start: a long `rg` is then
            // visible while it runs, not after.
            guard let item = object["item"] as? [String: Any], item["type"] as? String == "command_execution",
                  let command = item["command"] as? String else { return [] }
            return [.tool(name: "Ran", detail: ClaudeSessions.oneLine(shellBody(command)))]
        case "item.completed":
            guard let item = object["item"] as? [String: Any], item["type"] as? String == "agent_message",
                  let text = item["text"] as? String, !text.isEmpty else { return [] }
            return [.textBlock, .text(text)]
        case "turn.completed":
            return [.finished(isError: false, message: nil, costUSD: nil)]
        case "turn.failed":
            let message = (object["error"] as? [String: Any])?["message"] as? String
            return [.finished(isError: true, message: message ?? "The turn failed.", costUSD: nil)]
        default:
            return []
        }
    }

    /// `/usr/bin/zsh -lc "rg foo"` → `rg foo`: the shell wrapper is the same
    /// every time and says nothing.
    static func shellBody(_ command: String) -> String {
        for marker in [" -lc ", " -c "] {
            guard let range = command.range(of: marker) else { continue }
            var body = command[range.upperBound...]
            if let first = body.first, first == "\"" || first == "'", body.last == first, body.count >= 2 {
                body = body.dropFirst().dropLast()
            }
            return String(body)
        }
        return command
    }
}

/// Codex's saved sessions: `~/.codex/sessions/YYYY/MM/DD/rollout-…-<id>.jsonl`,
/// each starting with a `session_meta` record that says where it ran. Names
/// live apart, in `session_index.jsonl`, and what the user typed in
/// `history.jsonl`.
public enum CodexSessions {
    public static var defaultHome: URL {
        if let configured = ProcessInfo.processInfo.environment["CODEX_HOME"], !configured.isEmpty {
            return URL(fileURLWithPath: configured, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    }

    /// Sessions the user started (not Codex's own reviewer threads) in any
    /// of `directories`, newest first.
    public static func list(in directories: [URL], home: URL = defaultHome) -> [AgentSession] {
        let wanted = Set(directories.map { $0.standardizedFileURL.path })
        let names = latestByID(home.appendingPathComponent("session_index.jsonl"), key: "thread_name", idKey: "id")
        let prompts = latestByID(home.appendingPathComponent("history.jsonl"), key: "text", idKey: "session_id")
        let root = home.appendingPathComponent("sessions", isDirectory: true)
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else {
            return []
        }
        var out: [AgentSession] = []
        for case let file as URL in walker where file.pathExtension == "jsonl" && file.lastPathComponent.hasPrefix("rollout-") {
            guard let meta = meta(of: file), wanted.contains(meta.directory.standardizedFileURL.path),
                  meta.isUser else { continue }
            let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let title = [names[meta.id], (prompts[meta.id] ?? meta.firstPrompt).map(InlineChatPrompt.title)]
                .compactMap { $0 }.first { !$0.isEmpty } ?? "Untitled session"
            out.append(AgentSession(agent: .codex, id: meta.id, title: title,
                                    date: values?.contentModificationDate ?? .distantPast,
                                    directory: meta.directory, bytes: values?.fileSize ?? 0))
        }
        return out.sorted { $0.date > $1.date }
    }

    struct Meta {
        var id: String
        var directory: URL
        var isUser: Bool
        /// The first thing the user said, for a session with no name and
        /// nothing in `history.jsonl` — which is every `codex exec` one.
        var firstPrompt: String?
    }

    /// The first record. It carries the whole system prompt, tens of
    /// kilobytes, so the read is bounded rather than a fixed small head.
    static func meta(of file: URL) -> Meta? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 512 * 1024),
              let end = head.firstIndex(of: UInt8(ascii: "\n")),
              var meta = meta(line: head[head.startIndex..<end]) else { return nil }
        meta.firstPrompt = firstPrompt(in: head[(end + 1)...])
        return meta
    }

    /// The first user message that the user wrote: Codex sends its own
    /// context (`<environment_context>`, the AGENTS.md text) as user
    /// messages too, all of them opening with a tag or a heading.
    static func firstPrompt(in head: Data) -> String? {
        for line in head.split(separator: UInt8(ascii: "\n")).prefix(64) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  object["type"] as? String == "response_item",
                  let payload = object["payload"] as? [String: Any], payload["role"] as? String == "user",
                  let content = payload["content"] as? [[String: Any]] else { continue }
            for part in content {
                guard let text = part["text"] as? String else { continue }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty || trimmed.hasPrefix("<") || trimmed.hasPrefix("# AGENTS") { continue }
                return trimmed
            }
        }
        return nil
    }

    static func meta(line: Data) -> Meta? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["type"] as? String == "session_meta",
              let payload = object["payload"] as? [String: Any],
              let id = payload["id"] as? String, let cwd = payload["cwd"] as? String else { return nil }
        let source = payload["thread_source"] as? String
        return Meta(id: id, directory: URL(fileURLWithPath: cwd, isDirectory: true),
                    isUser: source == nil || source == "user")
    }

    /// The last value of `key` per id in a JSON-lines file appended to over
    /// time — so the last one is the current one.
    static func latestByID(_ file: URL, key: String, idKey: String) -> [String: String] {
        guard let data = try? Data(contentsOf: file) else { return [:] }
        var out: [String: String] = [:]
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let id = object[idKey] as? String, let value = object[key] as? String else { continue }
            out[id] = value
        }
        return out
    }
}
