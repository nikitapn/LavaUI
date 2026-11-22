import Foundation
import LavaAgentCore
import LavaGitCore
import LavaUI
import Observation

@Observable
final class AgentLaunch {
    enum Destination: String, CaseIterable, Identifiable {
        case main, current, newWorktree
        var id: String { rawValue }

        var title: String {
            switch self {
            case .main: "Main branch"
            case .current: "Current worktree"
            case .newWorktree: "New worktree"
            }
        }
    }

    let id = UUID()
    let agent: AgentSession.Agent
    let repository: GitRepository
    var destination = Destination.current
    var branch = ""
    var branchFocused = false
    var worktrees: [GitWorktree]?
    var hasMainBranch = false
    var creating = false
    var error: String?

    init(agent: AgentSession.Agent, repository: GitRepository) {
        self.agent = agent
        self.repository = repository
    }

    var main: GitWorktree? { worktrees?.first { $0.branch == "main" } }
    var current: GitWorktree? { worktrees?.first { BranchPicker.samePath($0.root, repository.root) } }
    var branchPrefix: String { agent.rawValue + "/" }
    var branchName: String? {
        let name = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : branchPrefix + name
    }
    var mainDirectory: URL? { main?.root ?? (hasMainBranch ? directory(for: "main") : nil) }
    var newDirectory: URL? { branchName.map { directory(for: $0) } }

    private func directory(for branch: String) -> URL {
        let primary = worktrees?.first(where: \.isMain)?.root ?? repository.root
        let suffix = branch.replacingOccurrences(of: "/", with: "-")
        return primary.deletingLastPathComponent()
            .appendingPathComponent(primary.lastPathComponent + "-" + suffix, isDirectory: true)
    }

    var canStart: Bool {
        guard !creating, worktrees != nil else { return false }
        switch destination {
        case .main: return mainDirectory != nil
        case .current: return true
        case .newWorktree: return newDirectory != nil
        }
    }

    func select(_ destination: Destination) {
        self.destination = destination
        branchFocused = destination == .newWorktree
        error = nil
    }
}

extension EditorSession {
    func startNewAgent(_ agent: AgentSession.Agent) {
        guard let repository = project?.repository, agentLaunch == nil else { return }
        let launch = AgentLaunch(agent: agent, repository: repository)
        agentLaunch = launch
        let id = launch.id
        let owner = LanguageSessionRef(self)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { (try repository.worktrees(), try repository.hasLocalBranch("main")) }
            MainQueue.async {
                guard let launch = owner.session?.agentLaunch, launch.id == id else { return }
                switch result {
                case .success(let (trees, hasMain)):
                    launch.hasMainBranch = hasMain
                    launch.worktrees = trees
                case .failure(let error): launch.error = String(describing: error)
                }
            }
        }
    }

    func cancelAgentLaunch() {
        guard agentLaunch?.creating == false else { return }
        agentLaunch = nil
        controller.focus()
    }

    func confirmAgentLaunch() {
        guard let launch = agentLaunch, launch.canStart else { return }
        switch launch.destination {
        case .main:
            guard let directory = launch.mainDirectory else { return }
            if launch.main == nil {
                createAgentWorktree(launch, at: directory, branch: "main", createBranch: false)
            } else {
                let repository = GitRepository(root: directory, executable: launch.repository.executable)
                guard (try? repository.branch()) == "main" else {
                    launch.error = "The main branch is no longer checked out there."
                    return
                }
                finishAgentLaunch(launch, directory: directory)
            }
        case .current:
            finishAgentLaunch(launch, directory: launch.repository.root)
        case .newWorktree:
            guard let branch = launch.branchName, let directory = launch.newDirectory else { return }
            createAgentWorktree(launch, at: directory, branch: branch, createBranch: true)
        }
    }

    private func createAgentWorktree(_ launch: AgentLaunch, at directory: URL, branch: String, createBranch: Bool) {
        launch.creating = true
        launch.branchFocused = false
        launch.error = nil
        let id = launch.id
        let repository = launch.repository
        let owner = LanguageSessionRef(self)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try repository.addWorktree(at: directory, branch: branch, createBranch: createBranch) }
            MainQueue.async {
                guard let session = owner.session, let launch = session.agentLaunch, launch.id == id else { return }
                launch.creating = false
                switch result {
                case .success: session.finishAgentLaunch(launch, directory: directory)
                case .failure(let error):
                    launch.error = String(describing: error)
                    launch.branchFocused = createBranch
                }
            }
        }
    }

    private func finishAgentLaunch(_ launch: AgentLaunch, directory: URL) {
        agentLaunch = nil
        let title = InlineChatView.name(launch.agent)
        var command = launch.agent.rawValue
        if launch.agent == .claude {
            command += " --permission-mode auto"
            if let chosen = ProcessInfo.processInfo.environment["LAVAEDITOR_CLAUDE_MODEL"], !chosen.isEmpty {
                command += " --model " + Self.shellQuoted(chosen)
            }
        }
        openAgentTerminal(key: "new:" + launch.id.uuidString, title: title, name: "new",
                          directory: directory, command: command)
        agents.notice = nil
    }
}

struct AgentLaunchView: View {
    let session: EditorSession
    let launch: AgentLaunch
    let appearance: EditorAppearance

    static let placement = OverlayPlacement { context in
        let width = min(470, max(1, context.viewport.width - 32))
        let height = min(context.idealSize.height, max(1, context.viewport.height - 32))
        return OverlayFrame(x: (context.viewport.width - width) / 2, y: (context.viewport.height - height) / 2,
                            width: width, height: height)
    }

    static func style(session: EditorSession, theme: Theme) -> OverlayStyle {
        var style = OverlayStyle(background: theme.panel, border: theme.border, cornerRadius: 16,
                                 padding: 0, scrim: Color(r: 0, g: 0, b: 0, a: 0.2), modal: true)
        style.onKey = { event in
            switch event.key {
            case KeyCode.escape: session.cancelAgentLaunch()
            case KeyCode.enter: session.confirmAgentLaunch()
            default: return false
            }
            return true
        }
        return style
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(spacing: 12) {
                Text("Start \(InlineChatView.name(launch.agent))", color: .primary, font: session.fonts.tabSelected)
                if launch.worktrees != nil {
                    VStack(spacing: 4) {
                        ForEach(AgentLaunch.Destination.allCases) { destination in
                            option(destination)
                        }
                    }
                    if launch.destination == .newWorktree {
                        HStack(alignment: .center, spacing: 6) {
                            Text(launch.branchPrefix, color: .secondary, font: session.fonts.tab)
                            TextField(
                                text: Binding(get: { launch.branch }, set: { value in
                                    guard !launch.creating else { return }
                                    launch.branch = value
                                    launch.error = nil
                                }),
                                placeholder: "New branch name", font: session.fonts.tab,
                                onSubmit: { session.confirmAgentLaunch() }
                            )
                            .focused(Binding(get: { launch.branchFocused }, set: { launch.branchFocused = $0 }))
                            .flexGrow(1)
                            .agentId("agent-launch-branch")
                        }
                        if let path = launch.newDirectory?.path {
                            Text(path, color: .muted, font: session.fonts.status, lineLimit: 1)
                                .tooltip(path)
                        }
                    }
                } else if launch.error == nil {
                    Text("Reading worktrees…", color: .muted, font: session.fonts.status)
                }
                if let error = launch.error {
                    Text(error, color: appearance.modified, font: session.fonts.status)
                        .agentId("agent-launch-error")
                }
                HStack(alignment: .center, spacing: 8) {
                    Spacer()
                    Button("Cancel", font: session.fonts.tab, isEnabled: !launch.creating) {
                        session.cancelAgentLaunch()
                    }
                    .agentId("agent-launch-cancel")
                    Button(launch.creating ? "Creating worktree…" : "Start",
                           font: session.fonts.tab, isEnabled: launch.canStart) {
                        session.confirmAgentLaunch()
                    }
                    .agentId("agent-launch-start")
                }
            }
            .padding(16)
        }
        .flexGrow(0)
        .agentId("agent-launch")
    }

    private func option(_ destination: AgentLaunch.Destination) -> some View {
        let theme = appearance.theme
        let selected = launch.destination == destination
        let enabled = !launch.creating && (destination != .main || launch.mainDirectory != nil)
        let detail: String
        switch destination {
        case .main:
            if let main = launch.main { detail = main.root.path }
            else if let path = launch.mainDirectory?.path { detail = "Check out main in \(path)" }
            else { detail = "This repository has no local main branch." }
        case .current: detail = (launch.current?.branch ?? "Detached HEAD") + " · " + launch.repository.root.path
        case .newWorktree: detail = "Create a branch from the current commit"
        }
        return VStack(spacing: 2, onClick: enabled ? { launch.select(destination) } : nil) {
            Text(destination.title, color: enabled ? .primary : .muted, font: session.fonts.tab)
            Text(detail, color: .muted, font: session.fonts.status, lineLimit: 1)
                .tooltip(detail)
        }
        .padding(EdgeInsets(top: 7, leading: 10, bottom: 7, trailing: 10))
        .background(selected ? theme.selectionFill : .clear)
        .hoverBackground(enabled ? (selected ? theme.selectionFill : theme.hover) : .clear)
        .cornerRadius(8)
        .cursor(enabled ? .pointer : nil)
        .agentId("agent-launch-\(destination.rawValue)")
    }
}
