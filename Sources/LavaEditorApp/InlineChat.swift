import Foundation
import LavaAgentCore
import LavaUI
import Observation

/// A conversation about some lines, held in a box between them (Ctrl+I).
///
/// It asks a chosen Claude Code session — forked, so the original is left
/// alone — or a new one. What it proposes to change comes back as the
/// complete new text of those lines and is shown as a diff before anything
/// is applied; accepting is one undo step.
@Observable
final class InlineChat {
    struct Turn: Equatable {
        var question: String
        var reply = ""
        /// Tools it used while answering, as one-line descriptions.
        var activity: [String] = []
        var finished = false
        var failure: String?
    }

    let documentID: Int
    /// The logical lines asked about, 0-based.
    let lines: ClosedRange<Int>
    /// Their text when the question was asked. A proposal applies to these
    /// lines only while they still read this — see `EditorSession.acceptProposal`.
    let original: String
    /// The file as the agent should hear it named: relative to the folder.
    let path: String
    let language: String
    /// Where the agent runs when no session is picked.
    let directory: URL

    private(set) var sessions: [AgentSession] = []
    private(set) var sessionsLoaded = false
    /// The session to fork; nil for a new one. Fixed once the first
    /// question is sent — the process is that session's from then on.
    var choice: AgentSession?
    var pickingSession = false
    var draft = ""
    var inputFocused = true
    private(set) var turns: [Turn] = []
    /// The replacement for `lines` in the latest reply that had one.
    private(set) var proposal: String?
    /// The id the forked (or new) conversation is saved under.
    private(set) var forkedSession: String?
    private(set) var model = ""

    @ObservationIgnored private var process: ClaudeChatProcess?
    /// The transcript follows the reply as it streams in.
    @ObservationIgnored let scroll = ScrollPosition()

    init(documentID: Int, lines: ClosedRange<Int>, original: String, path: String,
         language: String, directory: URL) {
        self.documentID = documentID
        self.lines = lines
        self.original = original
        self.path = path
        self.language = language
        self.directory = directory
    }

    deinit { process?.stop() }

    var busy: Bool { turns.last.map { !$0.finished } ?? false }
    var started: Bool { !turns.isEmpty }

    /// Rows of the editor the box takes. Fixed steps rather than following
    /// the transcript line by line: every change of height moves the text
    /// under the box, and text that jumps while you read a reply is worse
    /// than a reply that scrolls.
    var rows: Int {
        if pickingSession { return 12 }
        return started ? 16 : 4
    }

    func adopt(sessions: [AgentSession]) {
        self.sessions = sessions
        sessionsLoaded = true
    }

    // MARK: - Talking

    func send(onExit: @escaping () -> Void) {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !busy else { return }
        draft = ""
        pickingSession = false
        if process == nil {
            do {
                process = try ClaudeChatProcess(
                    resuming: choice, in: choice?.directory ?? directory,
                    onEvent: { [weak self] event in self?.handle(event) },
                    onExit: { [weak self] status, stderr in
                        self?.exited(status: status, stderr: stderr)
                        onExit()
                    }
                )
            } catch {
                turns.append(Turn(question: question, finished: true, failure: "\(error)"))
                return
            }
        }
        // The first question carries the lines; follow-ups are about them.
        let message = turns.isEmpty
            ? InlineChatPrompt.question(question, path: path, lines: (lines.lowerBound + 1)...(lines.upperBound + 1),
                                        language: language, text: original)
            : InlineChatPrompt.followUp(question)
        turns.append(Turn(question: question))
        process?.send(message)
    }

    func stop() {
        process?.stop()
        process = nil
    }

    private func handle(_ event: ClaudeEvent) {
        defer { if event != .ignored { scroll.scroll(to: 1e9) } }
        switch event {
        case .started(let session, let model):
            forkedSession = session
            self.model = model
        case .textBlock:
            guard var turn = turns.last, !turn.reply.isEmpty, !turn.reply.hasSuffix("\n\n") else { return }
            turn.reply += "\n\n"
            turns[turns.count - 1] = turn
        case .text(let text):
            guard !turns.isEmpty else { return }
            turns[turns.count - 1].reply += text
        case .tool(let name, let detail):
            guard !turns.isEmpty else { return }
            turns[turns.count - 1].activity.append(detail.isEmpty ? name : "\(name) \(detail)")
        case .finished(let isError, let message, _):
            guard var turn = turns.last else { return }
            turn.finished = true
            if isError { turn.failure = message ?? "The turn failed." }
            else if turn.reply.isEmpty, let message { turn.reply = message }
            turns[turns.count - 1] = turn
            if let replacement = InlineChatPrompt.proposedReplacement(in: turn.reply) {
                proposal = replacement
            }
        case .ignored:
            break
        }
    }

    private func exited(status: Int32, stderr: String) {
        process = nil
        guard var turn = turns.last, !turn.finished else { return }
        turn.finished = true
        let reason = stderr.split(whereSeparator: \.isNewline).last.map(String.init)
        turn.failure = reason ?? "claude exited with status \(status)."
        turns[turns.count - 1] = turn
    }

    /// The proposal as the reply shows it, minus the fenced block itself —
    /// that is what the diff is for.
    static func prose(_ reply: String) -> String {
        guard InlineChatPrompt.proposedReplacement(in: reply) != nil else { return reply }
        var out: [Substring] = []
        var skipping: Substring?
        for line in reply.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.drop { $0 == " " }
            if let fence = skipping {
                if trimmed.hasPrefix(fence), trimmed.drop(while: { $0 == "`" || $0 == "~" }).allSatisfy(\.isWhitespace) {
                    skipping = nil
                    out.append("[proposed change — Review to see it]")
                }
                continue
            }
            if let mark = trimmed.first, mark == "`" || mark == "~" {
                let fence = trimmed.prefix { $0 == mark }
                if fence.count >= 3,
                   trimmed.dropFirst(fence.count).split(whereSeparator: \.isWhitespace).contains(where: { $0 == InlineChatPrompt.replaceTag }) {
                    skipping = fence
                    continue
                }
            }
            out.append(line)
        }
        return out.joined(separator: "\n")
    }
}

extension EditorSession {
    /// Ctrl+I: a box below the selected lines, or the caret's line. Again on
    /// an open box goes back to its input.
    func openInlineChat() {
        if let chat = inlineChat, chat.documentID == active.id {
            chat.inputFocused = true
            return
        }
        guard active.preview == nil, active.isLoaded else { return }
        guard let position = controller.position() else { return }
        let text = active.text
        let lines = TextLines.lines(in: text, from: position.anchor, to: position.focus)
        guard let original = TextLines.text(of: lines, in: text) else { return }
        let root = project?.tree.root ?? active.url?.deletingLastPathComponent()
            ?? FileManager.default.homeDirectoryForCurrentUser
        let path = active.url.map { url in
            project?.tree.path(of: url).flatMap { $0.isEmpty ? nil : $0 } ?? url.path
        } ?? active.name
        closeInlineChat()
        let chat = InlineChat(
            documentID: active.id, lines: lines, original: original, path: path,
            language: active.language.rawValue, directory: root
        )
        inlineChat = chat
        chatAnchor.line = lines.upperBound + 1
        loadAgentSessions(for: chat)
    }

    func closeInlineChat() {
        inlineChat?.stop()
        inlineChat = nil
        if let diff, diff.proposalAccept != nil { closeDiff() }
        controller.focus()
    }

    /// This project's sessions, from its folder and its other worktrees —
    /// a session started in an agent's worktree is one you may well want to
    /// ask about the same file here.
    private func loadAgentSessions(for chat: InlineChat) {
        let directory = chat.directory
        let repository = project?.repository
        let ref = ChatRef(chat)
        DispatchQueue.global(qos: .userInitiated).async {
            var folders = [directory]
            if let repository {
                folders.append(repository.root)
                folders += (try? repository.worktrees().map(\.root)) ?? []
            }
            let sessions = ClaudeSessions.list(in: folders)
            MainQueue.async { ref.chat?.adopt(sessions: sessions) }
        }
    }

    func sendInlineChat() {
        guard let chat = inlineChat else { return }
        chat.send(onExit: {})
    }

    /// The proposal as a diff: the document as it is against the document
    /// with the lines replaced. Read-only on both sides — the choice is to
    /// take it or leave it, and the editor is where to change it after.
    func reviewProposal() {
        guard let chat = inlineChat, let proposal = chat.proposal,
              let index = documents.firstIndex(where: { $0.id == chat.documentID }) else { return }
        let document = documents[index]
        guard TextLines.text(of: chat.lines, in: document.text) == chat.original else {
            notice = "Those lines have changed since the question; ask again to get a proposal for them as they are."
            return
        }
        guard let proposed = TextLines.replacing(chat.lines, in: document.text, with: proposal) else { return }
        let owner = SessionRef(session: self)
        diff = DiffModel(
            old: document.text, new: proposed,
            oldTitle: "Editor · \(chat.path)", newTitle: "Proposed · \(chat.path)",
            highlighter: document.language.highlighter, documentID: document.id, isEditable: false,
            proposalAccept: { owner.session.acceptProposal() }
        )
        if !(diff?.diff.isEmpty ?? true) { stepDiff(forward: true) }
    }

    /// Replaces the lines with the proposal as one undo step, if they still
    /// read what they did when asked about.
    func acceptProposal() {
        guard let chat = inlineChat, let proposal = chat.proposal,
              chat.documentID == active.id else { return }
        closeDiff()
        guard TextLines.text(of: chat.lines, in: active.text) == chat.original,
              let range = TextLines.characterRange(of: chat.lines, in: active.text) else {
            notice = "Those lines have changed since the question; the proposal was not applied."
            return
        }
        let applied = { [weak self] in
            guard let self else { return }
            if self.controller.insert(proposal, replacing: range) {
                self.notice = "Applied the proposed change · Ctrl+Z undoes it"
                self.closeInlineChat()
            }
        }
        // The document's editor is mounted again only once the diff is gone.
        FrameTasks.after(applied)
    }
}

/// Carried to a worker and back; only dereferenced on the main queue.
struct ChatRef: @unchecked Sendable {
    weak var chat: InlineChat?
    init(_ chat: InlineChat) { self.chat = chat }
}
