import Foundation

/// What a line of an agent CLI's JSON output means to a chat view —
/// Claude Code's `stream-json` and Codex's `exec --json` alike.
public enum AgentEvent: Equatable, Sendable {
    /// The process is up; `session` is the id this conversation is saved
    /// under — a new one when the session was forked.
    case started(session: String, model: String)
    /// More of the reply.
    case text(String)
    /// A new block of reply text begins — after a tool ran, say. The view
    /// puts a break between blocks.
    case textBlock
    /// The agent used a tool; `detail` is what it was pointed at.
    case tool(name: String, detail: String)
    /// The turn is over.
    case finished(isError: Bool, message: String?, costUSD: Double?)
    /// Anything else: status lines, rate limits, the whole assistant message
    /// that the partial events already delivered.
    case ignored

    /// Parses one line of `claude -p --output-format stream-json
    /// --include-partial-messages`. A line that is not JSON is `.ignored`,
    /// not an error: the CLI is another program, and a chat that died on its
    /// first unexpected line would be worse than one that skips it.
    public static func claude(_ line: Data) -> AgentEvent {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = object["type"] as? String else { return .ignored }
        switch type {
        case "system":
            guard object["subtype"] as? String == "init", let session = object["session_id"] as? String else {
                return .ignored
            }
            return .started(session: session, model: object["model"] as? String ?? "")
        case "stream_event":
            // A subagent's stream is its own conversation; only the top
            // level is the reply.
            guard object["parent_tool_use_id"] == nil || object["parent_tool_use_id"] is NSNull,
                  let event = object["event"] as? [String: Any],
                  let kind = event["type"] as? String else { return .ignored }
            if kind == "content_block_start",
               (event["content_block"] as? [String: Any])?["type"] as? String == "text" {
                return .textBlock
            }
            if kind == "content_block_delta", let delta = event["delta"] as? [String: Any],
               delta["type"] as? String == "text_delta", let text = delta["text"] as? String {
                return .text(text)
            }
            return .ignored
        case "assistant":
            // Tools are read from the whole message: its input arrives in
            // pieces as partial JSON otherwise.
            guard object["parent_tool_use_id"] == nil || object["parent_tool_use_id"] is NSNull,
                  let message = object["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]],
                  let use = content.last(where: { $0["type"] as? String == "tool_use" }),
                  let name = use["name"] as? String else { return .ignored }
            return .tool(name: name, detail: toolDetail(use["input"] as? [String: Any] ?? [:]))
        case "result":
            let isError = object["is_error"] as? Bool ?? (object["subtype"] as? String != "success")
            return .finished(isError: isError, message: object["result"] as? String,
                             costUSD: object["total_cost_usd"] as? Double)
        default:
            return .ignored
        }
    }

    static func toolDetail(_ input: [String: Any]) -> String {
        for key in ["file_path", "path", "pattern", "command", "url", "query", "description"] {
            if let value = input[key] as? String, !value.isEmpty { return ClaudeSessions.oneLine(value) }
        }
        return ""
    }
}

/// What goes to the CLI's standard input for one user turn.
public enum ClaudeInput {
    public static func userMessage(_ text: String) -> Data {
        let message: [String: Any] = ["type": "user", "message": ["role": "user", "content": text]]
        var data = (try? JSONSerialization.data(withJSONObject: message)) ?? Data()
        data.append(UInt8(ascii: "\n"))
        return data
    }
}

/// Splits a byte stream into lines as it arrives.
public struct LineBuffer: Sendable {
    private var pending = Data()

    public init() {}

    public mutating func append(_ chunk: Data) -> [Data] {
        pending.append(chunk)
        var lines: [Data] = []
        while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
            let line = pending[pending.startIndex..<newline]
            if !line.isEmpty { lines.append(Data(line)) }
            pending.removeSubrange(pending.startIndex...newline)
        }
        return lines
    }
}
