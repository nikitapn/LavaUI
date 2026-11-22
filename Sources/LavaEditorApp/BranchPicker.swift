import Foundation
import LavaGitCore
import LavaUI
import Observation

/// What the branch picker shows: this repository's working trees and its
/// local branches, filtered by what has been typed.
///
/// Fetched once when it opens, on a worker — a branch list with
/// ahead/behind counts walks history for each branch that has an upstream,
/// and that is not frame-loop work.
@Observable
final class BranchPicker {
    enum Row: Equatable {
        case heading(String)
        /// `current` when the editor has this tree open.
        case worktree(GitWorktree, current: Bool)
        /// `elsewhere` is the other working tree that has it checked out:
        /// choosing such a branch goes to that tree rather than failing.
        case branch(GitBranch, elsewhere: GitWorktree?)

        var isChoice: Bool {
            if case .heading = self { return false }
            return true
        }
    }

    /// The working tree the editor has open.
    let root: URL
    var query = "" {
        didSet {
            guard query != oldValue else { return }
            selection = firstMove
            error = nil
        }
    }
    private(set) var worktrees: [GitWorktree] = []
    private(set) var branches: [GitBranch] = []
    private(set) var loading = true
    var error: String?
    /// Index into `choices`.
    var selection = 0
    var searchFocused = true

    init(root: URL) {
        self.root = root.standardizedFileURL
    }

    func adopt(worktrees: [GitWorktree], branches: [GitBranch]) {
        self.worktrees = worktrees
        self.branches = branches
        loading = false
        selection = firstMove
    }

    /// The first row that goes somewhere: the tree and the branch already
    /// open are listed for orientation, and Enter on them would do nothing.
    private var firstMove: Int {
        choices.firstIndex { row in
            switch row {
            case .worktree(_, let current): return !current
            case .branch(let branch, _): return !branch.isHead
            case .heading: return false
            }
        } ?? 0
    }

    func isCurrent(_ worktree: GitWorktree) -> Bool {
        Self.samePath(worktree.root, root)
    }

    var rows: [Row] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        func matches(_ strings: String?...) -> Bool {
            needle.isEmpty || strings.contains { $0?.lowercased().contains(needle) == true }
        }
        var out: [Row] = []
        // One tree is no choice at all, and a heading over it is noise.
        if worktrees.count > 1 {
            let trees = worktrees.filter { matches($0.name, $0.branch, $0.root.path) }
            if !trees.isEmpty {
                out.append(.heading("Worktrees"))
                out += trees.map { .worktree($0, current: isCurrent($0)) }
            }
        }
        let current = worktrees.first(where: isCurrent)
        let picked = branches.filter { matches($0.name) }
        if !picked.isEmpty {
            out.append(.heading("Branches"))
            out += picked.map { branch in
                let holder = worktrees.first { $0.branch == branch.name && !Self.samePath($0.root, current?.root ?? root) }
                return .branch(branch, elsewhere: holder)
            }
        }
        return out
    }

    var choices: [Row] { rows.filter(\.isChoice) }

    var selected: Row? {
        let choices = self.choices
        return choices.indices.contains(selection) ? choices[selection] : nil
    }

    func move(by delta: Int) {
        let count = choices.count
        guard count > 0 else { return }
        selection = (selection + delta + count) % count
    }

    static func samePath(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.resolvingSymlinksInPath().path == b.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

extension EditorSession {
    /// Git → Switch Branch or Worktree…, and a click on the branch chip.
    func openBranchPicker() {
        guard let project, let repository = project.repository else {
            notice = project == nil ? "Open a folder in a git repository first." : "This folder is not in a git repository."
            return
        }
        let picker = BranchPicker(root: repository.root)
        branchPicker = picker
        let owner = SessionRef(session: self)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { (try repository.worktrees(), try repository.branches()) }
            MainQueue.async {
                // Closed, or closed and opened again, while this was read.
                guard let picker = owner.session.branchPicker, picker.root == repository.root else { return }
                switch result {
                case .success(let (worktrees, branches)): picker.adopt(worktrees: worktrees, branches: branches)
                case .failure(let error):
                    picker.adopt(worktrees: [], branches: [])
                    picker.error = "\(error)"
                }
            }
        }
    }

    func closeBranchPicker() {
        branchPicker = nil
        controller.focus()
    }

    func choose(_ row: BranchPicker.Row) {
        switch row {
        case .heading: return
        case .worktree(let worktree, let current):
            closeBranchPicker()
            if !current { switchToWorktree(worktree) }
        case .branch(let branch, let elsewhere):
            if let elsewhere {
                closeBranchPicker()
                switchToWorktree(elsewhere)
            } else if branch.isHead {
                closeBranchPicker()
            } else {
                checkout(branch.name)
            }
        }
    }

    // MARK: - Another working tree

    /// Opens `worktree` in place of the folder's tree. No checkout happens,
    /// so this is instant and touches no file.
    ///
    /// Tabs come along: an unmodified file from the tree being left is
    /// replaced by the same path in the new one — which is the point when
    /// looking at what an agent changed — and closed when the new tree has
    /// no such file. A tab with unsaved edits stays exactly as it was, on its
    /// own tree's file; its path in the tab says which.
    func switchToWorktree(_ worktree: GitWorktree) {
        guard let project, let repository = project.repository else { return }
        let oldTop = repository.root
        let newTop = worktree.root
        // The folder may be a part of the repository rather than its top;
        // open the same part of the other tree when it has one.
        var newRoot = newTop
        if let inside = repository.relativePath(of: project.tree.root), !inside.isEmpty {
            let candidate = newTop.appendingPathComponent(inside, isDirectory: true)
            if Self.isDirectory(candidate) { newRoot = candidate }
        }

        stashPosition()
        closeDiff()
        let activeID = active.id
        var replaced: [Int: Int] = [:]
        var closing: Set<Int> = []
        var next: [EditorDocument] = []
        for document in documents {
            guard let url = document.url, !document.isModified, document.preview == nil,
                  let relative = repository.relativePath(of: url), !relative.isEmpty else {
                next.append(document)
                continue
            }
            let target = newTop.appendingPathComponent(relative).standardizedFileURL
            guard FileManager.default.fileExists(atPath: target.path) else {
                closing.insert(document.id)
                continue
            }
            var moved = EditorDocument(id: takeID(), url: target, text: "",
                                       tabState: document.tabState, isLoaded: false)
            moved.position = document.position
            replaced[document.id] = moved.id
            next.append(moved)
        }
        // A preview follows its source, and goes with it.
        let gone = closing.union(replaced.keys)
        next.removeAll { $0.preview.map { gone.contains($0.sourceID) } ?? false }
        for id in gone {
            forgetTab(id)
        }
        if next.isEmpty { next = [EditorDocument(id: takeID(), url: nil, text: "")] }

        let wanted = replaced[activeID] ?? activeID
        documents = next
        activeIndex = documents.firstIndex { $0.id == wanted } ?? min(activeIndex, documents.count - 1)
        controller.restore(documents[activeIndex].position ?? .start)
        loadIfNeeded(activeIndex)

        let expanded = project.tree.expanded.subtracting([""])
        restoreProject(newRoot.path, expanded: expanded)
        followActive()
        let branch = worktree.branch.map { " on \($0)" } ?? ""
        let kept = documents.filter { doc in
            doc.isModified && doc.url.map { repository.relativePath(of: $0) != nil } == true
                && !BranchPicker.samePath(oldTop, newTop)
        }.count
        notice = "Opened worktree \(worktree.name)\(branch)"
            + (kept > 0 ? " · \(kept) modified tab\(kept == 1 ? "" : "s") kept from \(oldTop.lastPathComponent)" : "")
    }

    // MARK: - Another branch in this tree

    /// `git switch <name>` in the open tree. Refused while a file in it has
    /// unsaved edits: the checkout rewrites files on disk, and a buffer saved
    /// over the new branch's copy afterwards would quietly undo the switch
    /// for that file.
    func checkout(_ name: String) {
        guard let picker = branchPicker, let project, let repository = project.repository else { return }
        let unsaved = documents.filter { doc in
            doc.isModified && doc.url.flatMap { repository.relativePath(of: $0) } != nil
        }
        if !unsaved.isEmpty {
            picker.error = "Save or revert \(unsaved.map(\.name).joined(separator: ", ")) before switching branches."
            return
        }
        guard !switchingBranch else { return }
        switchingBranch = true
        picker.error = nil
        let owner = SessionRef(session: self)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try repository.checkout(branch: name) }
            MainQueue.async {
                let session = owner.session
                session.switchingBranch = false
                switch result {
                case .failure(let error):
                    // The picker stays up with the reason: the files it names
                    // are the next thing to look at.
                    if let picker = session.branchPicker { picker.error = "\(error)" }
                    else { session.notice = "\(error)" }
                case .success:
                    session.closeBranchPicker()
                    session.reloadAfterCheckout(repository)
                    session.notice = "Switched to \(name)"
                }
            }
        }
    }

    /// Every unmodified tab of this tree read again — the checkout may have
    /// changed it — and closed when the branch does not have its file.
    private func reloadAfterCheckout(_ repository: GitRepository) {
        stashPosition()
        var vanished: [Int] = []
        for index in documents.indices {
            let document = documents[index]
            guard let url = document.url, !document.isModified, document.preview == nil,
                  repository.relativePath(of: url) != nil else { continue }
            guard FileManager.default.fileExists(atPath: url.path) else {
                vanished.append(document.id)
                continue
            }
            guard document.isLoaded else { continue }
            if let data = try? Data(contentsOf: url), data == Data(document.text.utf8) {
                refreshBaseline(index)
                continue
            }
            _ = documents[index].load()
            if index == activeIndex { controller.restore(documents[index].position ?? .start) }
            refreshBaseline(index)
        }
        for id in vanished {
            if let index = documents.firstIndex(where: { $0.id == id }) { close(index) }
        }
        project?.refresh()
    }
}
