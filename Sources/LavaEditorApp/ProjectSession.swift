import Foundation
import LavaExplorerCore
import LavaGitCore
import LavaProjectCore
import LavaUI
import Observation

/// The folder the editor has open: its tree, what git says about each row,
/// and a watcher that keeps both true without anyone pressing refresh.
///
/// Listing a folder happens on the frame loop — it is one `readdir`, and the
/// row should open in the same frame as the click. Git happens on a worker:
/// `status` over a large checkout is tens of milliseconds, and it re-runs
/// whenever anything changes.
@Observable
final class ProjectSession {
    private(set) var tree: ProjectTree
    /// `tree.rows`, kept rather than recomputed per body: the walk is the
    /// whole visible tree, and the body is rebuilt on every keystroke.
    private(set) var rows: [ProjectRow] = []
    private(set) var decorations = GitDecorations()
    private(set) var branch: String?
    /// What git reports as changed — staged, unstaged, untracked, in
    /// conflict; never ignored. Paths are the repository's, not the tree's.
    private(set) var changes: [GitStatusEntry] = []
    /// The row the keyboard and the highlight are on.
    var selected: String?

    @ObservationIgnored private(set) var repository: GitRepository?
    /// `repository != nil`, observed: the repository is found on a worker
    /// after the tree is up, and a view that asked before then has to hear.
    private(set) var isInRepository = false
    /// Where the project sits relative to its repository; see `GitDecorations`.
    @ObservationIgnored private var repositoryPath: String? = ""
    @ObservationIgnored private var projectPath = ""
    @ObservationIgnored private var watcher: FolderWatcher?
    @ObservationIgnored private var statusRunning = false
    @ObservationIgnored private var statusAgain = false
    /// Told when the repository changed under the editor — a commit, a
    /// checkout — so the gutter's copy of HEAD can be fetched again.
    @ObservationIgnored var onRepositoryChanged: (() -> Void)?
    @ObservationIgnored let scroll = ScrollPosition()
    /// The tree's visible height, from layout: what a page is, and what
    /// "in sight" means for a row the keyboard moved to.
    @ObservationIgnored var viewportHeight: Float = 0
    /// The Source Control panel's own state. See `SourceControlModel`.
    let sourceControl = SourceControlModel()

    var name: String { tree.root.lastPathComponent }

    init(root: URL, expanded: Set<String> = []) {
        tree = ProjectTree(root: root)
        tree.restore(expanded: expanded)
        rows = tree.rows
        let owner = ProjectRef(project: self)
        watcher = FolderWatcher { changed in
            MainQueue.async { owner.project.foldersChanged(changed) }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let repository = GitRepository.containing(root)
            MainQueue.async {
                owner.project.adopt(repository)
            }
        }
        rewatch()
    }

    deinit { watcher?.stop() }

    func close() { watcher?.stop() }

    // MARK: - The tree

    func toggle(_ path: String) {
        tree.toggle(path)
        changed()
    }

    /// Carries out what a key worked out (`ProjectTree.step`), keeping a
    /// newly selected row in sight.
    func apply(_ step: ProjectTreeStep, rowHeight: Float) {
        switch step {
        case .none:
            return
        case .select(let path):
            selected = path
            keepInSight(path, rowHeight: rowHeight)
        case .expand(let path):
            tree.setExpanded(path, true)
            changed()
        case .collapse(let path):
            tree.setExpanded(path, false)
            changed()
        }
    }

    /// Scrolls only as far as it takes, the way a list follows its keyboard:
    /// a row above the view comes in at the top, one below at the bottom.
    /// Through the scroll position, not `scrollIntoView`: the rows are lazy,
    /// and a row past the end of the view has no node to ask.
    private func keepInSight(_ path: String, rowHeight: Float) {
        guard viewportHeight > 0, let index = rows.firstIndex(where: { $0.node.path == path })
        else { return }
        let top = Float(index) * rowHeight
        if top < scroll.offset {
            scroll.scroll(to: top)
        } else if top + rowHeight > scroll.offset + viewportHeight {
            scroll.scroll(to: top + rowHeight - viewportHeight)
        }
    }

    /// Opens the folders above a file and selects it — what following the
    /// document in front looks like.
    func reveal(_ url: URL) {
        guard let path = tree.path(of: url), !path.isEmpty else { return }
        if selected == path, rows.contains(where: { $0.node.path == path }) { return }
        tree.reveal(path)
        selected = path
        changed()
    }

    private func changed() {
        rows = tree.rows
        rewatch()
    }

    private func rewatch() {
        var paths = Set(tree.visibleFolders.map { tree.url(of: $0).path })
        if let gitDirectory { paths.insert(gitDirectory) }
        watcher?.watch(paths)
    }

    /// `.git`, when it is a folder: watching it is how a commit made in a
    /// terminal reaches the editor. A worktree's `.git` is a file pointing
    /// elsewhere, and goes unwatched — status still refreshes on any change
    /// to the files themselves.
    private var gitDirectory: String? {
        guard let repository else { return nil }
        let dir = repository.root.appendingPathComponent(".git").path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return dir
    }

    private func foldersChanged(_ changed: Set<String>) {
        var any = false
        var gitChanged = false
        let gitPrefix = gitDirectory
        for folder in changed {
            if let gitPrefix, folder == gitPrefix || folder.hasPrefix(gitPrefix + "/") {
                gitChanged = true
                continue
            }
            guard let path = tree.path(of: URL(fileURLWithPath: folder)) else { continue }
            if tree.reload(path) { any = true }
        }
        if any { self.changed() }
        // A file saved changes its status whether or not the listing moved.
        refreshStatus()
        if gitChanged { onRepositoryChanged?() }
    }

    /// Re-reads everything visible. For a menu command — the watcher does
    /// this on its own for anything it can see.
    func refresh() {
        for folder in tree.visibleFolders { tree.reload(folder) }
        changed()
        refreshStatus()
    }

    // MARK: - Git

    private func adopt(_ repository: GitRepository?) {
        self.repository = repository
        isInRepository = repository != nil
        guard let repository else { return }
        let top = repository.root.resolvingSymlinksInPath().path
        let mine = tree.root.resolvingSymlinksInPath().path
        if mine == top {
            repositoryPath = ""
        } else if mine.hasPrefix(top + "/") {
            repositoryPath = nil
            projectPath = String(mine.dropFirst(top.count + 1))
        } else if top.hasPrefix(mine + "/") {
            repositoryPath = String(top.dropFirst(mine.count + 1))
        }
        rewatch()
        refreshStatus()
    }

    /// Asks git again, on a worker. Calls that arrive while one is running
    /// collapse into a single run after it: a build writing a hundred files
    /// is one more status, not a hundred queued.
    func refreshStatus() {
        guard let repository else { return }
        if statusRunning {
            statusAgain = true
            return
        }
        statusRunning = true
        let owner = ProjectRef(project: self)
        let repositoryPath = self.repositoryPath
        let projectPath = self.projectPath
        DispatchQueue.global(qos: .utility).async {
            let entries = (try? repository.status(ignored: true)) ?? []
            let changes = entries.filter { $0.kind != .ignored }
            let branch = try? repository.branch()
            let decorations = GitDecorations(
                entries: entries, repositoryPath: repositoryPath, projectPath: projectPath
            )
            MainQueue.async {
                let project = owner.project
                project.statusRunning = false
                if project.decorations != decorations { project.decorations = decorations }
                if project.branch != branch { project.branch = branch }
                if project.changes != changes { project.changes = changes }
                if project.statusAgain {
                    project.statusAgain = false
                    project.refreshStatus()
                }
            }
        }
    }
}

/// Carried to a worker and back; only dereferenced inside `MainQueue.async`.
struct ProjectRef: @unchecked Sendable {
    let project: ProjectSession
}
