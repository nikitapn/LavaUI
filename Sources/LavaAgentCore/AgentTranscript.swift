import Foundation

/// One thing said or done in a session, as the session panel shows it.
public struct TranscriptEntry: Equatable, Sendable {
    public enum Kind: Sendable { case user, assistant, tool }
    public var kind: Kind
    public var text: String

    public init(_ kind: Kind, _ text: String) {
        self.kind = kind
        self.text = text
    }
}

/// Session files, line by line, as entries: what the user said, what the
/// agent said, and one line per tool it used. Everything else — thinking,
/// tool output, the CLI's own bookkeeping — is left out.
public enum TranscriptParser {
    /// A line of a Claude Code session file.
    public static func claude(_ line: Data) -> [TranscriptEntry] {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = object["type"] as? String, type == "user" || type == "assistant",
              object["isMeta"] as? Bool != true, object["isSidechain"] as? Bool != true,
              let message = object["message"] as? [String: Any] else { return [] }
        if let text = message["content"] as? String {
            return type == "user" ? userText(text).map { [TranscriptEntry(.user, $0)] } ?? [] : [TranscriptEntry(.assistant, text)]
        }
        guard let blocks = message["content"] as? [[String: Any]] else { return [] }
        var out: [TranscriptEntry] = []
        for block in blocks {
            switch block["type"] as? String {
            case "text":
                guard let text = block["text"] as? String else { continue }
                if type == "user" {
                    if let text = userText(text) { out.append(TranscriptEntry(.user, text)) }
                } else if !text.isEmpty {
                    out.append(TranscriptEntry(.assistant, text))
                }
            case "tool_use":
                let name = block["name"] as? String ?? "tool"
                let detail = AgentEvent.toolDetail(block["input"] as? [String: Any] ?? [:])
                out.append(TranscriptEntry(.tool, detail.isEmpty ? name : "\(name) \(detail)"))
            default:
                continue
            }
        }
        return out
    }

    /// A line of a Codex rollout.
    public static func codex(_ line: Data) -> [TranscriptEntry] {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["type"] as? String == "response_item",
              let payload = object["payload"] as? [String: Any] else { return [] }
        switch payload["type"] as? String {
        case "message":
            let role = payload["role"] as? String
            guard role == "user" || role == "assistant",
                  let content = payload["content"] as? [[String: Any]] else { return [] }
            return content.compactMap { part in
                guard let text = part["text"] as? String else { return nil }
                if role == "user" { return userText(text).map { TranscriptEntry(.user, $0) } }
                return text.isEmpty ? nil : TranscriptEntry(.assistant, text)
            }
        case "custom_tool_call", "function_call", "local_shell_call":
            let name = payload["name"] as? String ?? "tool"
            let input = (payload["input"] as? String) ?? (payload["arguments"] as? String) ?? ""
            let detail = commandIn(input)
            return [TranscriptEntry(.tool, detail.isEmpty ? name : "\(name) \(detail)")]
        default:
            return []
        }
    }

    /// What the user typed, or nil for what the CLI said in their name: the
    /// context it injects, a slash command's wrapper, an interruption.
    static func userText(_ text: String) -> String? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // What the inline chat adds around a question is for the agent.
        if trimmed.hasPrefix(InlineChatPrompt.instructions) {
            trimmed = String(trimmed.dropFirst(InlineChatPrompt.instructions.count))
        }
        if trimmed.hasSuffix(InlineChatPrompt.reminder) {
            trimmed = String(trimmed.dropLast(InlineChatPrompt.reminder.count))
        }
        trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("<"), !trimmed.hasPrefix("# AGENTS"),
              !trimmed.hasPrefix("[Request interrupted"), !trimmed.hasPrefix("[Image: source:") else { return nil }
        return trimmed
    }

    /// The command in a Codex tool call: its `cmd:` or `command` when it has
    /// one, else the start of the call.
    static func commandIn(_ input: String) -> String {
        if let data = input.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let command = object["cmd"] as? String ?? object["command"] as? String { return ClaudeSessions.oneLine(command) }
            if let parts = object["command"] as? [String] { return ClaudeSessions.oneLine(parts.joined(separator: " ")) }
        }
        for opener in ["cmd:`", "cmd: `", "cmd:\"", "cmd: \""] {
            guard let start = input.range(of: opener) else { continue }
            let close = opener.last!
            let rest = input[start.upperBound...]
            let end = rest.firstIndex(of: close) ?? rest.endIndex
            return ClaudeSessions.oneLine(String(rest[..<end]))
        }
        return ClaudeSessions.oneLine(input)
    }
}

/// A session file read from where it was left: each call returns the
/// entries appended since the last. Files run to tens of megabytes, so the
/// first read starts near the end and says that it did.
public struct TranscriptTail: Sendable {
    public let file: URL
    public let agent: AgentSession.Agent
    /// Whether the first read skipped the beginning.
    public private(set) var truncated = false
    private var offset: UInt64?
    private var lines = LineBuffer()
    private let initialBytes: UInt64

    public init(file: URL, agent: AgentSession.Agent, initialBytes: UInt64 = 2 * 1024 * 1024) {
        self.file = file
        self.agent = agent
        self.initialBytes = initialBytes
    }

    public mutating func read() -> [TranscriptEntry] {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return [] }
        var start: UInt64
        if let offset {
            // Replaced or cut short: start over from its end.
            start = size < offset ? max(0, size - min(size, initialBytes)) : offset
        } else {
            start = size > initialBytes ? size - initialBytes : 0
            truncated = start > 0
        }
        guard start < size else { offset = size; return [] }
        try? handle.seek(toOffset: start)
        guard let data = try? handle.read(upToCount: Int(size - start)) else { return [] }
        var complete = lines.append(data)
        // Started mid-line on the first read; that piece is not JSON.
        if offset == nil, start > 0, !complete.isEmpty { complete.removeFirst() }
        offset = size
        let parse = agent == .claude ? TranscriptParser.claude : TranscriptParser.codex
        return complete.flatMap(parse)
    }
}

/// Whether an agent is doing something now.
public enum AgentStatus: Equatable, Sendable {
    /// In the middle of a turn.
    case working
    /// Running, its turn over: it is waiting for you.
    case waiting
    /// Not running.
    case stopped
}

/// A Claude Code session that is running now, from `claude agents --json`
/// — the CLI's own answer, interactive sessions in a terminal included.
public struct ClaudeLiveSession: Equatable, Sendable {
    public let session: String
    public let pid: Int32
    public let directory: URL
    /// `interactive` or `background`.
    public let kind: String
    /// The CLI's word: `busy` while a turn runs.
    public let state: String
    public let name: String

    public var status: AgentStatus { state == "busy" ? .working : .waiting }

    public static func parse(_ data: Data) -> [ClaudeLiveSession] {
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return list.compactMap { entry in
            guard let session = entry["sessionId"] as? String, let cwd = entry["cwd"] as? String else { return nil }
            let pid = (entry["pid"] as? String).flatMap { Int32($0) } ?? (entry["pid"] as? Int).map { Int32($0) } ?? 0
            return ClaudeLiveSession(
                session: session, pid: pid, directory: URL(fileURLWithPath: cwd, isDirectory: true),
                kind: entry["kind"] as? String ?? "", state: entry["status"] as? String ?? "",
                name: entry["name"] as? String ?? ""
            )
        }
    }
}

extension CodexSessions {
    /// Whether a rollout's last turn is still open: a `task_started` with no
    /// `task_complete` or abort after it. From the tail only.
    public static func turnOpen(_ file: URL, tailBytes: Int = 256 * 1024) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return false }
        try? handle.seek(toOffset: size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0)
        guard let data = try? handle.readToEnd() else { return false }
        return turnOpen(lines: data.split(separator: UInt8(ascii: "\n")).map { Data($0) })
    }

    static func turnOpen(lines: [Data]) -> Bool {
        var open = false
        for line in lines {
            guard line.count < 1_000_000,
                  let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  object["type"] as? String == "event_msg",
                  let kind = (object["payload"] as? [String: Any])?["type"] as? String else { continue }
            switch kind {
            case "task_started": open = true
            case "task_complete", "turn_aborted": open = false
            default: break
            }
        }
        return open
    }
}
