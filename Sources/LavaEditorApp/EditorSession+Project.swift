import Foundation
import LavaProjectCore
import LavaUI

/// The project folder: opening one, and keeping its tree on the document in
/// front.
extension EditorSession {
    func openFolderDialog() {
        guard let folder = FileDialog.openFolder(title: "Open Folder") else { return }
        openFolder(folder)
    }

    func openFolder(_ url: URL) {
        let root = url.standardizedFileURL
        guard Self.isDirectory(root) else {
            notice = "\(root.path) is not a folder."
            return
        }
        rememberProjectPath(root, kind: .folder)
        if project?.tree.root.path == root.path {
            showsSidebar = true
            return
        }
        restoreProject(root.path, expanded: [])
        followActive()
        showsSidebar = true
    }

    func closeFolder() {
        project?.close()
        project = nil
    }

    /// Opens `path` as the project with `expanded` folders open, as a
    /// previous session left it. A folder that has gone since is not an
    /// error worth a notice at startup; the sidebar simply is not there.
    func restoreProject(_ path: String, expanded: Set<String>) {
        let root = URL(fileURLWithPath: path, isDirectory: true)
        guard Self.isDirectory(root) else { return }
        project?.close()
        let project = ProjectSession(root: root, expanded: expanded)
        let owner = SessionRef(session: self)
        // A commit, a checkout or a reset moved HEAD under every open file.
        project.onRepositoryChanged = {
            let session = owner.session
            for index in session.documents.indices where session.documents[index].isLoaded {
                session.refreshBaseline(index)
            }
        }
        self.project = project
    }

    /// Opens a file from the tree in a tab, or brings its tab forward.
    func openFromTree(_ path: String, clicks: Int) {
        guard let project else { return }
        let doubleClick = clicks > 1 && project.selected == path
        project.selected = path
        open([project.tree.url(of: path)], mode: doubleClick ? .treeDoubleClick : .treeClick)
    }

    func revealInExplorer(_ url: URL) {
        guard let project, let path = project.tree.path(of: url), !path.isEmpty else { return }
        showSidebar(.explorer)
        project.reveal(url)
        if let row = project.rows.firstIndex(where: { $0.node.path == path }) {
            project.scroll.scroll(to: Float(row) * projectRowHeight)
        }
    }

    var projectRowHeight: Float {
        (((fonts.tab ?? FontStore.default)?.lineHeight ?? 18) + 8).rounded()
    }

    /// Shows `view` in the sidebar, asking for a folder first if none is
    /// open — every view in it is about one.
    func showSidebar(_ view: SidebarView) {
        guard project != nil else {
            openFolderDialog()
            if project != nil { sidebarView = view }
            return
        }
        sidebarView = view
        showsSidebar = true
        if view == .agents { startAgentsPolling() }
    }

    func toggleSidebar() {
        if project == nil {
            openFolderDialog()
        } else {
            showsSidebar.toggle()
        }
    }

    /// Selects the document in front in the tree, opening the folders above
    /// it — so the tree always says where the file being edited lives.
    func followActive() {
        guard let project, let url = active.url else { return }
        project.reveal(url)
    }

    static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}
