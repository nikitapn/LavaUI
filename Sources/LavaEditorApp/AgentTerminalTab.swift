import Foundation
import LavaAgentCore
import LavaTerminal
import LavaUI

/// An agent's own terminal UI in an editor tab: `claude` or `codex`,
/// running interactively in a shell of its own.
///
/// The CLI's interactive UI is the one input both agents fully support —
/// permission prompts, pasting a screenshot, selecting and copying, every
/// slash command — so rather than imitate it, the editor gives it a tab.
/// The tab is a plain terminal: the command is typed into a shell, and
/// leaving the agent leaves you in that shell in its folder.
final class AgentTerminal {
    /// Which tab this is, so opening the same session again brings it
    /// forward: `session:<id>`, or `new:<worktree name>`.
    let key: String
    let session: TerminalSession

    init(key: String, session: TerminalSession) {
        self.key = key
        self.session = session
    }
}

extension EditorSession {
    /// Agent tabs open in the document area.
    var agentTerminals: [AgentTerminal] {
        documents.compactMap { document in
            if case .terminal(let terminal)? = document.preview?.content { return terminal }
            return nil
        }
    }

    /// Opens (or brings forward) a tab running `command` in a fresh shell
    /// in `directory`.
    func openAgentTerminal(key: String, title: String, name: String, directory: URL, command: String) {
        if let index = documents.firstIndex(where: { document in
            if case .terminal(let terminal)? = document.preview?.content { return terminal.key == key && !terminal.session.exited }
            return false
        }) {
            activate(index)
            focusActiveAgentTerminal()
            return
        }
        if terminal.font == nil, let editor = imageEditor {
            terminal.font = TerminalFont.load(into: editor, pixelSize: documentFont?.pixelSize ?? 15)
        }
        let shell = TerminalSession(workingDirectory: directory)
        shell.keysBeforeShortcuts = true
        shell.declinesKey = TerminalPanel.editorKeeps
        let tab = AgentTerminal(key: key, session: shell)
        stashPosition()
        documents.append(EditorDocument(id: takeID(), url: nil, text: "",
                                        preview: DocumentPreview(terminal: tab, title: title, name: name)))
        activate(documents.count - 1)
        let owner = LanguageSessionRef(self)
        // After the frame, as the terminal panel does: the grid sizes the
        // shell from its first paint.
        FrameTasks.after { [weak shell] in
            guard let shell else { return }
            shell.start { [weak shell] in
                // The shell ended (`exit`, or the tab killed it): the tab goes.
                guard let shell, let editor = owner.session,
                      let index = editor.documents.firstIndex(where: { document in
                          if case .terminal(let t)? = document.preview?.content { return t.session === shell }
                          return false
                      }) else { return }
                editor.close(index)
            }
            TerminalGrid.focus(shell)
            // Once the shell has drawn its prompt: typed before that, the
            // line is echoed twice — by the terminal, then by the prompt.
            let box = ShellBox(shell)
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) {
                MainQueue.async { box.shell?.write(command + "\n") }
            }
        }
    }

    /// The tab in front, if it is an agent's terminal, takes the keyboard —
    /// after the frame, once its grid is in the tree.
    func focusActiveAgentTerminal() {
        guard documents.indices.contains(activeIndex),
              case .terminal(let terminal)? = documents[activeIndex].preview?.content else { return }
        TerminalGrid.focus(terminal.session)
        FrameTasks.after { TerminalGrid.focus(terminal.session) }
    }

    /// `'…'` for a shell, whatever the text holds.
    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// A row of the Agents view, opened in its agent's own terminal UI:
    /// attached while it runs in the background, resumed while nothing runs
    /// it, brought forward while it runs in one of the editor's terminals.
    /// One running in some other terminal cannot be joined — two UIs on one
    /// session is two writers — so its transcript opens instead.
    func openAgent(_ row: AgentRow) {
        let agent = row.session
        let name = agent.title.count > 40 ? String(agent.title.prefix(39)) + "…" : agent.title
        switch agent.agent {
        case .claude:
            if let live = row.live {
                if live.isBackground {
                    openAgentTerminal(key: "session:" + agent.id, title: "Claude", name: name,
                                      directory: agent.directory, command: "claude attach \(live.attachName)")
                } else if let shell = terminal(running: live.pid) {
                    bringForward(shell)
                } else {
                    openSessionChat(agent)
                    notice = "This session runs in a terminal outside LavaEditor (pid \(live.pid)); its transcript is open instead."
                }
            } else {
                openAgentTerminal(key: "session:" + agent.id, title: "Claude", name: name,
                                  directory: agent.directory, command: "claude --resume \(agent.id)")
            }
        case .codex:
            if row.isCurrent || row.status != .stopped {
                openSessionChat(agent)
            } else {
                openAgentTerminal(key: "session:" + agent.id, title: "Codex", name: name,
                                  directory: agent.directory, command: "codex resume \(Self.shellQuoted(agent.id))")
            }
        }
    }

    /// Shows the terminal `shell` lives in: its document tab, or its tab in
    /// the panel.
    func bringForward(_ shell: TerminalSession) {
        if let index = documents.firstIndex(where: { document in
            if case .terminal(let t)? = document.preview?.content { return t.session === shell }
            return false
        }) {
            activate(index)
            focusActiveAgentTerminal()
        } else if let index = terminal.tabs.firstIndex(where: { $0 === shell }) {
            if !terminal.isOpen { toggleTerminal() }
            selectTerminal(index)
        }
    }
}

/// The agent's terminal, filling its tab.
struct AgentTerminalView: View {
    let session: EditorSession
    let terminal: AgentTerminal
    let appearance: EditorAppearance

    var body: some View {
        VStack(flexGrow: 1, spacing: 0) {
            if let font = session.terminal.font ?? FontStore.default {
                TerminalGrid(session: terminal.session, mono: font, claimsKeyboard: false,
                             background: appearance.theme.inset)
                    .flexGrow(1)
            }
        }
        .agentId("agent-terminal")
    }
}

private struct ShellBox: @unchecked Sendable {
    weak var shell: TerminalSession?
    init(_ shell: TerminalSession) { self.shell = shell }
}
