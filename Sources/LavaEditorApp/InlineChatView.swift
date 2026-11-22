import Foundation
import LavaAgentCore
import LavaUI

/// The box between the lines: which session, what was said, and the field
/// to say more. Laid over the editor's gap by `.editorZone`.
struct InlineChatView: View {
    let session: EditorSession
    let chat: InlineChat
    let appearance: EditorAppearance

    var body: some View {
        let theme = appearance.theme
        return VStack(flexGrow: 1, spacing: 6) {
            header(theme: theme)
            if chat.pickingSession {
                sessionList(theme: theme)
            } else if chat.started {
                transcript(theme: theme)
            }
            input(theme: theme)
        }
        .padding(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
        .background(theme.panel)
        .border(theme.accent.opacity(0.55), width: 1)
        .cornerRadius(10)
        .padding(EdgeInsets(top: 3, leading: 6, bottom: 3, trailing: 18))
        .agentId("inline-chat")
    }

    // MARK: - Top

    private func header(theme: Theme) -> some View {
        let session = self.session
        let chat = self.chat
        let place = chat.lines.count == 1
            ? "line \(chat.lines.lowerBound + 1)"
            : "lines \(chat.lines.lowerBound + 1)–\(chat.lines.upperBound + 1)"
        let sessionTitle = chat.choice.map { (chat.inPlace ? "" : "Fork of ") + $0.title } ?? "New session"
        return HStack(alignment: .center, spacing: 8) {
            Text(Self.name(chat.agent), color: theme.accent, font: session.fonts.statusEmphasis)
            pill(sessionTitle, theme: theme, enabled: !chat.started) {
                chat.pickingSession.toggle()
            }
            .tooltip(chat.started ? "This chat's session" : "Choose a session")
            .agentId("inline-chat-session")
            // In place: the question lands in that conversation and its own
            // agent answers, tools and all. Fork: a read-only copy proposes.
            if chat.choice != nil {
                pill(chat.inPlace ? "In this session" : "Fork", theme: theme, enabled: !chat.started) {
                    chat.inPlace.toggle()
                }
                .tooltip(chat.inPlace
                    ? "Asks the session itself: the answer lands in its chat, and it may edit files. Click to ask a read-only fork instead."
                    : "Asks a read-only copy, which proposes a change to review. Click to ask the session itself.")
                .agentId("inline-chat-mode")
            }
            Text(place, color: .muted, font: session.fonts.status, lineLimit: 1)
            Spacer()
            if chat.busy {
                Text("answering…", color: .muted, font: session.fonts.status)
            }
            HStack(padding: 6, alignment: .center, onClick: { session.closeInlineChat() }) {
                Mark(.cross, size: 9, color: theme.textSecondary, lineWidth: 1.6)
            }
            .hoverBackground(theme.hover)
            .cornerRadius(6)
            .cursor(.pointer)
            .tooltip("Close (Escape)")
            .agentId("inline-chat-close")
        }
        .frame(height: .pt(24))
    }

    /// One node with a fixed height and the text centred in it: padding
    /// around a `Text` sits the glyphs at the top of their line box, which
    /// is taller than the capitals.
    private func pill(_ title: String, theme: Theme, enabled: Bool, action: @escaping () -> Void) -> some View {
        HStack(height: .pt(22), padding: 0, alignment: .center, onClick: { if enabled { action() } }) {
            Text(title, color: enabled ? .primary : .secondary, font: session.fonts.status, lineLimit: 1)
                .flexShrink(1)
        }
        .padding(.horizontal, 8)
        .background(theme.inset)
        .hoverBackground(enabled ? theme.hover : theme.inset)
        .cornerRadius(6)
        .flexShrink(1)
        .cursor(enabled ? .pointer : nil)
    }

    // MARK: - Sessions

    private func sessionList(theme: Theme) -> some View {
        let chat = self.chat
        return ScrollView(.vertical) {
            VStack(spacing: 2) {
                ForEach([AgentSession.Agent.claude, .codex], id: \.rawValue) { agent in
                    sessionRow(title: "New \(Self.name(agent)) session", detail: "Starts with no history",
                               agent: agent, theme: theme,
                               isChosen: chat.choice == nil && chat.newAgent == agent, id: "inline-chat-new-\(agent.rawValue)") {
                        chat.choice = nil
                        chat.newAgent = agent
                        chat.pickingSession = false
                        chat.inputFocused = true
                    }
                }
                if !chat.sessionsLoaded {
                    Text("Reading sessions…", color: .muted, font: session.fonts.status).padding(6)
                }
                ForEach(Array(chat.sessions.prefix(60).enumerated()), id: \.offset) { index, agent in
                    sessionRow(title: agent.title, detail: Self.detail(agent, chat: chat), agent: agent.agent, theme: theme,
                               isChosen: chat.choice?.id == agent.id, id: "inline-chat-session-\(index)") {
                        chat.choice = agent
                        chat.pickingSession = false
                        chat.inputFocused = true
                    }
                }
            }
        }
        .flexGrow(1)
        .agentId("inline-chat-sessions")
    }

    private func sessionRow(title: String, detail: String, agent: AgentSession.Agent, theme: Theme,
                            isChosen: Bool, id: String, action: @escaping () -> Void) -> some View {
        HStack(alignment: .center, spacing: 8, onClick: action) {
            Text(Self.name(agent), color: agent == .claude ? theme.accent : appearance.languageText,
                 font: session.fonts.status, lineLimit: 1)
                .frame(width: .pt(48))
            Text(title, color: .primary, font: session.fonts.tab, lineLimit: 1)
                .flexShrink(1)
            Spacer()
            Text(detail, color: .muted, font: session.fonts.status, lineLimit: 1)
        }
        .padding(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
        .background(isChosen ? theme.selectionFill : .clear)
        .hoverBackground(isChosen ? theme.selectionFill : theme.hover)
        .cornerRadius(6)
        .cursor(.pointer)
        .agentId(id)
    }

    static func name(_ agent: AgentSession.Agent) -> String {
        switch agent {
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }

    /// When, where if not here, and how much history comes along.
    static func detail(_ agent: AgentSession, chat: InlineChat) -> String {
        var parts = [relative(agent.date)]
        if !BranchPicker.samePath(agent.directory, chat.directory) { parts.append(agent.directory.lastPathComponent) }
        let megabytes = Double(agent.bytes) / 1_048_576
        if megabytes >= 1 { parts.append(String(format: "%.0f MB", megabytes)) }
        return parts.joined(separator: " · ")
    }

    static func relative(_ date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        switch seconds {
        case ..<60: return "just now"
        case ..<3600: return "\(Int(seconds / 60)) min ago"
        case ..<86_400: return "\(Int(seconds / 3600)) h ago"
        default: return "\(Int(seconds / 86_400)) d ago"
        }
    }

    // MARK: - Conversation

    private func transcript(theme: Theme) -> some View {
        let chat = self.chat
        let font = session.fonts.tab
        return ScrollView(.vertical, position: chat.scroll) {
            VStack(spacing: 6) {
                ForEach(Array(chat.turns.enumerated()), id: \.offset) { _, turn in
                    Text("› " + turn.question, color: .secondary, font: font)
                    if !turn.activity.isEmpty {
                        Text(turn.activity.suffix(3).joined(separator: "  ·  "), color: .muted,
                             font: session.fonts.status, lineLimit: 1)
                    }
                    if !turn.reply.isEmpty {
                        MarkdownView(InlineChat.prose(turn.reply), font: font)
                    }
                    if let failure = turn.failure {
                        Text(failure, color: theme.accent, font: session.fonts.status)
                    }
                }
                if !chat.edited.isEmpty {
                    Text("Changed " + chat.edited.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", "),
                         color: .secondary, font: session.fonts.status)
                        .agentId("inline-chat-edited")
                }
            }
            .padding(.trailing, 8)
        }
        .flexGrow(1)
        .flexShrink(1)
        .agentId("inline-chat-transcript")
    }

    private func input(theme: Theme) -> some View {
        let session = self.session
        let chat = self.chat
        let placeholder = chat.started ? "Follow up…" : "Ask about these lines — Enter sends, Escape closes"
        return HStack(alignment: .center, spacing: 6) {
            TextField(
                text: Binding(get: { chat.draft }, set: { chat.draft = $0 }),
                placeholder: placeholder, font: session.fonts.tab,
                autoFocus: true,
                onSubmit: { session.sendInlineChat() }
            )
            .focused(Binding(get: { chat.inputFocused }, set: { chat.inputFocused = $0 }))
            .flexGrow(1)
            .agentId("inline-chat-input")
            if chat.proposal != nil, !chat.busy {
                Button("Review change") { session.reviewProposal() }
                    .agentId("inline-chat-review")
                Button("Accept") { session.acceptProposal() }
                    .agentId("inline-chat-accept")
            }
        }
    }
}
