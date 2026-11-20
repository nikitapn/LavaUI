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
        // Before the session, which reads the wrap and line-number settings
        // out of it in its initialiser.
        AppSettings.configure(appName: "LavaEditor")

        if !LavaHost.isClient { Theme.current = .paper }
        guard let editor = LavaHost.open(title: "LavaEditor", width: 1040, height: 640) else { exit(1) }
        LavaHost.setMinimumSize(editor: editor, width: 480, height: 280)

        let session = EditorSession(editor: editor)
        session.restoreSession()
        session.openArguments(Array(CommandLine.arguments.dropFirst()))

        LavaHost.run(
            editor: editor,
            menu: {
                MenuBar {
                    Menu("Editor", id: "app") {
                        MenuItem("About LavaEditor", id: "app.about") {
                            FileHandle.standardError.write(
                                Data("LavaEditor · a plain text editor built on LavaUI\n".utf8)
                            )
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
                        MenuItem("Reload from Disk", id: "file.reload") { session.reload() }
                        MenuItem("Close Folder", id: "file.close-folder",
                                 isEnabled: session.project != nil) { session.closeFolder() }
                        MenuSeparator()
                        MenuItem(
                            "Close Tab", id: "file.close",
                            shortcut: KeyShortcut(KeyCode.w, .primary)
                        ) { session.requestClose() }
                    }
                    Menu("Search", id: "search") {
                        MenuItem(
                            "Find…", id: "search.find",
                            shortcut: KeyShortcut(KeyCode.f, .primary)
                        ) { session.openFind(replace: false) }
                        MenuItem(
                            "Find and Replace…", id: "search.replace",
                            shortcut: KeyShortcut(KeyCode.h, .primary),
                            isEnabled: session.active.saveUnavailable == nil
                        ) { session.openFind(replace: true) }
                        MenuItem(
                            "Find Next", id: "search.next",
                            shortcut: KeyShortcut(KeyCode.g, .primary)
                        ) { session.findNext() }
                        MenuItem(
                            "Find Previous", id: "search.previous",
                            shortcut: KeyShortcut(KeyCode.g, [.primary, .shift])
                        ) { session.findPrevious() }
                        MenuSeparator()
                        MenuItem(
                            "Go to Line…", id: "search.goto",
                            shortcut: KeyShortcut(KeyCode.l, .primary)
                        ) { session.openGoto() }
                    }
                    Menu("Git", id: "git") {
                        MenuItem(
                            session.visibleDiff == nil ? "Compare with HEAD" : "Close Comparison",
                            id: "git.compare-head",
                            shortcut: KeyShortcut(KeyCode.d, [.primary, .shift])
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
                        MenuItem(
                            "Toggle Sidebar", id: "view.sidebar",
                            shortcut: KeyShortcut(KeyCode.b, .primary)
                        ) { session.toggleSidebar() }
                        MenuItem("Refresh Folder", id: "view.refresh-folder",
                                 isEnabled: session.project != nil) { session.project?.refresh() }
                        MenuItem("Toggle Soft Wrap", id: "view.wrap") {
                            session.wraps.toggle()
                        }
                        MenuItem("Toggle Line Numbers", id: "view.line-numbers") {
                            session.showLineNumbers.toggle()
                        }
                        MenuItem("Toggle Changed-Line Highlight", id: "view.change-fills") {
                            session.highlightsChangedLines.toggle()
                        }
                    }
                }
            },
            makeRoot: {
                let appearance = EditorAppearance(theme: Theme.current)
                return LavaEditorView(session: session, appearance: appearance)
                    .theme(appearance.theme)
            }
        )
    }
}
