import Foundation
import LavaProjectCore
import LavaUI

extension EditorSession {
    func showProjectSearch() {
        showSidebar(.search)
        if sidebarView == .search { projectSearch.queryFocused = true }
    }

    /// The documents whose unsaved text project search reads instead of their
    /// files: modified, loaded, inside the project at `root`, and not ignored
    /// by git — the walk skips ignored files, so a buffer must not bring one in.
    func searchBuffers(under root: URL) -> [ProjectSearchBuffer] {
        guard let project, project.tree.root == root else { return [] }
        return documents.compactMap { document in
            guard document.isModified, document.isLoaded, let url = document.url,
                  let path = project.tree.path(of: url), !path.isEmpty else { return nil }
            let node = ProjectNode(name: url.lastPathComponent, path: path, isDirectory: false)
            guard project.decorations.mark(for: node) != .ignored else { return nil }
            return ProjectSearchBuffer(path: path, text: document.text)
        }
    }

    func openProjectMatch(_ url: URL, line: ProjectSearchLine, match: Int) {
        open([url])
        guard active.isLoaded else { return }
        guard let range = line.selection(in: active.text, match: match) else {
            notice = "This line has changed. Run the search again to refresh the results."
            return
        }
        if visibleDiff != nil { closeDiff() }

        let destination = active.id
        let position = EditorPosition(anchor: range.lowerBound, focus: range.upperBound,
                                      topOffset: range.lowerBound)
        documents[activeIndex].position = position
        controller.restore(position)
        // The controller still points at the outgoing buffer until the next
        // frame. After layout it can also reveal the match horizontally.
        FrameTasks.after { [weak self] in
            guard let self, active.id == destination else { return }
            controller.reveal(range: range)
            controller.focus()
        }
    }
}
