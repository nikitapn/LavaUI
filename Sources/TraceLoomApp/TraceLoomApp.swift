import Foundation
import LavaHost
import LavaUI

/// Runs TraceLoom, a pattern-driven log timeline product built with LavaUI.
@main
struct TraceLoomApp {
    static func main() {
        guard let editor = LavaHost.open(title: "TraceLoom · Log Timeline Studio") else {
            exit(1)
        }

        // One session instance shared by the menubar and the root view.
        // Menu closures capture this reference; the view reads the same
        // `@Observable` object — see `TraceLoomSession`.
        let session = TraceLoomSession()

        LavaHost.run(
            editor: editor,
            menu: {
                // One home per action. Duplicating an item across menus is not
                // harmless here: DBusMenu exports each id as its own entry, so
                // the panel really does show both.
                //
                // The app menu stays even though its contents would fit
                // elsewhere — Vala Panel draws a clickable stub with its own
                // "New"/"Quit" when an application exports none, so an empty
                // slot is worse than a real one. Chrome does the same thing
                // with its "Google Chrome" menu. About/Settings/Quit live here
                // because that is the convention the slot implies.
                MenuBar {
                    Menu("TraceLoom", id: "app") {
                        MenuItem("About TraceLoom", id: "app.about") {
                            FileHandle.standardError.write(
                                Data("TraceLoom · log timeline studio\n".utf8)
                            )
                        }
                        MenuSeparator()
                        MenuItem(
                            "Settings…",
                            id: "app.settings",
                            shortcut: KeyShortcut(KeyCode.comma, .primary)
                        ) {
                            session.openSettings()
                        }
                        MenuSeparator()
                        MenuItem(
                            "Quit TraceLoom",
                            id: "app.quit",
                            shortcut: KeyShortcut(KeyCode.q, .primary)
                        ) {
                            editor.requestClose()
                        }
                    }
                    Menu("File", id: "file") {
                        MenuItem(
                            "Open Log…",
                            id: "file.open",
                            shortcut: KeyShortcut(KeyCode.o, .primary)
                        ) {
                            session.openLogFile()
                        }
                        MenuItem("Reload Sample", id: "file.reload-sample") {
                            session.reloadSample()
                        }
                    }
                    Menu("View", id: "view") {
                        MenuItem(
                            "Lanes",
                            id: "view.lanes",
                            isChecked: session.timelineLayout == .lanes
                        ) {
                            session.timelineLayout = .lanes
                        }
                        MenuItem(
                            "Overlay",
                            id: "view.overlay",
                            isChecked: session.timelineLayout == .overlay
                        ) {
                            session.timelineLayout = .overlay
                        }
                        MenuSeparator()
                        MenuItem(
                            "Toggle Theme",
                            id: "view.theme",
                            shortcut: KeyShortcut(KeyCode.t, .primary)
                        ) {
                            Theme.current = (Theme.current == .dark) ? .light : .dark
                        }
                    }
                    // Not a second About — that would be the duplicate this
                    // menu exists to avoid. Help answers "how do I use this",
                    // which for TraceLoom is the rule syntax.
                    Menu("Help", id: "help") {
                        MenuItem("Rule Syntax", id: "help.syntax") {
                            let msg = """
                                TraceLoom rule: kind | name | regex | \
                                time capture | value capture | shared scale
                                  kind:  line, step, or event
                                  time:  1-based capture group, \
                                ms or HH:MM:SS.mmm
                                  value: 1-based capture group, or - for event
                                Open a log from File → Open Log…
                                """
                            FileHandle.standardError.write(Data((msg + "\n").utf8))
                        }
                    }
                }
            }
        ) {
            TraceLoom(session: session)
        }
    }
}
