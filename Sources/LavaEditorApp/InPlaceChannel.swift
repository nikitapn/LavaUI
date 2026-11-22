import Foundation
import Glibc
import LavaAgentCore
import LavaTerminal
import LavaUI

/// The inline chat asking a session itself rather than a fork of it: the
/// question lands in that conversation, and the answer is read back from
/// the session's file the way the chat tab reads it.
///
/// How it gets there depends on where the session is, and never makes a
/// second writer on a running conversation:
/// - Codex: `codex queue --resume`, always.
/// - Claude Code, not running: one more turn, `claude -p --resume` in auto
///   mode — the same as the chat tab's Send.
/// - Claude Code, running in this editor's terminal panel: the question is
///   typed into that terminal, as a bracketed paste so a question of
///   several lines arrives whole, and Enter. It queues if a turn is running.
/// - Claude Code, running anywhere else: refused — that terminal is the
///   only way in, and it is not ours. A fork still works.
///
/// This is the real agent with its real tools: it may edit files rather
/// than propose a block. Every file it writes is reported as it goes, and
/// the editor re-reads open tabs whose files changed.
final class InPlaceChannel: AgentChatProcess, @unchecked Sendable {
    private enum Route { case process, terminal, queued }

    private let session: AgentSession
    private weak var editor: EditorSession?
    private let onEvent: (AgentEvent) -> Void
    private let onEdited: ([String]) -> Void

    // All of the below on the main queue only.
    private var turn = 0
    private var route = Route.process
    private var tail: TranscriptTail?
    private var sawReply = false
    private var processRunning = false
    private var quietSince = Date()
    private var lastLiveCheck = Date.distantPast
    private var liveCheckRunning = false

    var endsWithProcess: Bool { false }

    init(session: AgentSession, editor: EditorSession, onEvent: @escaping (AgentEvent) -> Void,
         onEdited: @escaping ([String]) -> Void) {
        self.session = session
        self.editor = editor
        self.onEvent = onEvent
        self.onEdited = onEdited
    }

    func stop() {
        // The turn is the session's own and goes on; this only stops
        // listening to it.
        turn &+= 1
        tail = nil
    }

    func send(_ text: String) {
        guard let file = session.file else {
            finish(error: "This session's file was not found.")
            return
        }
        turn &+= 1
        sawReply = false
        quietSince = Date()
        // From the end as it is now: the reply is whatever comes after.
        var fresh = TranscriptTail(file: file, agent: session.agent, fromEnd: true)
        _ = fresh.read()
        tail = fresh
        switch session.agent {
        case .codex:
            route = .queued
            run(CodexChatProcess.executable, ["queue", "--thread", session.id, "--message", text, "--resume"])
        case .claude:
            let id = session.id
            let me = ChannelRef(self)
            DispatchQueue.global(qos: .userInitiated).async {
                let live = ClaudeAgentsQuery.run().first { $0.session == id }
                MainQueue.async { me.channel?.deliverToClaude(text, live: live) }
            }
        }
        follow(turn)
    }

    private func deliverToClaude(_ text: String, live: ClaudeLiveSession?) {
        guard let live else {
            route = .process
            var arguments = ["-p", "--resume", session.id, "--permission-mode", "auto", "--permission-prompts", "none"]
            if let model = ProcessInfo.processInfo.environment["LAVAEDITOR_CLAUDE_MODEL"], !model.isEmpty {
                arguments += ["--model", model]
            }
            run(ClaudeChatProcess.executable, arguments + [text])
            return
        }
        guard let terminal = editor?.terminal(running: live.pid) else {
            let place = live.kind == "background" ? "in the background (\(live.name))" : "in a terminal outside LavaEditor (pid \(live.pid))"
            finish(error: "This session is running \(place), and only that can talk to it. Pick Fork to ask a copy of it.")
            return
        }
        route = .terminal
        // Bracketed paste: the TUI takes the lines as one message rather
        // than sending at the first newline. Then Enter.
        terminal.write("\u{1b}[200~" + text + "\u{1b}[201~")
        terminal.write("\r")
    }

    /// Reads what the session wrote since, twice a second, until the turn
    /// is over by the session's own account.
    private func follow(_ turn: Int) {
        guard turn == self.turn, var tail else { return }
        let entries = tail.read()
        self.tail = tail
        if !entries.isEmpty { quietSince = Date() }
        for entry in entries {
            if entry.kind == .assistant { sawReply = true }
            for event in entry.event { onEvent(event) }
        }
        let edited = entries.flatMap(\.editedPaths)
        if !edited.isEmpty { onEdited(edited) }
        if turnOver() {
            finish(error: nil)
            return
        }
        let me = ChannelRef(self)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
            MainQueue.async { me.channel?.follow(turn) }
        }
    }

    private func turnOver() -> Bool {
        switch route {
        case .process:
            // A `claude -p` turn is over when the process is; the file was
            // read once more after it ended, above.
            guard !processRunning else { return false }
            return sawReply || Date().timeIntervalSince(quietSince) > 3
        case .queued:
            guard !processRunning else { return false }
            if sawReply, let file = session.file, !CodexSessions.turnOpen(file) { return true }
            // Nothing running picked it up: it waits in the session's queue.
            if !sawReply, Date().timeIntervalSince(quietSince) > 20 {
                onEvent(.text("Queued. The session will see it the next time it runs."))
                return true
            }
            return false
        case .terminal:
            // The terminal says nothing about turns; the CLI's list does.
            guard sawReply, !liveCheckRunning, Date().timeIntervalSince(lastLiveCheck) > 1.5 else { return false }
            lastLiveCheck = Date()
            liveCheckRunning = true
            let id = session.id
            let me = ChannelRef(self)
            DispatchQueue.global(qos: .utility).async {
                let busy = ClaudeAgentsQuery.run().first { $0.session == id }?.status == .working
                MainQueue.async {
                    guard let channel = me.channel else { return }
                    channel.liveCheckRunning = false
                    if !busy, channel.tail != nil, channel.route == .terminal { channel.finish(error: nil) }
                }
            }
            return false
        }
    }

    private func finish(error: String?) {
        guard tail != nil || error != nil else { return }
        turn &+= 1
        tail = nil
        // A shell command can write a file as well as an Edit can, and
        // only the files' own bytes say which.
        editor?.rereadChangedDocuments()
        onEvent(.finished(isError: error != nil, message: error, costUSD: nil))
    }

    private func run(_ executable: URL?, _ arguments: [String]) {
        guard let executable else {
            finish(error: "The \(session.agent == .claude ? "claude" : "codex") command was not found.")
            return
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = session.directory
        var environment = ProcessInfo.processInfo.environment
        for key in ["CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SSE_PORT"] { environment[key] = nil }
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        let me = ChannelRef(self)
        process.terminationHandler = { process in
            let data = (try? output.fileHandleForReading.readToEnd()) ?? Data()
            let last = String(decoding: data.suffix(2000), as: UTF8.self)
                .split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
            let status = process.terminationStatus
            MainQueue.async {
                guard let channel = me.channel else { return }
                channel.processRunning = false
                if status != 0 { channel.finish(error: "\(executable.lastPathComponent) exited with status \(status): \(last)") }
            }
        }
        processRunning = true
        do {
            try process.run()
        } catch {
            processRunning = false
            finish(error: "\(error)")
        }
    }
}

private struct ChannelRef: @unchecked Sendable {
    weak var channel: InPlaceChannel?
    init(_ channel: InPlaceChannel) { self.channel = channel }
}

extension EditorSession {
    /// The terminal tab whose shell `pid` runs under, if any.
    func terminal(running pid: Int32) -> TerminalSession? {
        let shells = terminal.tabs.compactMap { tab in tab.shellPid.map { ($0, tab) } }
        guard !shells.isEmpty else { return nil }
        var current = pid
        for _ in 0..<64 {
            if let match = shells.first(where: { $0.0 == current }) { return match.1 }
            guard current > 1, let parent = Self.parentPid(of: current) else { return nil }
            current = parent
        }
        return nil
    }

    /// The fourth field of `/proc/<pid>/stat`. The name in parentheses may
    /// itself hold spaces and parentheses, so the fields are counted from
    /// the last `)`.
    static func parentPid(of pid: Int32) -> Int32? {
        guard let stat = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
              let close = stat.lastIndex(of: ")") else { return nil }
        let fields = stat[stat.index(after: close)...].split(separator: " ")
        return fields.count > 1 ? Int32(fields[1]) : nil
    }

    /// Re-reads every open, unmodified file whose bytes on disk are not what
    /// the tab shows — after an agent wrote them. A tab with unsaved edits is
    /// left alone: those edits are the user's, and the next save decides.
    func rereadChangedDocuments() {
        stashPosition()
        for index in documents.indices {
            let document = documents[index]
            guard let url = document.url, document.isLoaded, !document.isModified, document.preview == nil,
                  let data = try? Data(contentsOf: url), data != Data(document.text.utf8) else { continue }
            _ = documents[index].load()
            if index == activeIndex { controller.restore(documents[index].position ?? .start) }
            refreshBaseline(index)
        }
    }
}
