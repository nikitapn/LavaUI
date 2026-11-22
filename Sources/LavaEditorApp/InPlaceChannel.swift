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
/// - Claude Code, not running: one more turn in Claude Code's background
///   service, `claude --bg --resume` in auto mode — the same as the chat
///   tab's Send.
/// - Claude Code, running: typed into its terminal — an editor tab it runs
///   in, or one the editor attaches for a background session. See
///   `EditorSession.deliver(_:toRunning:in:done:)`. Refused only for a
///   session in a terminal that is not ours; a fork still works there.
///
/// This is the real agent with its real tools: it may edit files rather
/// than propose a block. Every file it writes is reported as it goes, and
/// the editor re-reads open tabs whose files changed.
final class InPlaceChannel: AgentChatProcess, @unchecked Sendable {
    /// `live`: the turn is over when `claude agents` stops calling the
    /// session busy. `queued`: when the Codex rollout's turn closes.
    private enum Route { case live, queued }

    /// Changes when Claude Code continues the question in a copy.
    private var session: AgentSession
    /// The question as the transcript will show it, while the reply is
    /// being looked for in a copy's file: everything up to it is history.
    private var skipUntil: String?
    private var lastQuestion = ""
    private weak var editor: EditorSession?
    private let onEvent: (AgentEvent) -> Void
    private let onEdited: ([String]) -> Void

    // All of the below on the main queue only.
    private var turn = 0
    private var route = Route.live
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
        skipUntil = nil
        lastQuestion = text.trimmingCharacters(in: .whitespacesAndNewlines)
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
        route = .live
        guard let live else {
            let before = session
            let me = ChannelRef(self)
            run(ClaudeChatProcess.executable, EditorSession.backgroundResume(session.id, message: text)) { output in
                DispatchQueue.global(qos: .userInitiated).async {
                    let copy = EditorSession.continuation(of: before, output: output)
                    MainQueue.async { if let copy { me.channel?.switchTo(copy) } }
                }
            }
            return
        }
        guard let editor else { return }
        let me = ChannelRef(self)
        editor.deliver(text, toRunning: live, in: session.directory) { error in
            if let error { me.channel?.finish(error: error + " Pick Fork to ask a copy of it.") }
        }
    }

    /// The reply is in `copy`'s file: read it from the question on.
    private func switchTo(_ copy: AgentSession) {
        guard tail != nil, let file = copy.file else { return }
        session = copy
        tail = TranscriptTail(file: file, agent: copy.agent)
        skipUntil = lastQuestion
        onEvent(.tool(name: "Continued", detail: "in a copy, \(copy.id.prefix(8))"))
    }

    /// Reads what the session wrote since, twice a second, until the turn
    /// is over by the session's own account.
    private func follow(_ turn: Int) {
        guard turn == self.turn, var tail else { return }
        var entries = tail.read()
        self.tail = tail
        if let question = skipUntil {
            // History first, then the question, then the reply.
            if let at = entries.lastIndex(where: { $0.kind == .user && $0.text == question }) {
                entries = Array(entries[(at + 1)...])
                skipUntil = nil
            } else {
                entries = []
            }
        }
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
        case .queued:
            guard !processRunning else { return false }
            if sawReply, let file = session.file, !CodexSessions.turnOpen(file) { return true }
            // Nothing running picked it up: it waits in the session's queue.
            if !sawReply, Date().timeIntervalSince(quietSince) > 20 {
                onEvent(.text("Queued. The session will see it the next time it runs."))
                return true
            }
            return false
        case .live:
            // Nothing came at all: the session goes on without the box.
            if !sawReply, !processRunning, Date().timeIntervalSince(quietSince) > 120 {
                onEvent(.text("No answer yet. The session carries on; its chat in the Agents view follows it."))
                return true
            }
            // A terminal says nothing about turns; the CLI's list does.
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
                    if !busy, channel.tail != nil, channel.route == .live { channel.finish(error: nil) }
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

    private func run(_ executable: URL?, _ arguments: [String], succeeded: (@Sendable (String) -> Void)? = nil) {
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
            let text = String(decoding: data.suffix(4000), as: UTF8.self)
            let last = text.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
            let status = process.terminationStatus
            MainQueue.async {
                guard let channel = me.channel else { return }
                channel.processRunning = false
                if status != 0 { channel.finish(error: "\(executable.lastPathComponent) exited with status \(status): \(last)") }
                else { succeeded?(text) }
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
    /// The terminal — a panel tab or an agent's document tab — whose shell
    /// `pid` runs under, if any.
    func terminal(running pid: Int32) -> TerminalSession? {
        let shells = (terminal.tabs + agentTerminals.map(\.session)).compactMap { tab in tab.shellPid.map { ($0, tab) } }
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
