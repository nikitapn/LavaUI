import Foundation
import LavaExplorerCore
import LavaHost
import LavaUI

/// LavaExplorer — one folder, as a list.
///
/// Browse and open, copy by dropping, and throw away into the desktop's
/// Trash — the freedesktop one, shared with every other file manager. No
/// rename yet. A double-click on a folder goes in; a double-click on a file
/// asks the desktop to open it.
enum Layout {
    static let initialWidth: Float = 960
    static let initialHeight: Float = 640
    static let minWidth: Float = 640
    static let minHeight: Float = 360
}

@main
struct LavaExplorerApp {
    static func main() {
        AppSettings.configure(appName: "LavaExplorer")

        guard let editor = LavaHost.open(
            title: "LavaExplorer",
            width: Layout.initialWidth, height: Layout.initialHeight
        ) else { exit(1) }

        LavaHost.setMinimumSize(
            editor: editor, width: Layout.minWidth, height: Layout.minHeight
        )
        Theme.current = .nebula

        let paths = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        let session = ExplorerSession(
            paths: paths.isEmpty ? [NSHomeDirectory()] : Array(paths)
        )
        session.requestClose = { editor.requestClose() }

        LavaHost.run(
            editor: editor,
            menu: { menu(session: session, editor: editor) },
            onRawKey: { event in keys(event, session: session) },
            makeRoot: { ExplorerView(session: session) }
        )
    }

    private static func menu(session: ExplorerSession, editor: Editor) -> MenuBar {
        MenuBar {
            Menu("LavaExplorer", id: "app") {
                MenuItem("About LavaExplorer", id: "app.about") {
                    FileHandle.standardError.write(Data(
                        "LavaExplorer · a folder, as a list\n".utf8
                    ))
                }
                MenuSeparator()
                MenuItem(
                    "Quit", id: "app.quit",
                    shortcut: KeyShortcut(KeyCode.q, .primary)
                ) { editor.requestClose() }
            }
            Menu("File", id: "file") {
                // Enter is handled in `keys` only when the address bar is
                // not focused — a menu shortcut would steal it from the field.
                MenuItem("Open", id: "file.open") { session.activate() }
                MenuItem(
                    "New Tab", id: "file.new-tab",
                    shortcut: KeyShortcut(KeyCode.t, .primary)
                ) { session.newTab() }
                MenuItem(
                    "Close Tab", id: "file.close-tab",
                    shortcut: KeyShortcut(KeyCode.w, .primary)
                ) { session.closeTab(id: session.tabSet.currentID) }
                // Ctrl+Shift+N in `keys`, for the reason Delete is there.
                MenuItem("New Folder", id: "file.new-folder") { session.startNewFolder() }
                MenuItem(
                    "Reload", id: "file.reload",
                    shortcut: KeyShortcut(KeyCode.r, .primary)
                ) { session.reload() }
            }
            Menu("Edit", id: "edit") {
                // Ctrl+Z and Ctrl+Shift+Z are handled in `keys`, which leaves
                // them to the address bar while it is being typed in.
                MenuItem("Undo", id: "edit.undo") { session.undo() }
                MenuItem("Redo", id: "edit.redo") { session.redo() }
                MenuSeparator()
                MenuItem("Select All", id: "edit.select-all") { session.selectAll() }
                MenuItem("Copy Path", id: "edit.copy-path") {
                    session.copySelectedPath()
                }
                MenuSeparator()
                // Delete itself is handled in `keys`: a menu shortcut would
                // take it from the address bar while a path is being edited.
                MenuItem("Move to Trash", id: "edit.trash") {
                    session.deleteSelected(permanently: false)
                }
                MenuItem("Delete Permanently", id: "edit.delete") {
                    session.deleteSelected(permanently: true)
                }
                MenuItem("Empty Trash", id: "edit.empty-trash") {
                    session.askToEmptyTrash()
                }
            }
            Menu("View", id: "view") {
                MenuItem("Show Hidden Files", id: "view.hidden") {
                    session.toggleHidden()
                }
                MenuSeparator()
                MenuItem("Sort by Name", id: "view.sort-name") {
                    session.setSort(.name)
                }
                MenuItem("Sort by Size", id: "view.sort-size") {
                    session.setSort(.size)
                }
                MenuItem("Sort by Date", id: "view.sort-modified") {
                    session.setSort(.modified)
                }
            }
            Menu("Go", id: "go") {
                MenuItem("Back", id: "go.back") { session.goBack() }
                MenuItem("Forward", id: "go.forward") { session.goForward() }
                MenuItem("Up", id: "go.up") { session.goUp() }
                MenuSeparator()
                MenuItem("Home", id: "go.home") { session.goHome() }
                MenuItem("Computer", id: "go.computer") { session.go("/") }
                MenuItem("Trash", id: "go.trash") { session.go(TrashPath.uri) }
            }
        }
    }

    /// Navigation keys. The address bar keeps Enter, Backspace and the
    /// arrows while it is focused — `onRawKey` runs first, so anything we
    /// consume here never reaches the field.
    private static func keys(_ event: InputEvent, session: ExplorerSession) -> Bool {
        guard event.x > 0 else { return false }
        let mods = Int32(event.y)
        let control = (mods & KeyMods.control) != 0
        let alt = (mods & KeyMods.alt) != 0
        let shift = (mods & KeyMods.shift) != 0
        let typing = FocusManager.focusedID != nil

        // Before the field gets it: Escape in the new folder's name is
        // "never mind", not "stop typing".
        if event.button == KeyCode.escape, session.newFolderDraft != nil {
            session.cancelNewFolder()
            return true
        }
        if typing && !control && !alt { return false }

        switch event.button {
        case KeyCode.enter where !typing:
            session.activate()
        case KeyCode.backspace where !typing && !control:
            session.goUp()
        case KeyCode.up where !typing && !alt:
            session.moveSelection(by: -1, extending: shift)
        case KeyCode.down where !typing:
            session.moveSelection(by: 1, extending: shift)
        case KeyCode.a where control && !typing:
            session.selectAll()
        case KeyCode.n where control && shift:
            session.startNewFolder()
        case KeyCode.z where control && !typing:
            if shift { session.redo() } else { session.undo() }
        case KeyCode.y where control && !typing:
            session.redo()
        case KeyCode.left where alt:
            session.goBack()
        case KeyCode.right where alt:
            session.goForward()
        case KeyCode.up where alt:
            session.goUp()
        case KeyCode.h where control:
            session.toggleHidden()
        case KeyCode.r where control:
            session.reload()
        case KeyCode.t where control:
            session.newTab()
        case KeyCode.w where control:
            session.closeTab(id: session.tabSet.currentID)
        case KeyCode.tab where control:
            session.cycleTab(by: shift ? -1 : 1)
        case KeyCode.pageDown where control:
            session.cycleTab(by: 1)
        case KeyCode.pageUp where control:
            session.cycleTab(by: -1)
        case KeyCode.delete where !typing:
            session.deleteSelected(permanently: shift)
        case KeyCode.escape where session.pendingErase != nil:
            session.resolveErase(false)
        case KeyCode.escape where !typing && session.selectedEntries.count > 1:
            session.clearSelection()
        case KeyCode.l where control:
            // The field is already there; focusing it is a click. Ctrl+L
            // still reloads the draft from the current path so a half-typed
            // address can be thrown away.
            session.pathDraft = session.listing.path
            ViewInvalidation.markDirty()
        default:
            return false
        }
        return true
    }
}
