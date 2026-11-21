import Foundation
import LavaProjectCore
import LavaUI

enum RecentProjectKind: CaseIterable {
    case folder, workspace

    var settingsKey: String {
        switch self {
        case .folder: "recentFolders"
        case .workspace: "recentWorkspaces"
        }
    }
}

struct WorkspaceOpening {
    let url: URL
    let snapshot: EditorSessionSnapshot
}

extension EditorSession {
    var workspaceName: String? { workspaceURL?.deletingPathExtension().lastPathComponent }

    func visibleRecentPaths(_ kind: RecentProjectKind) -> [String] {
        (recentProjectPaths[kind] ?? []).filter { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                && isDirectory.boolValue == (kind == .folder)
        }
    }

    func clearRecentProjectPaths(_ kind: RecentProjectKind) {
        let empty: [String] = []
        AppSettings.set(empty, forKey: kind.settingsKey)
        recentProjectPaths[kind] = empty
    }

    func rememberProjectPath(_ url: URL, kind: RecentProjectKind) {
        var updated: [String] = []
        AppSettings.update([String].self, forKey: kind.settingsKey) { stored in
            updated = RecentProjectPaths.recording(url, in: stored ?? [])
            return updated
        }
        recentProjectPaths[kind] = updated
    }

    private static var workspaceFilters: [FileDialog.Filter] {
        [.init(name: "Lava Workspaces", extensions: [EditorWorkspace.pathExtension])]
    }

    func saveWorkspaceAs() {
        let name = workspaceName ?? project?.name ?? "Workspace"
        guard let chosen = FileDialog.saveFile(
            title: "Save Workspace As", filters: Self.workspaceFilters,
            defaultName: "\(name).\(EditorWorkspace.pathExtension)"
        ) else { return }
        let url = chosen.pathExtension.lowercased() == EditorWorkspace.pathExtension
            ? chosen.standardizedFileURL
            : chosen.appendingPathExtension(EditorWorkspace.pathExtension).standardizedFileURL

        // Check the final filename as the picker only confirms overwrites
        // against the name it returns, before we append the extension.
        if url.path != chosen.standardizedFileURL.path,
           FileManager.default.fileExists(atPath: url.path) {
            notice = "\(url.lastPathComponent) already exists. Choose its full filename to replace it."
            return
        }
        flushOutgoingSession()
        var snapshot = sessionSnapshot()
        snapshot.showsSidebar = showsSidebar
        snapshot.sidebarFraction = sidebarFraction
        do {
            try SessionPersistence.writeWorkspace(snapshot, to: url)
        } catch {
            notice = "Could not save \(url.lastPathComponent): \(error.localizedDescription)"
            return
        }
        workspaceURL = url
        SessionPersistence.shared.adoptWorkspace(snapshot, at: url)
        rememberProjectPath(url, kind: .workspace)
        notice = "Saved workspace \(url.deletingPathExtension().lastPathComponent)"
    }

    func openWorkspaceDialog() {
        guard pendingWorkspace == nil,
              let url = FileDialog.openFile(title: "Open Workspace", filters: Self.workspaceFilters)
        else { return }
        openWorkspace(url)
    }

    func openWorkspace(_ chosen: URL) {
        guard pendingWorkspace == nil else { return }
        let url = chosen.standardizedFileURL
        if workspaceURL == url {
            rememberProjectPath(url, kind: .workspace)
            return
        }
        do {
            let snapshot = try EditorWorkspace.decode(Data(contentsOf: url), at: url)
            let opening = WorkspaceOpening(url: url, snapshot: snapshot)
            if hasUnsavedWork {
                pendingWorkspace = opening
            } else {
                replaceWithWorkspace(opening)
            }
        } catch {
            notice = "Could not open \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func resolveWorkspaceOpening(save shouldSave: Bool) {
        guard let opening = pendingWorkspace else { return }
        pendingWorkspace = nil
        if shouldSave {
            for index in documents.indices where documents[index].isModified {
                guard saveDocument(index) else { return }
            }
        }
        replaceWithWorkspace(opening)
    }

    private func replaceWithWorkspace(_ opening: WorkspaceOpening) {
        flushOutgoingSession()
        notice = nil
        pendingClose = nil
        find = FindState()
        findQueryFocused = false
        gotoOpen = false
        gotoFocused = false
        closeDiff()
        gitBaselines.removeAll()
        tabDrag = nil
        tabScroll.scrollToTop()

        workspaceURL = opening.url
        applySession(opening.snapshot, revealActive: false)
        SessionPersistence.shared.adoptWorkspace(sessionSnapshot(useLivePosition: false), at: opening.url)
        if let root = project?.tree.root { rememberProjectPath(root, kind: .folder) }
        rememberProjectPath(opening.url, kind: .workspace)
    }

    private func flushOutgoingSession() {
        // On a command-line workspace launch there is no outgoing frame.
        // Preserve the implicit session exactly as it was on disk.
        if hasCheckpointed { checkpointSession() }
        SessionPersistence.shared.flush()
    }
}
