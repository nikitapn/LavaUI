import Foundation
import LavaTerminal
import LavaUI
import Observation

/// Alt+X: every command in the menu bar, by name, narrowed as it is typed —
/// Emacs's M-x, in a minibuffer along the bottom of the window.
///
/// The commands are the menu's own items, read from the bar built afresh
/// when the palette opens, so what is offered and whether it can run are the
/// menu's answers at that moment; there is no second list to keep in step.
/// An extension's commands are in the Extensions menu and come along.
@Observable
final class CommandPalette {
    var query = "" {
        didSet { if query != oldValue { selection = 0 } }
    }
    /// Index into `matches`.
    var selection = 0
    var fieldFocused = true
    /// Every command that can run now.
    let commands: [MenuCommand]
    /// Ids run through the palette, most recent first.
    let recent: [MenuID]
    @ObservationIgnored let actions: MenuActionTable
    /// Where the keyboard goes back to when the palette closes.
    @ObservationIgnored let returnFocus: ReturnFocus

    enum ReturnFocus {
        case terminal(TerminalSession)
        case node(NodeID?)
    }

    init(commands: [MenuCommand], actions: MenuActionTable, recent: [MenuID], returnFocus: ReturnFocus) {
        self.commands = commands
        self.actions = actions
        self.recent = recent
        self.returnFocus = returnFocus
    }

    var matches: [MenuCommand] {
        CommandFilter.rank(commands, query: query, recent: recent)
    }

    func move(by delta: Int, in count: Int) {
        guard count > 0 else { return }
        selection = max(0, min(count - 1, selection + delta))
    }
}

extension EditorSession {
    static let commandPaletteID = "view.commands"
    private static let historyKey = "commandHistory"

    func toggleCommandPalette() {
        if commandPalette != nil {
            closeCommandPalette()
        } else {
            openCommandPalette()
        }
    }

    func openCommandPalette() {
        let (model, actions) = commandMenu().resolve()
        let commands = model.commands.filter {
            $0.isEnabled && $0.id.raw != Self.commandPaletteID && !Self.isListEntry($0.id.raw)
        }
        let recent = (AppSettings.value(forKey: Self.historyKey, as: [String].self) ?? []).map(MenuID.init)
        let returnFocus: CommandPalette.ReturnFocus
        if let current = terminal.current, FocusManager.isFocused(current.focusID) {
            returnFocus = .terminal(current)
        } else {
            returnFocus = .node(FocusManager.focusedID)
        }
        commandPalette = CommandPalette(commands: commands, actions: actions, recent: recent,
                                        returnFocus: returnFocus)
    }

    /// Closes it and gives the keyboard back to whatever had it: the editor,
    /// a terminal, a field or a list in the sidebar.
    func closeCommandPalette() {
        guard let palette = commandPalette else { return }
        commandPalette = nil
        switch palette.returnFocus {
        case .terminal(let session):
            focusTerminal(session)
        case .node(let id):
            if let id, FocusManager.refocus(id) { return }
            controller.focus()
        }
    }

    /// Runs `command` from where the keyboard was before the palette opened —
    /// Copy copies from the editor, not from the palette's field. After the
    /// frame, so the palette is gone first: some commands open a dialog and
    /// wait for it.
    func runCommand(_ command: MenuCommand) {
        guard let palette = commandPalette else { return }
        closeCommandPalette()
        remember(command.id)
        let actions = palette.actions
        FrameTasks.after { actions.activate(command.id) }
    }

    private func remember(_ id: MenuID) {
        AppSettings.update([String].self, forKey: Self.historyKey) { stored in
            Array(([id.raw] + (stored ?? []).filter { $0 != id.raw }).prefix(50))
        }
    }

    /// Rows of a list in the menu — a recent file or folder — rather than
    /// commands: one per path, and a palette full of paths buries the
    /// commands. Their "Clear" items stay.
    private static func isListEntry(_ id: String) -> Bool {
        for prefix in ["file.recent.", "file.recent-folders.", "file.recent-workspaces."] where id.hasPrefix(prefix) {
            return id.dropFirst(prefix.count).allSatisfy(\.isNumber)
        }
        return false
    }
}
