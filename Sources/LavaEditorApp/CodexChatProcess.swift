import Foundation
import LavaAgentCore
import LavaUI

/// What an inline chat talks to: a Claude Code process kept open, or Codex
/// started once per turn.
protocol AgentChatProcess: AnyObject {
    func send(_ text: String)
    func stop()
    /// Whether the process ending ends the conversation. Claude's runs
    /// for the whole chat; Codex's exits after every answer.
    var endsWithProcess: Bool { get }
}

extension ClaudeChatProcess: AgentChatProcess {
    var endsWithProcess: Bool { true }
}

/// Codex for an inline chat: `codex exec` once per question. The first is
/// `exec fork <id>` of the chosen session (or a plain `exec` for a new one);
/// every follow-up is `exec resume` of the thread that made, so only the
/// fork is ever appended to — never the session picked, which may be open
/// in the Codex app at this moment.
///
/// Read-only, and not only by sandbox. `sandbox_mode = "read-only"` alone
/// was not enough: with `approval_policy = "on-request"` the model asks to
/// run a write outside the sandbox, and a user whose config has
/// `approvals_reviewer = "auto_review"` gets it approved without being
/// asked — a fork wrote a file that way while this was being written.
/// `approval_policy = "never"` takes escalation away, so a write fails.
final class CodexChatProcess: AgentChatProcess, @unchecked Sendable {
    private let fork: String?
    private let directory: URL
    private let sink: Sink
    private let lock = NSLock()
    /// The thread this chat continues, once the first turn has said it.
    private var thread: String?
    private var current: Process?

    var endsWithProcess: Bool { false }

    init(
        resuming session: AgentSession?, in directory: URL,
        onEvent: @escaping (AgentEvent) -> Void,
        onExit: @escaping (_ status: Int32, _ stderr: String) -> Void
    ) throws {
        guard Self.executable != nil else { throw Failure.notInstalled }
        fork = session?.id
        self.directory = directory
        sink = Sink(onEvent: onEvent, onExit: onExit)
    }

    deinit { stop() }

    static let readOnly = ["-c", #"sandbox_mode="read-only""#, "-c", #"approval_policy="never""#]

    func send(_ text: String) {
        guard let executable = Self.executable else { return }
        let thread = lock.withLock { self.thread }
        var arguments: [String]
        if let thread {
            arguments = ["exec", "resume", "--json", "--skip-git-repo-check"] + Self.readOnly + model + [thread, "-"]
        } else if let fork {
            arguments = ["exec", "fork", "--json", "--skip-git-repo-check"] + Self.readOnly + model + [fork, "-"]
        } else {
            arguments = ["exec", "--json", "--skip-git-repo-check"] + Self.readOnly + model + ["-"]
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        let reader = TurnReader()
        let sink = self.sink
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            let events = reader.lines(data).flatMap(AgentEvent.codex)
            for case .started(let session, _) in events {
                self?.lock.withLock { if self?.thread == nil { self?.thread = session } }
            }
            if events.contains(where: { if case .finished = $0 { true } else { false } }) { reader.finished = true }
            guard !events.isEmpty else { return }
            MainQueue.async { for event in events { sink.onEvent(event) } }
        }
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            reader.error(data)
        }
        process.terminationHandler = { [weak self] process in
            // An answer ends the process every time; only one that ended
            // without finishing its turn is news.
            let status = process.terminationStatus
            self?.lock.withLock { if self?.current === process { self?.current = nil } }
            guard !reader.finished else { return }
            let tail = reader.errorText
            MainQueue.async { sink.onExit(status, tail) }
        }
        do {
            try process.run()
        } catch {
            MainQueue.async { sink.onExit(-1, "\(error)") }
            return
        }
        lock.withLock { current = process }
        try? input.fileHandleForWriting.write(contentsOf: Data(text.utf8))
        try? input.fileHandleForWriting.close()
    }

    func stop() {
        let process = lock.withLock { current }
        if let process, process.isRunning { process.terminate() }
    }

    private var model: [String] {
        guard let model = ProcessInfo.processInfo.environment["LAVAEDITOR_CODEX_MODEL"], !model.isEmpty else { return [] }
        return ["-m", model]
    }

    /// One turn's output, read on the pipes' threads.
    private final class TurnReader: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = LineBuffer()
        private var stderr = Data()
        private var done = false

        var finished: Bool {
            get { lock.withLock { done } }
            set { lock.withLock { done = newValue } }
        }

        func lines(_ data: Data) -> [Data] { lock.withLock { buffer.append(data) } }

        func error(_ data: Data) {
            lock.withLock {
                stderr.append(data)
                if stderr.count > 8192 { stderr = stderr.suffix(8192) }
            }
        }

        var errorText: String { lock.withLock { String(decoding: stderr, as: UTF8.self) } }
    }

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
        var description: String { "The codex command was not found on PATH or in ~/.local/bin." }
    }

    static let executable: URL? = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for directory in path + [home + "/.local/bin", "/usr/local/bin", "/usr/bin"] {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent("codex")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }()
}
