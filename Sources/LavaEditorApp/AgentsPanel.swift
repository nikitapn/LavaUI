import Foundation
import LavaAgentCore
import LavaGitCore
import LavaUI
import Observation

/// One working tree and the agent session last at work in it.
struct AgentRow: Equatable, Identifiable {
    var id: String { worktree.root.path }
    let worktree: GitWorktree
    /// The tree the editor has open.
    let isOpen: Bool
    /// Files git reports changed there.
    let changes: Int
    let session: AgentSession?
    let status: AgentStatus
    /// The CLI's record of it, while a Claude Code session runs.
    let live: ClaudeLiveSession?
}

/// The Agents view's rows, looked at again every few seconds while it is
/// shown. Everything it knows comes from files the CLIs write anyway and
/// from `claude agents --json`; nothing here talks to an agent.
@Observable
final class AgentsModel {
    private(set) var rows: [AgentRow] = []
    private(set) var loaded = false
    /// The New Agent field is open.
    var composing = false
    var task = ""
    var taskFocused = false
    /// A `claude --bg -w` is being started.
    var starting = false
    var notice: String?
    @ObservationIgnored private var polling = false
    @ObservationIgnored private let cache = CodexSessions.MetaCache()

    static let interval: Double = 3

    /// Starts looking, and keeps on while `shouldContinue` says so — the
    /// view is still the one in the sidebar.
    func poll(_ repository: GitRepository?, root: URL, shouldContinue: @escaping () -> Bool) {
        guard !polling else { return }
        polling = true
        tick(repository, root: root, shouldContinue: shouldContinue)
    }

    private func tick(_ repository: GitRepository?, root: URL, shouldContinue: @escaping () -> Bool) {
        let cache = self.cache
        let ref = AgentsRef(self)
        let carry = ContinueCheck(shouldContinue)
        DispatchQueue.global(qos: .utility).async {
            let rows = Self.scan(repository, root: root, cache: cache)
            MainQueue.async {
                guard let model = ref.model else { return }
                if model.rows != rows { model.rows = rows }
                model.loaded = true
                guard carry.check() else {
                    model.polling = false
                    return
                }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.interval) {
                    MainQueue.async {
                        guard let model = ref.model else { return }
                        guard carry.check() else {
                            model.polling = false
                            return
                        }
                        model.tick(repository, root: root, shouldContinue: carry.check)
                    }
                }
            }
        }
    }

    /// Every worktree of the repository (or just the folder, outside one),
    /// with its newest Claude Code or Codex session and what that is doing.
    static func scan(_ repository: GitRepository?, root: URL, cache: CodexSessions.MetaCache) -> [AgentRow] {
        let trees = (try? repository?.worktrees()) ?? nil
        let worktrees = trees ?? [GitWorktree(name: root.lastPathComponent, root: root, branch: nil, isMain: true, isLocked: false)]
        let live = ClaudeAgentsQuery.run()
        let now = Date()
        return worktrees.map { tree in
            let changes = repository == nil ? 0
                : ((try? GitRepository(root: tree.root).status())?.count ?? 0)
            let claude = ClaudeSessions.latest(in: tree.root)
            let codex = CodexSessions.list(in: [tree.root], cache: cache).first
            // A session running here wins; otherwise whichever was written last.
            let running = live.first { BranchPicker.samePath($0.directory, tree.root) }
            var session = [claude, codex].compactMap { $0 }.max { $0.date < $1.date }
            if let running, claude?.id == running.session { session = claude }
            let liveHere = session.flatMap { s in live.first { $0.session == s.id } }
            let status: AgentStatus
            switch session?.agent {
            case .claude?:
                if let liveHere { status = liveHere.status }
                // A `claude -p` turn is not in the CLI's list, but it writes.
                else if let date = session?.date, now.timeIntervalSince(date) < 15 { status = .working }
                else { status = .stopped }
            case .codex?:
                let recent = session.map { now.timeIntervalSince($0.date) < 600 } ?? false
                status = recent && session?.file.map { CodexSessions.turnOpen($0) } == true ? .working : .stopped
            case nil:
                status = .stopped
            }
            return AgentRow(worktree: tree, isOpen: BranchPicker.samePath(tree.root, root), changes: changes,
                            session: session, status: status, live: liveHere)
        }
    }
}

/// `claude agents --json`: which Claude Code sessions are running now.
enum ClaudeAgentsQuery {
    static func run(timeout: TimeInterval = 5) -> [ClaudeLiveSession] {
        guard let executable = ClaudeChatProcess.executable else { return [] }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["agents", "--json"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        for key in ["CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SSE_PORT"] { environment[key] = nil }
        process.environment = environment
        guard (try? process.run()) != nil else { return [] }
        let deadline = DispatchTime.now() + timeout
        let done = DispatchSemaphore(value: 0)
        let reader = OutputBox()
        DispatchQueue.global().async {
            reader.data = output.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        if done.wait(timeout: deadline) == .timedOut {
            process.terminate()
            return []
        }
        process.waitUntilExit()
        return ClaudeLiveSession.parse(reader.data)
    }

    private final class OutputBox: @unchecked Sendable {
        var data = Data()
    }
}

private struct AgentsRef: @unchecked Sendable {
    weak var model: AgentsModel?
    init(_ model: AgentsModel) { self.model = model }
}

private struct ContinueCheck: @unchecked Sendable {
    let check: () -> Bool
    init(_ check: @escaping () -> Bool) { self.check = check }
}

extension EditorSession {
    /// Opens the Agents view and starts watching.
    func startAgentsPolling() {
        guard let project else { return }
        let owner = SessionRef(session: self)
        agents.poll(project.repository, root: project.tree.root) {
            let session = owner.session
            return session.showsSidebar && session.sidebarView == .agents && session.project === project
        }
    }

    /// New Agent: Claude Code on a task, in its background service, in a git
    /// worktree it makes for itself (`claude --bg -w`). It shows up as a row
    /// of its own once the worktree exists — the view is polling anyway.
    /// Auto mode, as a session left to itself wants; a call auto mode cannot
    /// decide waits for whoever attaches.
    func startAgent() {
        let model = agents
        let task = model.task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty, !model.starting, let repository = project?.repository else { return }
        guard let executable = ClaudeChatProcess.executable else {
            model.notice = ClaudeChatProcess.Failure.notInstalled.description
            return
        }
        let name = Self.worktreeName(for: task)
        var arguments = ["--bg", "-w", name, "--permission-mode", "auto"]
        if let model = ProcessInfo.processInfo.environment["LAVAEDITOR_CLAUDE_MODEL"], !model.isEmpty {
            arguments += ["--model", model]
        }
        arguments.append(task)
        let command = arguments
        model.starting = true
        model.notice = nil
        let ref = AgentsRef(model)
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = executable
            process.arguments = command
            process.currentDirectoryURL = repository.root
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            process.standardInput = FileHandle.nullDevice
            var read = ""
            var code: Int32 = -1
            if (try? process.run()) != nil {
                read = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                process.waitUntilExit()
                code = process.terminationStatus
            }
            let text = read, status = code
            // "backgrounded · 95abe5ab", among other lines.
            let id = text.split(whereSeparator: \.isNewline)
                .first { $0.contains("backgrounded") }
                .flatMap { $0.split(separator: " ").last.map(String.init) }
            let last = text.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
            MainQueue.async {
                guard let model = ref.model else { return }
                model.starting = false
                if status == 0 {
                    model.task = ""
                    model.composing = false
                    model.notice = "Started \(id ?? "an agent") in .claude/worktrees/\(name). Its row appears in a moment."
                } else {
                    model.notice = "claude --bg failed (\(status)): \(last)"
                }
            }
        }
    }

    /// A worktree name from the task's first words: `fix-the-login-bug-3f2a`.
    static func worktreeName(for task: String) -> String {
        let words = task.lowercased().split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }.prefix(4)
        let stem = words.joined(separator: "-")
        let suffix = String(UInt32.random(in: 0...0xffff), radix: 16)
        return (stem.isEmpty ? "agent" : String(stem.prefix(40))) + "-" + suffix
    }

    /// The session's chat in a tab — the one already open for it, if any.
    func openSessionChat(_ agent: AgentSession) {
        let optionID = "chat:" + agent.id
        if let existing = documents.firstIndex(where: { $0.preview?.optionID == optionID }) {
            activate(existing)
            return
        }
        stashPosition()
        let preview = DocumentPreview(chat: SessionTranscript(session: agent, editor: self))
        documents.append(EditorDocument(id: takeID(), url: nil, text: "", preview: preview))
        activate(documents.count - 1)
    }
}

/// The Agents view: each worktree, the agent last at work there, and what
/// it is doing. A row opens that session's chat.
struct AgentsPanel: View {
    let session: EditorSession
    let project: ProjectSession
    let appearance: EditorAppearance

    var body: some View {
        let theme = appearance.theme
        let model = session.agents
        return VStack(flexGrow: 1, spacing: 0) {
            HStack(padding: 0, alignment: .center, spacing: 8) {
                Text("Agents", color: .primary, font: session.fonts.tabSelected, lineLimit: 1)
                Spacer()
                if project.isInRepository {
                    Text(model.composing ? "Cancel" : "New Agent", color: .secondary, font: session.fonts.status,
                         hoverFill: theme.hover, cornerRadius: 6, onClick: {
                            model.composing.toggle()
                            model.taskFocused = model.composing
                            model.notice = nil
                         })
                        .padding(EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8))
                        .cursor(.pointer)
                        .tooltip("Start Claude Code on a task, in the background, in a worktree of its own")
                        .agentId("agents-new")
                }
            }
            .padding(EdgeInsets(top: 10, leading: 14, bottom: 8, trailing: 10))
            if model.composing {
                VStack(spacing: 6) {
                    TextField(
                        text: Binding(get: { model.task }, set: { model.task = $0 }),
                        placeholder: "What should it do? Enter starts it",
                        font: session.fonts.tab,
                        onSubmit: { session.startAgent() }
                    )
                    .focused(Binding(get: { model.taskFocused }, set: { model.taskFocused = $0 }))
                    .agentId("agents-task")
                    Text(model.starting ? "Starting…" : "Runs `claude --bg -w` in auto mode: a new branch and worktree, its own row here.",
                         color: .muted, font: session.fonts.status)
                }
                .padding(EdgeInsets(top: 0, leading: 14, bottom: 8, trailing: 12))
            }
            if let notice = model.notice {
                Text(notice, color: .muted, font: session.fonts.status)
                    .padding(EdgeInsets(top: 0, leading: 14, bottom: 8, trailing: 12))
                    .agentId("agents-notice")
            }
            if !model.loaded {
                Text("Looking at worktrees…", color: .muted, font: session.fonts.status).padding(14)
            } else {
                ScrollView(.vertical) {
                    VStack(spacing: 2) {
                        ForEach(model.rows) { row in
                            self.row(row, theme: theme)
                        }
                    }
                    .padding(.horizontal, 6)
                }
                .flexGrow(1)
            }
        }
        .agentId("agents-panel")
    }

    private func row(_ row: AgentRow, theme: Theme) -> some View {
        let session = self.session
        let agent = row.session
        var detail: [String] = []
        if let branch = row.worktree.branch { detail.append(branch) }
        if row.changes > 0 { detail.append("\(row.changes) changed") }
        return HStack(alignment: .center, spacing: 8, onClick: {
            if let agent { session.openSessionChat(agent) }
        }) {
            Self.dot(row.status, theme: theme, appearance: appearance)
            VStack(spacing: 2) {
                HStack(alignment: .center, spacing: 6) {
                    Text(row.worktree.name, color: .primary, font: session.fonts.tab, lineLimit: 1)
                        .flexShrink(1)
                    if row.isOpen {
                        Text("open", color: .muted, font: session.fonts.status)
                    }
                }
                if !detail.isEmpty {
                    Text(detail.joined(separator: " · "), color: .muted, font: session.fonts.status, lineLimit: 1)
                }
                if let agent {
                    let place = row.live.map { $0.kind == "background" ? " in the background" : " in a terminal" } ?? ""
                    Text("\(InlineChatView.name(agent.agent)) · \(Self.statusWord(row.status))\(place) · \(agent.title)",
                         color: .secondary, font: session.fonts.status, lineLimit: 1)
                } else {
                    Text("No agent session here", color: .muted, font: session.fonts.status, lineLimit: 1)
                }
            }
            .flexGrow(1)
            .flexShrink(1)
            if !row.isOpen {
                Text("Open", color: .secondary, font: session.fonts.status, hoverFill: theme.hover, cornerRadius: 6,
                     onClick: { session.switchToWorktree(row.worktree) })
                    .padding(EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8))
                    .cursor(.pointer)
                    .tooltip("Open this worktree")
                    .agentId("agents-open-\(row.worktree.name)")
            }
        }
        .padding(EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 6))
        .hoverBackground(theme.hover)
        .cornerRadius(8)
        .cursor(agent == nil ? nil : .pointer)
        .agentId("agents-row-\(row.worktree.name)")
    }

    static func statusWord(_ status: AgentStatus) -> String {
        switch status {
        case .working: "working"
        case .waiting: "waiting for you"
        case .stopped: "stopped"
        }
    }

    /// Green while it works, amber while it waits on you, grey otherwise.
    static func dot(_ status: AgentStatus, theme: Theme, appearance: EditorAppearance) -> some View {
        let color: Color
        switch status {
        case .working: color = Color(rgb24: 0x4c_b0_5a)
        case .waiting: color = Color(rgb24: 0xe0_a0_30)
        case .stopped: color = theme.textSecondary.opacity(0.45)
        }
        return Canvas(label: "agent-status", width: .pt(10), height: .pt(10)) { list, frame in
            list.roundedRect(x: frame.x + 1, y: frame.y + 1, w: frame.w - 2, h: frame.h - 2, color: color, radius: (frame.w - 2) / 2)
        }
    }
}
