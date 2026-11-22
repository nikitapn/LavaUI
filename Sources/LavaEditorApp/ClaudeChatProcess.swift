import Foundation
import LavaAgentCore
import LavaUI

/// One `claude -p` for one inline chat, kept running between questions: its
/// input is a stream of user messages, so a follow-up is another line on
/// its standard input rather than another process resuming from disk.
///
/// Read-only on purpose. Its tools are Read, Grep and Glob, and nothing
/// else is allowed — the chat proposes a replacement in its reply and the
/// editor applies it, after the user has looked at the diff. An agent that
/// wrote the file itself would write under an open buffer with unsaved
/// edits, and the next save would put the old text back.
///
/// A resumed session is *forked*: the conversation continues under a new
/// id and the original file is never appended to. The session picked may be
/// open in a terminal at this moment, and two writers on one session is the
/// hazard that matters.
final class ClaudeChatProcess: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let lock = NSLock()
    private var lines = LineBuffer()
    private var errorTail = Data()

    /// `onEvent` and `onExit` are called on the main queue.
    init(
        resuming session: AgentSession?, in directory: URL,
        onEvent: @escaping (AgentEvent) -> Void,
        onExit: @escaping (_ status: Int32, _ stderr: String) -> Void
    ) throws {
        let sink = Sink(onEvent: onEvent, onExit: onExit)
        guard let executable = Self.executable else { throw Failure.notInstalled }
        process.executableURL = executable
        var arguments = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--tools", "Read,Grep,Glob",
            "--allowedTools", "Read,Grep,Glob",
            "--permission-mode", "dontAsk",
            "--append-system-prompt", InlineChatPrompt.instructions,
        ]
        if let session { arguments += ["--resume", session.id, "--fork-session"] }
        // Otherwise the CLI's own default, as in a terminal.
        if let model = ProcessInfo.processInfo.environment["LAVAEDITOR_CLAUDE_MODEL"], !model.isEmpty {
            arguments += ["--model", model]
        }
        process.arguments = arguments
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        // Started from a terminal that is itself inside Claude Code, these
        // would make the child think it is a nested tool call of that one.
        for key in ["CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SSE_PORT"] { environment[key] = nil }
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            let complete = self.lock.withLock { self.lines.append(data) }
            let events = complete.map(AgentEvent.claude).filter { $0 != .ignored }
            guard !events.isEmpty else { return }
            MainQueue.async { for event in events { sink.onEvent(event) } }
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self.lock.withLock {
                self.errorTail.append(data)
                if self.errorTail.count > 8192 { self.errorTail = self.errorTail.suffix(8192) }
            }
        }
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            let tail = self.map { me in me.lock.withLock { String(decoding: me.errorTail, as: UTF8.self) } } ?? ""
            MainQueue.async { sink.onExit(status, tail) }
        }
        try process.run()
    }

    deinit { stop() }

    /// One user turn.
    func send(_ text: String) {
        guard process.isRunning else { return }
        try? input.fileHandleForWriting.write(contentsOf: ClaudeInput.userMessage(text))
    }

    /// Ends the chat: input closed (which ends a `-p` session on its own),
    /// then a terminate for one that is in the middle of a turn.
    func stop() {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }

    /// The callbacks, carried to the reader threads and only called back on
    /// the main queue.
    private final class Sink: @unchecked Sendable {
        let onEvent: (AgentEvent) -> Void
        let onExit: (Int32, String) -> Void
        init(onEvent: @escaping (AgentEvent) -> Void, onExit: @escaping (Int32, String) -> Void) {
            self.onEvent = onEvent
            self.onExit = onExit
        }
    }

    enum Failure: Error, CustomStringConvertible {
        case notInstalled
        var description: String { "The claude command was not found on PATH or in ~/.local/bin." }
    }

    /// `claude` on `PATH`, else where its installer puts it — an editor
    /// started from a desktop launcher often has a shorter `PATH` than the
    /// terminal the user installed it from.
    static let executable: URL? = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for directory in path + [home + "/.local/bin", home + "/.claude/local", "/usr/local/bin", "/usr/bin"] {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent("claude")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }()
}
