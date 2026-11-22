import Foundation
import LavaAgentCore
import LavaUI
import Observation

/// An agent session's conversation in a tab, read from the file its CLI
/// writes and followed as it grows — so the tab shows what the agent is
/// doing while it does it, wherever it is running.
///
/// Saying something to it goes through the CLI, and never as a second
/// writer on a session that is running: two processes appending to one
/// conversation is how it gets corrupted. Codex has a command for exactly
/// this (`codex queue`). A Claude Code session nothing runs gets one more
/// turn in the background service; a running one has the message typed into
/// its terminal (`EditorSession.deliver`), or is refused when that terminal
/// is not the editor's.
@Observable
final class SessionTranscript {
    /// The session followed. Changes when Claude Code continues a message in
    /// a copy — see `EditorSession.continuation(of:output:)`.
    private(set) var session: AgentSession
    private(set) var entries: [TranscriptEntry] = []
    /// The start of a long file was skipped.
    private(set) var truncated = false
    var draft = ""
    var inputFocused = false
    /// A turn this tab started is running.
    private(set) var sending = false
    /// What the last send or check had to say.
    var notice: String?

    @ObservationIgnored let scroll = ScrollPosition()
    @ObservationIgnored private var reader: Reader?
    @ObservationIgnored private weak var editor: EditorSession?

    /// Entries kept for the view: a long session's whole history would be
    /// thousands of rows, and what is going on is at the end.
    static let shownEntries = 300

    init(session: AgentSession, editor: EditorSession) {
        self.session = session
        self.editor = editor
        reader = session.file.map { Reader(TranscriptTail(file: $0, agent: session.agent)) }
        follow()
    }

    // MARK: - Following the file

    /// Reads what was appended, about once a second, for as long as the tab
    /// exists. Cheap when nothing was: a seek and an empty read.
    private func follow() {
        guard let reader else { return }
        let ref = TranscriptRef(self)
        reader.queue.async {
            let (new, truncated) = reader.read()
            MainQueue.async {
                guard let transcript = ref.transcript else { return }
                // Switched to another file meanwhile: this read is the old
                // one's. Dropped, and the next tick reads the new file.
                let current = transcript.reader === reader
                if current, truncated != transcript.truncated { transcript.truncated = truncated }
                if current, !new.isEmpty {
                    transcript.entries.append(contentsOf: new)
                    if transcript.entries.count > Self.shownEntries {
                        transcript.entries.removeFirst(transcript.entries.count - Self.shownEntries)
                        transcript.truncated = true
                    }
                    transcript.scroll.scroll(to: 1e9)
                }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
                    MainQueue.async { ref.transcript?.follow() }
                }
            }
        }
    }

    /// Follows `copy` from now on: the whole conversation is in it, so the
    /// tab is read again from its file.
    private func follow(_ copy: AgentSession) {
        session = copy
        entries = []
        truncated = false
        reader = copy.file.map { Reader(TranscriptTail(file: $0, agent: copy.agent)) }
        notice = "Claude Code continued this in a copy (\(copy.id.prefix(8))); following that here."
    }

    // MARK: - Talking to it

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        switch session.agent {
        case .codex: queueForCodex(text)
        case .claude: continueClaude(text)
        }
    }

    /// `codex queue`: the message waits for the session, and is picked up
    /// by it if it is running (`--resume` asks the local daemon to).
    private func queueForCodex(_ text: String) {
        guard let executable = CodexChatProcess.executable else {
            notice = CodexChatProcess.Failure.notInstalled.description
            return
        }
        sending = true
        draft = ""
        run(executable, ["queue", "--thread", session.id, "--message", text, "--resume"], in: session.directory) { status, output in
            let last = output.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
            self.notice = status == 0 ? "Queued for this session." : "codex queue failed: \(last)"
        }
    }

    /// A message for a Claude Code session. Running, it is typed into its
    /// terminal. Stopped, it is one more turn in Claude Code's background
    /// service (`claude --bg --resume`, auto mode): the turn outlives the
    /// editor, `claude agents` reports it while it works — so the status dot
    /// is the CLI's answer rather than a guess — and a call auto mode cannot
    /// decide waits for whoever attaches instead of being refused. Its
    /// progress shows up here through the file, like anyone's.
    private func continueClaude(_ text: String) {
        guard let executable = ClaudeChatProcess.executable else {
            notice = ClaudeChatProcess.Failure.notInstalled.description
            return
        }
        sending = true
        notice = "Checking whether the session is running…"
        let session = self.session
        let ref = TranscriptRef(self)
        DispatchQueue.global(qos: .userInitiated).async {
            let live = ClaudeAgentsQuery.run().first { $0.session == session.id }
            MainQueue.async {
                guard let transcript = ref.transcript else { return }
                if let live {
                    // Running: typed into its terminal — the editor's tab it
                    // runs in, or one attached for a background session.
                    guard let editor = transcript.editor else { return }
                    editor.deliver(text, toRunning: live, in: session.directory) { error in
                        transcript.sending = false
                        if let error {
                            transcript.notice = error
                        } else {
                            transcript.draft = ""
                            transcript.notice = nil
                        }
                    }
                    return
                }
                // Stopped: one more turn in Claude Code's background service.
                transcript.draft = ""
                transcript.notice = "Continuing in the background…"
                transcript.run(executable, EditorSession.backgroundResume(session.id, message: text),
                               in: session.directory) { status, output in
                    guard status == 0 else {
                        let last = output.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
                        transcript.notice = "claude exited with status \(status): \(last)"
                        return
                    }
                    transcript.notice = nil
                    DispatchQueue.global(qos: .userInitiated).async {
                        let copy = EditorSession.continuation(of: session, output: output)
                        MainQueue.async { if let copy { ref.transcript?.follow(copy) } }
                    }
                }
            }
        }
    }

    private func run(_ executable: URL, _ arguments: [String], in directory: URL,
                     done: @escaping (Int32, String) -> Void) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        for key in ["CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SSE_PORT"] { environment[key] = nil }
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        let ref = TranscriptRef(self)
        let box = DoneBox(done)
        process.terminationHandler = { process in
            let data = (try? output.fileHandleForReading.readToEnd()) ?? Data()
            let text = String(decoding: data.suffix(4000), as: UTF8.self)
            let status = process.terminationStatus
            MainQueue.async {
                ref.transcript?.sending = false
                box.done(status, text)
            }
        }
        do {
            try process.run()
        } catch {
            sending = false
            notice = "\(error)"
        }
    }

    /// The command that opens this session interactively, for the terminal
    /// panel: attach to it while it runs in the background, resume it
    /// otherwise. Nil while it runs in some other terminal.
    func terminalCommand(live: ClaudeLiveSession?) -> String? {
        switch session.agent {
        case .codex:
            return "codex resume \(session.id)"
        case .claude:
            guard let live else { return "claude --resume \(session.id)" }
            return live.kind == "background" ? "claude attach \(live.name.isEmpty ? session.id : live.name)" : nil
        }
    }

    func openInTerminal() {
        let session = self.session
        let ref = TranscriptRef(self)
        let probe = session.agent == .claude
        DispatchQueue.global(qos: .userInitiated).async {
            let live = probe ? ClaudeAgentsQuery.run().first { $0.session == session.id } : nil
            MainQueue.async {
                guard let transcript = ref.transcript else { return }
                guard let command = transcript.terminalCommand(live: live) else {
                    transcript.notice = "Already open in a terminal (pid \(live?.pid ?? 0))."
                    return
                }
                transcript.editor?.newTerminal(in: session.directory, typing: command)
            }
        }
    }

    /// The tail, read on its own queue — never two reads at once.
    private final class Reader: @unchecked Sendable {
        let queue = DispatchQueue(label: "lava.transcript")
        private var tail: TranscriptTail

        init(_ tail: TranscriptTail) { self.tail = tail }

        func read() -> ([TranscriptEntry], Bool) {
            let entries = tail.read()
            return (entries, tail.truncated)
        }
    }

    private final class DoneBox: @unchecked Sendable {
        let done: (Int32, String) -> Void
        init(_ done: @escaping (Int32, String) -> Void) { self.done = done }
    }
}

private struct TranscriptRef: @unchecked Sendable {
    weak var transcript: SessionTranscript?
    init(_ transcript: SessionTranscript) { self.transcript = transcript }
}

/// A session's chat in its tab: who said what, one line per tool, and a
/// field to say more.
struct SessionTranscriptView: View {
    let session: EditorSession
    let transcript: SessionTranscript
    let appearance: EditorAppearance

    var body: some View {
        let theme = appearance.theme
        let agent = transcript.session
        // Prose: the UI's face, as the inline chat has; code blocks inside
        // are the Markdown view's own business.
        let font = session.fonts.tab
        return VStack(flexGrow: 1, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                Text(InlineChatView.name(agent.agent), color: theme.accent, font: session.fonts.statusEmphasis)
                Text(agent.title, color: .primary, font: session.fonts.tab, lineLimit: 1)
                    .flexShrink(1)
                Text(agent.directory.lastPathComponent, color: .muted, font: session.fonts.status, lineLimit: 1)
                Spacer()
                Button("Open in Terminal") { transcript.openInTerminal() }
                    .agentId("chat-terminal")
            }
            .padding(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 12))
            .background(theme.panel)
            ScrollView(.vertical, position: transcript.scroll) {
                VStack(spacing: 10) {
                    if transcript.truncated {
                        Text("Earlier messages are not shown.", color: .muted, font: session.fonts.status)
                    }
                    if transcript.entries.isEmpty, !transcript.truncated {
                        Text(agent.file == nil ? "This session's file was not found." : "Nothing said yet.",
                             color: .muted, font: session.fonts.status)
                    }
                    ForEach(Array(transcript.entries.enumerated()), id: \.offset) { _, entry in
                        self.entry(entry, font: font, theme: theme)
                    }
                }
                .padding(EdgeInsets(top: 14, leading: 20, bottom: 14, trailing: 20))
            }
            .flexGrow(1)
            .theme(appearance.documentTheme)
            .agentId("chat-transcript")
            if let notice = transcript.notice {
                Text(notice, color: .muted, font: session.fonts.status)
                    .padding(EdgeInsets(top: 6, leading: 16, bottom: 0, trailing: 16))
                    .agentId("chat-notice")
            }
            HStack(alignment: .center, spacing: 8) {
                TextField(
                    text: Binding(get: { transcript.draft }, set: { transcript.draft = $0 }),
                    placeholder: agent.agent == .codex
                        ? "Queue a message for this session…"
                        : "Message this session — typed into its terminal while it runs, continued in the background when it does not…",
                    font: session.fonts.tab,
                    onSubmit: { transcript.send() }
                )
                .focused(Binding(get: { transcript.inputFocused }, set: { transcript.inputFocused = $0 }))
                .flexGrow(1)
                .agentId("chat-input")
                Button(transcript.sending ? "Sending…" : "Send") { transcript.send() }
                    .agentId("chat-send")
            }
            .padding(EdgeInsets(top: 8, leading: 16, bottom: 10, trailing: 12))
        }
    }

    @ViewBuilder
    private func entry(_ entry: TranscriptEntry, font: UIFont?, theme: Theme) -> some View {
        switch entry.kind {
        case .user:
            Text(entry.text, color: .primary, font: font)
                .padding(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                .background(theme.selectionFill)
                .cornerRadius(10)
        case .assistant:
            MarkdownView(entry.text, font: font)
        case .tool:
            Text("› " + entry.text, color: .muted, font: session.fonts.status, lineLimit: 1)
        }
    }
}
