import Foundation
import LavaHost
import LavaUI

/// A plain text editor: tabs, find and replace, syntax colouring, soft wrap.
///
/// The point of it is `EditorView` — everything about the buffer (undo,
/// selection, grapheme-correct motion, wrapping) is the framework's, and this
/// target is the shell around it: which files are open, where they came from,
/// and where they are written back.
@main
struct LavaEditorApp {
    static func main() {
        if let status = ExtensionHost.entryPoint(Array(CommandLine.arguments.dropFirst())) {
            exit(status)
        }
        SelectionExtension.start()
        forgetLaunchingAgentSession()
        // Before the session, which reads the wrap and line-number settings
        // out of it in its initialiser.
        AppSettings.configure(appName: "LavaEditor")
        FontCatalog.prewarm()

        // The windowed renderer changes directory to load its assets.
        let launchDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath,
                                  isDirectory: true)
        if !LavaHost.isClient { Theme.current = .paper }
        guard let editor = LavaHost.open(title: "LavaEditor", width: 1040, height: 640) else { exit(1) }
        LavaHost.setMinimumSize(editor: editor, width: 480, height: 280)

        let session = EditorSession(editor: editor)
        let fontDialog = EditorFontDialog()
        session.restoreSession()
        session.openArguments(Array(CommandLine.arguments.dropFirst()), relativeTo: launchDirectory)

        session.commandMenu = { menuBar(session: session, fontDialog: fontDialog, editor: editor) }

        LavaHost.run(
            editor: editor,
            menu: { menuBar(session: session, fontDialog: fontDialog, editor: editor) },
            onRawKey: { event in
                // Escape in the chat's field closes the chat, wherever the
                // field's own handling would have sent it.
                if let chat = session.inlineChat, chat.inputFocused, session.pendingWorkspace == nil,
                   event.button == KeyCode.escape {
                    if event.x > 0 { session.closeInlineChat() }
                    return true
                }
                guard session.pendingWorkspace != nil else { return false }
                if event.x > 0, event.button == KeyCode.escape {
                    session.pendingWorkspace = nil
                }
                return true
            },
            makeRoot: {
                let appearance = EditorAppearance(theme: Theme.current)
                return EditorWorkspaceWindow(session: session, appearance: appearance, fontDialog: fontDialog)
                    .theme(appearance.theme)
            }
        )
    }

    /// The menu bar, which is also every command the palette (Alt+X) offers:
    /// it builds this again each time it opens, so a command is enabled
    /// there exactly when it is in the menu.
    static func menuBar(session: EditorSession, fontDialog: EditorFontDialog, editor: Editor) -> MenuBar {
        var bar = MenuBar {
            Menu("Editor", id: "app") {
                MenuItem("About LavaEditor", id: "app.about") {
                    FileHandle.standardError.write(
                        Data("LavaEditor · a plain text editor built on LavaUI\n".utf8)
                    )
                }
                MenuSeparator()
                MenuItem("Choose Font…", id: "app.choose-font") {
                    fontDialog.present(for: session)
                }
                MenuItem("Open User Settings", id: "app.user-settings") { session.openUserSettings() }
                MenuItem("Open Folder Settings", id: "app.folder-settings",
                         isEnabled: session.project != nil || session.workspaceURL != nil) {
                    session.openFolderSettings()
                }
                MenuSeparator()
                MenuItem(
                    "Quit", id: "app.quit",
                    shortcut: KeyShortcut(KeyCode.q, .primary)
                ) {
                    editor.requestClose()
                }
            }
            Menu("File", id: "file") {
                MenuItem(
                    "New", id: "file.new",
                    shortcut: KeyShortcut(KeyCode.n, .primary)
                ) { session.newDocument() }
                MenuItem(
                    "Open…", id: "file.open",
                    shortcut: KeyShortcut(KeyCode.o, .primary)
                ) { session.openFileDialog() }
                MenuItem(
                    "Open Folder…", id: "file.open-folder",
                    shortcut: KeyShortcut(KeyCode.o, [.primary, .shift])
                ) { session.openFolderDialog() }
                recentProjects(session, kind: .folder)
                MenuItem("Open Workspace…", id: "file.open-workspace") {
                    session.openWorkspaceDialog()
                }
                recentProjects(session, kind: .workspace)
                MenuItem("Save Workspace As…", id: "file.save-workspace-as") {
                    session.saveWorkspaceAs()
                }
                MenuItem("Close Workspace", id: "file.close-workspace",
                         isEnabled: session.workspaceURL != nil) {
                    session.closeWorkspace()
                }
                Menu("Recent Files", id: "file.recent") {
                    if session.recentFiles.isEmpty {
                        MenuItem("No Recent Files", id: "file.recent.empty",
                                 isEnabled: false) {}
                    }
                    for (index, path) in session.recentFiles.enumerated() {
                        MenuItem(path, id: "file.recent.\(index)") {
                            session.open([URL(fileURLWithPath: path)])
                        }
                    }
                    MenuSeparator()
                    MenuItem("Clear Recent Files", id: "file.recent.clear",
                             isEnabled: !session.recentFiles.isEmpty) {
                        session.clearRecentFiles()
                    }
                }
                MenuSeparator()
                MenuItem(
                    "Save", id: "file.save",
                    shortcut: KeyShortcut(KeyCode.s, .primary),
                    isEnabled: session.active.saveUnavailable == nil
                ) { session.save() }
                MenuItem(
                    "Save As…", id: "file.save-as",
                    shortcut: KeyShortcut(KeyCode.s, [.primary, .shift]),
                    isEnabled: session.active.saveUnavailable == nil
                ) { session.saveAs() }
                MenuItem("Revert File", id: "file.revert", isEnabled: session.canRevert) { session.revertFile() }
                MenuItem("Reload from Disk", id: "file.reload", isEnabled: session.active.url != nil) { session.reload() }
                // Not inside a workspace: the folder is part of it,
                // and closing it there was a workspace that saved
                // itself without one. Close Workspace is the way out,
                // and keeps the folder — VS Code draws the same line.
                if session.workspaceURL == nil {
                    MenuItem("Close Folder", id: "file.close-folder",
                             isEnabled: session.project != nil) { session.closeFolder() }
                }
                MenuSeparator()
                MenuItem(
                    "Close Tab", id: "file.close",
                    shortcut: KeyShortcut(KeyCode.w, .primary)
                ) { session.requestClose() }
            }
            Menu("Search", id: "search") {
                MenuItem(
                    "Find…", id: "search.find",
                    shortcut: KeyShortcut(KeyCode.f, .primary),
                    isEnabled: session.active.preview == nil
                ) { session.openFind(replace: false) }
                MenuItem(
                    "Find and Replace…", id: "search.replace",
                    shortcut: KeyShortcut(KeyCode.h, .primary),
                    isEnabled: session.active.saveUnavailable == nil
                ) { session.openFind(replace: true) }
                MenuItem(
                    "Find Next", id: "search.next",
                    shortcut: KeyShortcut(KeyCode.g, .primary),
                    isEnabled: session.active.preview == nil
                ) { session.findNext() }
                // Shift+F3 rather than Ctrl+Shift+G, which opens
                // Source Control — as both are in VS Code.
                MenuItem(
                    "Find Previous", id: "search.previous",
                    shortcut: KeyShortcut(KeyCode.f3, .shift),
                    isEnabled: session.active.preview == nil
                ) { session.findPrevious() }
                MenuSeparator()
                MenuItem(
                    "Go to Line…", id: "search.goto",
                    shortcut: KeyShortcut(KeyCode.l, .primary),
                    isEnabled: session.active.preview == nil
                ) { session.openGoto() }
            }
            Menu("Assistant", id: "assistant") {
                MenuItem(
                    "Ask about These Lines", id: "assistant.inline-chat",
                    shortcut: KeyShortcut(KeyCode.i, .primary),
                    isEnabled: session.active.preview == nil && session.active.isLoaded
                ) { session.openInlineChat() }
                MenuItem(
                    "Close Inline Chat", id: "assistant.close",
                    isEnabled: session.inlineChat != nil
                ) { session.closeInlineChat() }
            }
            Menu("Git", id: "git") {
                MenuItem(
                    "Switch Branch or Worktree…", id: "git.switch",
                    isEnabled: session.project?.isInRepository == true
                ) { session.openBranchPicker() }
                MenuSeparator()
                MenuItem(
                    session.visibleDiff == nil ? "Compare with HEAD" : "Close Comparison",
                    id: "git.compare-head",
                    shortcut: KeyShortcut(KeyCode.d, [.primary, .shift]),
                    isEnabled: session.active.preview == nil
                ) { session.compareWithHEAD() }
                MenuSeparator()
                MenuItem(
                    "Next Change", id: "git.next-change",
                    shortcut: KeyShortcut(KeyCode.f7, []),
                    isEnabled: session.visibleDiff != nil
                ) { session.stepDiff(forward: true) }
                MenuItem(
                    "Previous Change", id: "git.previous-change",
                    shortcut: KeyShortcut(KeyCode.f7, .shift),
                    isEnabled: session.visibleDiff != nil
                ) { session.stepDiff(forward: false) }
            }
            Menu("View", id: "view") {
                // Alt+X, as in Emacs: every command in this bar by name.
                MenuItem(
                    "Run Command…", id: EditorSession.commandPaletteID,
                    shortcut: KeyShortcut(KeyCode.x, .option)
                ) { session.toggleCommandPalette() }
                MenuSeparator()
                MenuItem(
                    "Toggle Sidebar", id: "view.sidebar",
                    shortcut: KeyShortcut(KeyCode.b, .primary)
                ) { session.toggleSidebar() }
                MenuItem(
                    "Explorer", id: "view.explorer",
                    shortcut: KeyShortcut(KeyCode.e, [.primary, .shift])
                ) { session.showSidebar(.explorer) }
                MenuItem(
                    "Search", id: "view.search",
                    shortcut: KeyShortcut(KeyCode.f, [.primary, .shift])
                ) { session.showProjectSearch() }
                MenuItem(
                    "Source Control", id: "view.source-control",
                    shortcut: KeyShortcut(KeyCode.g, [.primary, .shift])
                ) { session.showSidebar(.sourceControl) }
                MenuItem(
                    "Problems", id: "view.problems",
                    shortcut: KeyShortcut(KeyCode.m, [.primary, .shift])
                ) { session.toggleProblems() }
                MenuItem(
                    "Terminal", id: "view.terminal",
                    shortcut: KeyShortcut(KeyCode.graveAccent, .primary)
                ) { session.toggleTerminal() }
                MenuItem(
                    "Toggle Panel", id: "view.panel",
                    shortcut: KeyShortcut(KeyCode.j, .primary)
                ) { session.toggleTerminal() }
                MenuItem(
                    "New Terminal", id: "view.new-terminal",
                    shortcut: KeyShortcut(KeyCode.graveAccent, [.primary, .shift])
                ) { session.newTerminal() }
                MenuItem("Refresh Folder", id: "view.refresh-folder",
                         isEnabled: session.project != nil) { session.project?.refresh() }
                MenuItem("Toggle Soft Wrap", id: "view.wrap", isChecked: session.wraps) {
                    session.wraps.toggle()
                }
                MenuItem("Toggle Line Numbers", id: "view.line-numbers", isChecked: session.showLineNumbers) {
                    session.showLineNumbers.toggle()
                }
                MenuItem("Toggle Changed-Line Highlight", id: "view.change-fills",
                         isChecked: session.highlightsChangedLines) {
                    session.highlightsChangedLines.toggle()
                }
            }
        }
        // An extension's shortcut gives way to the editor's own: the
        // Extensions menu comes before Search, Git and View, and the first
        // match in the bar is the one a key runs.
        let taken = Set(bar.menus.flatMap(Self.shortcuts(in:)))
        bar.menus.insert(Self.extensionsMenu(session: session, taken: taken), at: min(2, bar.menus.count))
        return bar
    }

    private static func extensionsMenu(session: EditorSession, taken: Set<KeyShortcut>) -> Menu {
        Menu("Extensions", id: "extensions") {
            for installed in session.matchingExtensionCommands {
                MenuItem(installed.command.title, id: installed.menuID,
                         shortcut: installed.command.keyShortcut.flatMap { taken.contains($0) ? nil : $0 },
                         isEnabled: !session.extensionRunning
                            && (installed.command.kind == .command || session.active.saveUnavailable == nil)) {
                    session.runExtension(installed)
                }
            }
            MenuItem("Reload Extensions", id: "extensions.reload") {
                session.reloadExtensions()
            }
        }
    }

    private static func shortcuts(in menu: Menu) -> [KeyShortcut] {
        menu.content.flatMap { content -> [KeyShortcut] in
            switch content {
            case .item(let item): return item.shortcut.map { [$0] } ?? []
            case .submenu(let menu): return shortcuts(in: menu)
            case .separator: return []
            }
        }
    }

    private static func recentProjects(_ session: EditorSession, kind: RecentProjectKind) -> Menu {
        let noun = kind == .folder ? "Folder" : "Workspace"
        let id = kind == .folder ? "file.recent-folders" : "file.recent-workspaces"
        let paths = session.visibleRecentPaths(kind)
        return Menu("Open Recent \(noun)", id: id) {
            if paths.isEmpty {
                MenuItem("No Recent \(noun)s", id: "\(id).empty", isEnabled: false) {}
            }
            for (index, path) in paths.enumerated() {
                MenuItem(path, id: "\(id).\(index)") {
                    let url = URL(fileURLWithPath: path)
                    switch kind {
                    case .folder: session.openFolder(url)
                    case .workspace: session.openWorkspace(url)
                    }
                }
            }
            MenuSeparator()
            MenuItem("Clear Recent \(noun)s", id: "\(id).clear",
                     isEnabled: !(session.recentProjectPaths[kind] ?? []).isEmpty) {
                session.clearRecentProjectPaths(kind)
            }
        }
    }
}

/// Started from inside a Claude Code session — its shell tool, a `!`
/// command — the editor inherits that session's identity: its id, the token
/// for its messaging socket, and the mark of being its child. Everything the
/// editor starts would inherit it in turn, so a `claude` typed into the
/// terminal panel believed it was a sub-session of that one, did not
/// register as a session of its own (`claude agents` never listed it, which
/// the Agents view and the inline chat rely on to tell a running session
/// from a stopped one), and held another session's token besides.
///
/// Only what ties a process to one running session goes; settings that
/// apply to every session (`CLAUDE_CONFIG_DIR`, the user's own `CLAUDE_*`
/// preferences) stay.
private func forgetLaunchingAgentSession() {
    for (key, _) in ProcessInfo.processInfo.environment
    where key == "CLAUDECODE" || key == "CLAUDE_PID" || key == "CLAUDE_EFFORT" || key.hasPrefix("CLAUDE_CODE_") {
        unsetenv(key)
    }
}
