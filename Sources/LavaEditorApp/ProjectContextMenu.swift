import Foundation
import LavaProjectCore
import LavaUI

/// The project tree's right-click menu: on a row, what can be done to that
/// file or folder; on the empty space below the rows, to the project's top.
/// The same in-window menu as a tab's (`TabContextMenu`).
struct ProjectContextMenu: View {
    struct Anchor {
        /// The row clicked, or nil for the space below the rows.
        let path: String?
        let x: Float
        let y: Float
    }

    let session: EditorSession
    let project: ProjectSession
    let path: String?
    let style: MenuBarStyle
    let dismiss: () -> Void

    private enum Action: String {
        case newFile, newFolder, rename, trash, copyPath, copyRelative, openInExplorer, refresh

        func item(_ title: String) -> MenuEntry {
            .item(MenuItemModel(id: MenuID(rawValue), title: title))
        }
    }

    @ViewBuilder var body: some View {
        let row = path.flatMap { path in project.rows.first { $0.node.path == path } }
        let url = project.tree.url(of: path ?? "")
        let onRow: [MenuEntry] = row == nil ? [] : [
            .separator,
            Action.rename.item("Rename"),
            Action.trash.item("Move to Trash"),
        ]
        let panel = MenuDropdownPanel(
            entries: [
                Action.newFile.item("New File…"),
                Action.newFolder.item("New Folder…"),
            ] + onRow + [
                .separator,
                Action.copyPath.item("Copy Path"),
            ] + (row == nil ? [] : [Action.copyRelative.item("Copy Relative Path")]) + [
                Action.openInExplorer.item(row?.node.isDirectory == false
                    ? "Open Containing Folder" : "Open in LavaExplorer"),
                .separator,
                Action.refresh.item("Refresh"),
            ],
            onActivate: { [session, project, path] id in
                dismiss()
                guard let action = Action(rawValue: id.raw) else { return }
                switch action {
                case .newFile: session.createInTree(folder: false, near: path)
                case .newFolder: session.createInTree(folder: true, near: path)
                case .rename: session.beginRename()
                case .trash: session.trashSelected()
                case .copyPath: ClipboardBridge.write(url.path)
                case .copyRelative: if let path { ClipboardBridge.write(path) }
                case .openInExplorer:
                    let folder = row?.node.isDirectory == false ? url.deletingLastPathComponent() : url
                    if !TabContextMenu.launchExplorer(at: folder) {
                        session.notice = "Could not launch LavaExplorer"
                    }
                case .refresh: project.refresh()
                }
            },
            style: style
        )
        if let font = session.fonts.tab { panel.font(font) } else { panel }
    }
}
