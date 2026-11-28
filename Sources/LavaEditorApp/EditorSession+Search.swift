import Foundation
import LavaProjectCore
import LavaText
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

    /// Every place a word is written: a whole-word, case-sensitive project
    /// search. What Ctrl+click does when no language server can say where the
    /// word is defined.
    func searchForWord(at offset: Int) {
        let text = active.text
        guard let project, offset >= 0, offset < text.count else { return }
        let index = text.index(text.startIndex, offsetBy: offset)
        let state = TextEditingState(text)
        let word = String(text[state.wordRange(at: index)])
        guard let first = word.first, TextEditingState.isWordCharacter(first) else { return }
        var options = ProjectSearchOptions()
        options.query = word
        options.wholeWord = true
        options.caseSensitive = true
        showSidebar(.search)
        projectSearch.search(root: project.tree.root, options: options, immediate: true)
    }

    /// Shows a match in the preview tab, selected. `focus` hands the keyboard
    /// to it — a click, Enter — and is off while the results are walked with
    /// the arrows, which keep it.
    func openProjectMatch(_ url: URL, line: ProjectSearchLine, match: Int, focus: Bool = true) {
        open([url], mode: .preview)
        guard active.isLoaded, active.url?.standardizedFileURL == url.standardizedFileURL else { return }
        guard let range = line.selection(in: active.text, match: match) else {
            notice = "This line has changed. Run the search again to refresh the results."
            return
        }
        select(range, focus: focus)
    }

    /// Selects `range` in the document in front and scrolls it into view.
    func select(_ range: Range<Int>, focus: Bool = true) {
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
            if focus { controller.focus() }
        }
    }
}
