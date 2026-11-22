import Foundation
import LavaAgentCore
import LavaGitCore
import LavaUI
import Observation

struct AgentRow: Equatable, Identifiable {
    var id: String { session.agent.rawValue + ":" + session.id }
    let session: AgentSession
    let status: AgentStatus
    /// The current Codex thread, when the editor inherited its identity.
    var isCurrent = false
    /// The CLI's record of it, while a Claude Code session runs.
    var live: ClaudeLiveSession?
}

struct AgentWorktree: Equatable, Identifiable {
    var id: String { worktree.root.path }
    let worktree: GitWorktree
    let isOpen: Bool
    let changes: Int
    let sessions: [AgentRow]
}

/// Refreshes worktrees and their saved sessions while the Agents panel is visible.
@Observable
final class AgentsModel {
    private(set) var rows: [AgentWorktree] = []
    private(set) var loaded = false
    var notice: String?
    @ObservationIgnored private var pollingProject: ObjectIdentifier?
    @ObservationIgnored private let cache = CodexSessions.MetaCache()

    static let interval: Double = 3

    /// Starts looking, and keeps on while `shouldContinue` says so — the
    /// view is still the one in the sidebar.
    func poll(_ project: ProjectSession, shouldContinue: @escaping () -> Bool) {
        let identity = ObjectIdentifier(project)
        guard pollingProject != identity else { return }
        pollingProject = identity
        loaded = false
        tick(project.repository, root: project.tree.root, identity: identity, shouldContinue: shouldContinue)
    }

    private func tick(_ repository: GitRepository?, root: URL, identity: ObjectIdentifier,
                      shouldContinue: @escaping () -> Bool) {
        let cache = self.cache
        let ref = AgentsRef(self)
        let carry = ContinueCheck(shouldContinue)
        DispatchQueue.global(qos: .utility).async {
            let rows = Self.scan(repository, root: root, cache: cache)
            MainQueue.async {
                guard let model = ref.model, model.pollingProject == identity else { return }
                guard carry.check() else {
                    model.pollingProject = nil
                    return
                }
                if model.rows != rows { model.rows = rows }
                model.loaded = true
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.interval) {
                    MainQueue.async {
                        guard let model = ref.model, model.pollingProject == identity else { return }
                        guard carry.check() else {
                            model.pollingProject = nil
                            return
                        }
                        model.tick(repository, root: root, identity: identity, shouldContinue: carry.check)
                    }
                }
            }
        }
    }

    static func scan(_ repository: GitRepository?, root: URL, cache: CodexSessions.MetaCache) -> [AgentWorktree] {
        let worktrees = (try? repository?.worktrees()) ?? [
            GitWorktree(name: root.lastPathComponent, root: root, branch: nil, isMain: true, isLocked: false),
        ]
        let directories = worktrees.map(\.root)
        let roots = directories.map { $0.standardizedFileURL.resolvingSymlinksInPath().pathComponents }
        let live = ClaudeAgentsQuery.run()
        let now = Date()
        let openRoot = repository?.root ?? root
        let currentID = ProcessInfo.processInfo.environment["CODEX_THREAD_ID"]
            ?? ProcessInfo.processInfo.environment["CODEX_SESSION_ID"]
        let codex = CodexChatProcess.executable.flatMap { CodexAppServer(executable: $0).sessions(in: directories) }
        var sessions = ClaudeSessions.list(in: directories).map { agent in
            let running = live.first { $0.session == agent.id }
            let status = running?.status ?? (now.timeIntervalSince(agent.date) < 15 ? .working : .stopped)
            return AgentRow(session: agent, status: status, live: running)
        }
        if let codex {
            sessions += codex.map { AgentRow(session: $0.agent, status: $0.status, isCurrent: $0.isCurrent) }
        } else {
            sessions += CodexSessions.list(in: directories, cache: cache).map { agent in
                let isCurrent = agent.id == currentID
                let recent = now.timeIntervalSince(agent.date) < 600
                let working = isCurrent || (recent && agent.file.map { CodexSessions.turnOpen($0) } == true)
                return AgentRow(session: agent, status: working ? .working : .stopped, isCurrent: isCurrent)
            }
        }
        var byWorktree: [Int: [AgentRow]] = [:]
        for row in sessions {
            let path = row.session.directory.standardizedFileURL.resolvingSymlinksInPath().pathComponents
            // A nested worktree belongs to itself, including sessions started
            // from one of its subdirectories.
            let match = roots.indices.filter { path.starts(with: roots[$0]) }
                .max { roots[$0].count < roots[$1].count }
            if let match { byWorktree[match, default: []].append(row) }
        }
        var groups = worktrees.enumerated().map { index, tree in
            let changes = repository == nil ? 0 : ((try? GitRepository(root: tree.root).status())?.count ?? 0)
            let rows = (byWorktree[index] ?? []).sorted { left, right in
                if left.isCurrent != right.isCurrent { return left.isCurrent }
                if (left.status == .stopped) != (right.status == .stopped) { return left.status != .stopped }
                if left.session.date != right.session.date { return left.session.date > right.session.date }
                return left.id < right.id
            }
            return AgentWorktree(worktree: tree, isOpen: BranchPicker.samePath(tree.root, openRoot),
                                 changes: changes, sessions: rows)
        }
        if let index = groups.firstIndex(where: { $0.sessions.contains(where: \.isCurrent) }), index > 0 {
            let current = groups.remove(at: index)
            groups.insert(current, at: 0)
        }
        return groups
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
        agents.poll(project) {
            let session = owner.session
            return session.showsSidebar && session.sidebarView == .agents && session.project === project
        }
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

/// The Agents view groups saved conversations by their working tree.
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
                    newButton("+ Claude", agent: .claude, theme: theme)
                    newButton("+ Codex", agent: .codex, theme: theme)
                }
            }
            .padding(EdgeInsets(top: 10, leading: 14, bottom: 8, trailing: 10))
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
                        ForEach(model.rows) { tree in
                            self.worktree(tree, theme: theme)
                        }
                    }
                    .padding(.horizontal, 6)
                }
                .flexGrow(1)
            }
        }
        .agentId("agents-panel")
    }

    private func newButton(_ title: String, agent: AgentSession.Agent, theme: Theme) -> some View {
        Text(title, color: .secondary, font: session.fonts.status,
             hoverFill: theme.hover, cornerRadius: 6, onClick: { session.startNewAgent(agent) })
            .padding(EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8))
            .cursor(.pointer)
            .tooltip("Open \(agent == .claude ? "Claude Code" : "Codex") in a new tab")
            .agentId("agents-new-\(agent.rawValue)")
    }

    private func worktree(_ group: AgentWorktree, theme: Theme) -> some View {
        let tree = group.worktree
        var detail: [String] = []
        if let branch = tree.branch { detail.append(branch) }
        if group.changes > 0 { detail.append("\(group.changes) changed") }
        return VStack(spacing: 2) {
            HStack(alignment: .center, spacing: 8) {
                VStack(spacing: 2) {
                    HStack(alignment: .center, spacing: 6) {
                        Text(tree.name, color: .primary, font: session.fonts.tab, lineLimit: 1)
                            .flexShrink(1)
                        if group.isOpen {
                            Text("open", color: .muted, font: session.fonts.status)
                        }
                    }
                    if !detail.isEmpty {
                        Text(detail.joined(separator: " · "), color: .muted, font: session.fonts.status, lineLimit: 1)
                    }
                }
                .flexGrow(1)
                .flexShrink(1)
                if !group.isOpen {
                    Text("Open", color: .secondary, font: session.fonts.status, hoverFill: theme.hover, cornerRadius: 6,
                         onClick: { session.switchToWorktree(tree) })
                        .padding(EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8))
                        .cursor(.pointer)
                        .tooltip("Open this worktree")
                        .agentId("agents-open-\(tree.name)")
                }
            }
            .padding(EdgeInsets(top: 6, leading: 8, bottom: 4, trailing: 6))
            if group.sessions.isEmpty {
                Text("No agent session here", color: .muted, font: session.fonts.status, lineLimit: 1)
                    .padding(EdgeInsets(top: 0, leading: 8, bottom: 6, trailing: 6))
            }
            ForEach(group.sessions) { row in
                self.row(row, theme: theme)
            }
        }
        .agentId("agents-row-\(tree.name)")
    }

    private func row(_ row: AgentRow, theme: Theme) -> some View {
        let session = self.session
        let agent = row.session
        let place = row.live.map { $0.isBackground ? " in the background" : " in a terminal" } ?? ""
        let status = row.isCurrent ? "current session" : Self.statusWord(row.status) + place
        return HStack(alignment: .center, spacing: 8, onClick: { session.openAgent(row) }) {
            Self.dot(row.status, theme: theme, appearance: appearance)
            VStack(spacing: 2) {
                Text(agent.title, color: .primary, font: session.fonts.tab, lineLimit: 1)
                Text("\(InlineChatView.name(agent.agent)) · \(status)",
                     color: .secondary, font: session.fonts.status, lineLimit: 1)
            }
            .flexGrow(1)
            .flexShrink(1)
            Text("Chat", color: .secondary, font: session.fonts.status, hoverFill: theme.hover, cornerRadius: 6,
                 onClick: { session.openSessionChat(agent) })
                .padding(EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8))
                .cursor(.pointer)
                .tooltip("Open the session transcript")
                .agentId("agents-chat-\(agent.id)")
        }
        .padding(EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 6))
        .background(row.isCurrent ? theme.selectionFill : .clear)
        .hoverBackground(row.isCurrent ? theme.selectionFill : theme.hover)
        .cornerRadius(8)
        .cursor(.pointer)
        .agentId("agents-session-\(agent.id)")
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
