import Foundation
import LavaExplorerCore
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
        showsSidebar = true
        if project?.tree.root.path == root.path {
            if sidebarView == .agents { startAgentsPolling() }
            return
        }
        restoreProject(root.path, expanded: [])
        followActive()
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
            session.blame.invalidate()
            session.dismissBlameCard()
            for index in session.documents.indices where session.documents[index].isLoaded {
                session.refreshBaseline(index)
            }
        }
        self.project = project
        if showsSidebar, sidebarView == .agents { startAgentsPolling() }
    }

    /// Opens a file from the tree in a tab, or brings its tab forward.
    func openFromTree(_ path: String, clicks: Int) {
        guard let project else { return }
        let doubleClick = clicks > 1 && project.selected == path
        project.selected = path
        open([project.tree.url(of: path)], mode: doubleClick ? .treeDoubleClick : .treeClick)
        // A click leaves the keyboard on the tree, for the arrows; a double
        // click means "I want to work on this", so the keys go to the file.
        // After the press, which is when the tree takes focus.
        if doubleClick { FrameTasks.after { [controller] in controller.focus() } }
    }

    // MARK: - Renaming and throwing away

    /// Puts the selected row's name in a field in place (F2), with the part
    /// before the extension selected — what gets retyped far more often than
    /// the type.
    func beginRename() {
        guard let project, let path = project.selected, !path.isEmpty else { return }
        project.renameText = String(path.split(separator: "/").last ?? "")
        project.renaming = path
    }

    /// Makes a file or folder next to `target` — inside it when it is a
    /// folder, beside it when it is a file, at the top for nil — under a name
    /// that is free, and puts that name in the rename field, all of it
    /// selected. Made first and named after, as file managers do: the row is
    /// real from the start, and Escape takes it away again while it is empty.
    func createInTree(folder: Bool, near target: String?) {
        guard let project else { return }
        let row = target.flatMap { path in project.rows.first { $0.node.path == path } }
        let parent: String
        if let row {
            parent = row.node.isDirectory ? row.node.path : ProjectTree.parent(of: row.node.path)
        } else {
            parent = ""
        }
        let directory = project.tree.url(of: parent).path
        // `lstat`, not `fileExists`: a dangling link still holds its name.
        func exists(_ path: String) -> Bool {
            var info = stat()
            return lstat(path, &info) == 0
        }
        let made: String
        do {
            if folder {
                made = try NewFolder.make(
                    named: NewFolder.freeName(in: directory, exists: exists), in: directory
                )
            } else {
                var name = "untitled"
                if exists(directory + "/" + name) {
                    name = CopyNaming.keepBoth(name, isDirectory: false, in: directory, exists: exists)
                }
                made = directory + "/" + name
                // Exclusive, so a file that appeared since the check is not
                // emptied out.
                let fd = Glibc.open(made, O_WRONLY | O_CREAT | O_EXCL, 0o644)
                guard fd >= 0 else {
                    throw FileAccessError(path: made, message: String(cString: strerror(errno)))
                }
                Glibc.close(fd)
            }
        } catch {
            notice = "Could not make a new \(folder ? "folder" : "file"): \(Self.describe(error))"
            return
        }
        guard let path = project.tree.path(of: URL(fileURLWithPath: made)) else { return }
        project.created(path, rowHeight: projectRowHeight)
        project.creating = path
        project.renameText = (made as NSString).lastPathComponent
        project.renaming = path
    }

    /// Renames on disk and takes everything that pointed at the old name
    /// along: the tree, its open folders, and tabs on the file or on files
    /// inside a renamed folder. A refusal — the name is taken, or not a name
    /// — keeps the field open to fix it.
    func commitRename() {
        guard let project, let path = project.renaming else { return }
        let old = project.tree.url(of: path)
        let newPath: String
        do {
            newPath = try Rename.rename(old.path, to: project.renameText)
        } catch {
            notice = "Could not rename \(old.lastPathComponent): \(Self.describe(error))"
            return
        }
        project.renaming = nil
        project.treeFocused = true
        let new = URL(fileURLWithPath: newPath)
        let wasCreating = project.creating == path
        project.creating = nil
        defer {
            // A file just made is made to be written in.
            if wasCreating, !Self.isDirectory(new), let relative = project.tree.path(of: new) {
                project.selected = relative
                open([new], mode: .treeDoubleClick)
                FrameTasks.after { [controller] in controller.focus() }
            }
        }
        guard let relative = project.tree.path(of: new), relative != path else { return }
        for index in documents.indices {
            guard let url = documents[index].url?.standardizedFileURL else { continue }
            if url == old.standardizedFileURL {
                documents[index].url = new
            } else if url.path.hasPrefix(old.standardizedFileURL.path + "/") {
                documents[index].url = URL(fileURLWithPath:
                    new.path + url.path.dropFirst(old.standardizedFileURL.path.count))
            }
        }
        project.moved(path, to: relative)
        project.refreshStatus()
        notice = "Renamed to \(new.lastPathComponent)"
    }

    /// Leaves the name as it was. Also what losing focus does when the name
    /// was not changed; a changed one is kept, as a click elsewhere means
    /// "done" more often than "never mind".
    func endRename(keeping: Bool) {
        guard let project, project.renaming != nil else { return }
        let original = project.renaming.flatMap { $0.split(separator: "/").last }.map(String.init)
        if keeping, project.renameText != original {
            commitRename()
            if project.renaming == nil { return }
        }
        project.renaming = nil
        project.treeFocused = true
        if let made = project.creating {
            project.creating = nil
            if !keeping { discardIfEmpty(made) }
        }
    }

    /// Takes back what New File or New Folder made, if nothing has been put
    /// in it since. Removed outright rather than trashed: an empty file
    /// that existed for two seconds is not something anyone wants back.
    private func discardIfEmpty(_ path: String) {
        guard let project else { return }
        let url = project.tree.url(of: path)
        let removed: Bool
        if Self.isDirectory(url) {
            removed = rmdir(url.path) == 0
        } else {
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? -1
            removed = size == 0 && unlink(url.path) == 0
        }
        if removed { project.removed(path) }
    }

    /// Moves the selected row to the Trash (Delete). The Trash is the undo,
    /// so it is not asked about first — the way a file manager does it.
    /// Unmodified tabs on what went are closed; a tab with edits stays, and
    /// saving it puts the file back.
    func trashSelected() {
        guard let project, let path = project.selected, !path.isEmpty else { return }
        let url = project.tree.url(of: path).standardizedFileURL
        do {
            try TrashCan().trash(url.path)
        } catch {
            notice = "Could not move \(url.lastPathComponent) to the Trash: \(Self.describe(error))"
            return
        }
        let ids = documents.filter { document in
            guard !document.isModified, let file = document.url?.standardizedFileURL else { return false }
            return file == url || file.path.hasPrefix(url.path + "/")
        }.map(\.id)
        for id in ids {
            if let index = documents.firstIndex(where: { $0.id == id }) { close(index) }
        }
        project.removed(path)
        project.refreshStatus()
        notice = "Moved \(url.lastPathComponent) to the Trash"
    }

    private static func describe(_ error: Error) -> String {
        (error as? FileAccessError)?.message ?? error.localizedDescription
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
        if project == nil {
            openFolderDialog()
            guard project != nil else { return }
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
            if showsSidebar, sidebarView == .agents { startAgentsPolling() }
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
