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

        guard let editor = LavaHost.open(title: "LavaEditor") else { exit(1) }

        let session = EditorSession()
        session.openArguments(Array(CommandLine.arguments.dropFirst()))

        LavaHost.run(
            editor: editor,
            menu: {
                MenuBar {
                    Menu("LavaEditor", id: "app") {
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
                        MenuSeparator()
                        MenuItem(
                            "Save", id: "file.save",
                            shortcut: KeyShortcut(KeyCode.s, .primary)
                        ) { session.save() }
                        MenuItem(
                            "Save As…", id: "file.save-as",
                            shortcut: KeyShortcut(KeyCode.s, [.primary, .shift])
                        ) { session.saveAs() }
                        MenuItem("Reload from Disk", id: "file.reload") { session.reload() }
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
                            shortcut: KeyShortcut(KeyCode.h, .primary)
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
                    Menu("View", id: "view") {
                        MenuItem("Toggle Soft Wrap", id: "view.wrap") {
                            session.wraps.toggle()
                        }
                        MenuItem("Toggle Line Numbers", id: "view.line-numbers") {
                            session.showLineNumbers.toggle()
                        }
                    }
                }
            },
            makeRoot: { LavaEditorView(session: session) }
        )
    }
}
