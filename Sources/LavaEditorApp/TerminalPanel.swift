import Foundation
import LavaTerminal
import LavaUI
import Observation

/// The terminals under the editor: open or not, which one is in front, and
/// how much of the column they take.
///
/// The sessions live here rather than in the view, so hiding the panel keeps
/// every shell running — the way VS Code's panel does, and what makes Ctrl+`
/// a glance rather than a restart.
@Observable
final class TerminalPanel {
    var isOpen = false
    /// What the panel shows: the terminals, or the Problems list.
    enum Content { case terminal, problems }
    var content: Content = .terminal
    private(set) var tabs: [TerminalSession] = []
    var active = 0
    /// The editor's share of the column while the panel is open.
    var editorFraction: Float = 0.66
    /// The terminals' face, loaded the first time one opens.
    @ObservationIgnored var font: UIFont?

    var current: TerminalSession? {
        tabs.indices.contains(active) ? tabs[active] : nil
    }

    func append(_ session: TerminalSession) {
        tabs.append(session)
        active = tabs.count - 1
    }

    func remove(_ session: TerminalSession) {
        guard let index = tabs.firstIndex(where: { $0 === session }) else { return }
        tabs.remove(at: index)
        if active >= tabs.count { active = max(0, tabs.count - 1) }
        else if index < active { active -= 1 }
    }

    /// Keys a terminal here leaves to the editor, when it sees keys first.
    ///
    /// Short on purpose. In a shell nearly every Control chord means
    /// something — Ctrl+B is tmux's prefix, Ctrl+P and Ctrl+N walk history,
    /// Ctrl+W deletes a word — so the editor keeps only what has no meaning
    /// there: the panel's own toggles, switching tabs, quitting, and the
    /// Ctrl+Shift+letter commands (bar copy and paste, which the terminal
    /// takes for itself before asking this).
    static func editorKeeps(_ event: KeyEvent) -> Bool {
        guard event.control, !event.alt else { return false }
        switch event.key {
        case KeyCode.graveAccent, KeyCode.j:
            return true
        case KeyCode.pageUp, KeyCode.pageDown, KeyCode.tab, KeyCode.q:
            return true
        default:
            return event.shift && event.key >= KeyCode.a && event.key <= KeyCode.z
        }
    }
}

extension EditorSession {
    /// Ctrl+`: opens the panel on its terminal, starting one if there is
    /// none; from the terminal, hides the panel and goes back to the text;
    /// from the text with the panel open, goes to the terminal.
    func toggleTerminal() {
        if terminal.isOpen, terminal.content == .terminal,
           let current = terminal.current, FocusManager.isFocused(current.focusID) {
            hideTerminal()
            return
        }
        terminal.content = .terminal
        if terminal.isOpen, let current = terminal.current {
            focusTerminal(current)
            return
        }
        setPanelOpen(true)
        if let current = terminal.current {
            focusTerminal(current)
        } else {
            newTerminal()
        }
    }

    /// Opens or closes the panel. The editor is the same view either way
    /// (the split collapses rather than going away), so it keeps its place
    /// by itself; this only hands the keyboard back when asked.
    func setPanelOpen(_ open: Bool, focusEditor: Bool = false) {
        terminal.isOpen = open
        if focusEditor { controller.focus() }
    }

    /// A new shell in the project's folder — or the file in front's, or home.
    func newTerminal() {
        newTerminal(in: nil, typing: nil)
    }

    /// A new shell in `directory`, with `command` typed into it once it is
    /// up — a command rather than the shell's argument, so that quitting the
    /// program leaves you in a shell in that folder instead of closing the tab.
    @discardableResult
    func newTerminal(in directory: URL?, typing command: String?) -> TerminalSession {
        if terminal.font == nil, let editor = imageEditor {
            terminal.font = TerminalFont.load(into: editor, pixelSize: documentFont?.pixelSize ?? 15)
        }
        let session = TerminalSession(workingDirectory: directory ?? terminalDirectory())
        session.keysBeforeShortcuts = true
        session.declinesKey = TerminalPanel.editorKeeps
        terminal.append(session)
        terminal.content = .terminal
        setPanelOpen(true)
        let owner = LanguageSessionRef(self)
        // After the frame, as LavaTerm does: the grid sizes the session from
        // its first paint, and a shell started at 80×24 and resized at once
        // draws its first prompt twice.
        FrameTasks.after { [weak session] in
            session?.start { [weak session] in
                guard let session, let editor = owner.session else { return }
                editor.terminalExited(session)
            }
            if let session {
                if let command { session.write(command + "\n") }
                owner.session?.focusTerminal(session)
            }
        }
        return session
    }

    func selectTerminal(_ index: Int) {
        guard terminal.tabs.indices.contains(index) else { return }
        terminal.active = index
        terminal.content = .terminal
        focusTerminal(terminal.tabs[index])
    }

    /// Ends the shell (and whatever it was running) and drops its tab.
    func closeTerminal(_ session: TerminalSession) {
        session.stop()
        terminalExited(session)
    }

    func hideTerminal() {
        setPanelOpen(false, focusEditor: true)
    }

    /// The shell ended — `exit`, or closed here. The last one closes the panel.
    private func terminalExited(_ session: TerminalSession) {
        let wasFocused = FocusManager.isFocused(session.focusID)
        terminal.remove(session)
        if let next = terminal.current {
            if wasFocused { focusTerminal(next) }
        } else if terminal.content == .terminal {
            // The last shell closes the panel — unless it is showing the
            // Problems, which did not need a shell to be open.
            setPanelOpen(false, focusEditor: wasFocused)
        }
    }

    /// After the frame: a grid that is only now being shown has to be in the
    /// tree before it holds focus, or the window gives the focus straight back.
    func focusTerminal(_ session: TerminalSession) {
        TerminalGrid.focus(session)
        FrameTasks.after { TerminalGrid.focus(session) }
    }

    private func terminalDirectory() -> URL? {
        if let project { return project.tree.root }
        if let url = active.url { return url.deletingLastPathComponent() }
        return FileManager.default.homeDirectoryForCurrentUser
    }
}
