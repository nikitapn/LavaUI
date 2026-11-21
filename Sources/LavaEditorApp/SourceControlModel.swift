import Foundation
import LavaExplorerCore
import LavaGitCore
import LavaProjectCore
import LavaUI
import Observation

/// What the Source Control panel holds between frames: the message being
/// written, what is running, what went wrong, and which row the pointer is on.
/// The list itself is not kept — it is `ProjectSession.changes`, regrouped
/// whenever the body is built.
@Observable
final class SourceControlModel {
    var message = ""
    /// A git command is running. One at a time: a stage racing a commit
    /// would commit whichever happened to land first.
    var busy = false
    var error: String?
    /// The last commit made from here, shown until the next action.
    var committed: String?
    var collapsed: Set<SourceControlList.Group> = []
    /// Asked before it happens: discarding is the one action here that loses
    /// work.
    var pendingDiscard: SourceControlList.Item?
    var hovered: String?
    /// The row last clicked. Its buttons stay up as VS Code keeps them on the
    /// selected row — the pointer can then leave it, and a click that opened
    /// a diff leaves the stage / discard buttons where the user is looking.
    var selected: String?
    @ObservationIgnored let scroll = ScrollPosition()
}

/// The panel's actions. Every git call runs on a worker — a commit runs the
/// repository's hooks, which can take seconds — and reports back through
/// `MainQueue`.
extension EditorSession {
    func stage(_ items: [SourceControlList.Item]) {
        let paths = items.flatMap(\.paths)
        runGit { try $0.stage(paths) }
    }

    func unstage(_ items: [SourceControlList.Item]) {
        let paths = items.flatMap(\.paths)
        runGit { try $0.unstage(paths) }
    }

    /// Asks first; `confirmDiscard` does it.
    func requestDiscard(_ item: SourceControlList.Item) {
        project?.sourceControl.pendingDiscard = item
    }

    /// Puts an edited file back as the index has it, or — for a file git does
    /// not track — moves it to the Trash rather than deleting it, so that a
    /// wrong click can still be undone from the file manager.
    func confirmDiscard() {
        guard let project, let repository = project.repository,
              let item = project.sourceControl.pendingDiscard else { return }
        project.sourceControl.pendingDiscard = nil
        let url = repository.root.appendingPathComponent(item.path)
        if item.isUntracked {
            do {
                try TrashCan().trash(url.path)
            } catch {
                project.sourceControl.error = "Could not move \(item.name) to the Trash: \(error.localizedDescription)"
                return
            }
            closeUntouched(url)
            project.refreshStatus()
            return
        }
        runGit(then: { [weak self] in self?.reloadUntouched(url) }) {
            try $0.discard([item.path])
        }
    }

    /// Commits what is staged, or everything when nothing is.
    func commit() {
        guard let project else { return }
        let model = project.sourceControl
        let message = model.message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            model.error = "Write a commit message first."
            return
        }
        let list = SourceControlList(project.changes)
        guard list.conflicts.isEmpty else {
            model.error = "Resolve the merge conflicts before committing."
            return
        }
        guard !list.isClean else {
            model.error = "There is nothing to commit."
            return
        }
        // Unsaved edits would not be in the commit, and the user is looking
        // at them; saying so beats a commit of the files as they were.
        if documents.contains(where: { $0.isModified && $0.url.map(project.contains) == true }) {
            model.error = "Save your changes first — unsaved edits are not in a commit."
            return
        }
        let all = list.staged.isEmpty
        runGit(then: { model.message = "" }, report: true) {
            try $0.commit(message: message, all: all)
        }
    }

    /// Runs `work` against the repository on a worker, then refreshes the
    /// status. `report` shows what `work` returned as the last commit.
    private func runGit(
        then done: (() -> Void)? = nil, report: Bool = false,
        _ work: @escaping @Sendable (GitRepository) throws -> Any?
    ) {
        guard let project, let repository = project.repository else { return }
        let model = project.sourceControl
        guard !model.busy else { return }
        model.busy = true
        model.error = nil
        model.committed = nil
        let owner = ProjectRef(project: project)
        let finish = SendableBox(done)
        DispatchQueue.global(qos: .userInitiated).async {
            var failure: String?
            var result: String?
            do {
                result = try work(repository) as? String
            } catch {
                failure = "\(error)"
            }
            let failed = failure, summary = result
            MainQueue.async {
                let project = owner.project
                let model = project.sourceControl
                model.busy = false
                if let failed {
                    model.error = failed
                } else {
                    if report { model.committed = summary }
                    finish.value?()
                }
                project.refreshStatus()
            }
        }
    }

    /// A document showing a file whose contents were just put back: reloaded
    /// if it has no edits of its own, so the editor is not left showing what
    /// was discarded.
    private func reloadUntouched(_ url: URL) {
        let target = url.standardizedFileURL
        for index in documents.indices
        where documents[index].url?.standardizedFileURL == target && !documents[index].isModified {
            if documents[index].isLoaded { _ = documents[index].load() }
            refreshBaseline(index)
            if index == activeIndex { controller.restore(documents[index].position ?? .start) }
        }
    }

    /// A tab on a file that was just moved to the Trash: closed, unless it has
    /// edits — those are the user's, and saving them brings the file back.
    private func closeUntouched(_ url: URL) {
        let target = url.standardizedFileURL
        if let index = documents.firstIndex(where: {
            $0.url?.standardizedFileURL == target && !$0.isModified
        }) {
            close(index)
        }
    }
}

extension ProjectSession {
    /// Whether `url` is inside this project's folder.
    func contains(_ url: URL) -> Bool { tree.path(of: url) != nil }
}

/// A closure carried to a worker and back, only called on the main thread.
struct SendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
