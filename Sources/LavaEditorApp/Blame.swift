import Foundation
import LavaDiffCore
import LavaExplorerCore
import LavaGitCore
import LavaUI
import Observation

struct BlameKey: Hashable, Sendable {
    let path: URL
    let head: String
}

/// Commit metadata is shared across files, but the libgit2 operations stay on
/// the worker. A result is published only if its request still owns the key.
private final class BlameWorker: @unchecked Sendable {
    let queue = DispatchQueue(label: "lavaeditor.blame", qos: .userInitiated)
    var commits: [String: GitBlameCommit] = [:]
}

/// Mutated on the frame loop. Workers only return values through MainQueue.
@Observable
final class BlameState: @unchecked Sendable {
    static let settingsKey = "inlineBlame"

    struct Card {
        let document: Int
        let revision: Int
        let line: Int
        let scroll: CGPoint
        let commit: GitBlameCommit
        let author: String
        let now: Date
    }

    var enabled = AppSettings.bool(forKey: settingsKey) ?? false
    var card: Card?
    let anchor = EditorLineEndHintAnchor()
    let cardEditor = EditorController()

    @ObservationIgnored private var files: [BlameKey: GitBlame?] = [:]
    @ObservationIgnored private var requests: [BlameKey: UUID] = [:]
    @ObservationIgnored private let worker = BlameWorker()
    @ObservationIgnored private var overHint = false
    @ObservationIgnored private var overCard = false
    @ObservationIgnored private var deadline: Double?
    @ObservationIgnored private var watchedFile: URL?

    func attribution(_ key: BlameKey, repository: GitRepository) -> GitBlame? {
        if let cached = files[key] { return cached }
        guard requests[key] == nil else { return nil }
        let request = UUID()
        requests[key] = request
        let worker = self.worker
        worker.queue.async { [weak self] in
            let result = try? repository.blame(key.path, at: key.head, commits: &worker.commits)
            MainQueue.async { [weak self] in
                guard let self, self.requests[key] == request else { return }
                self.requests[key] = nil
                self.files[key] = .some(result)
                ViewInvalidation.markNeedsBody()
            }
        }
        return nil
    }

    /// Says when HEAD of the repository holding `file` moves — a commit,
    /// checkout or reset in a terminal — so the blame on screen is redone.
    /// Event-driven: inotify on the folders git writes when HEAD moves
    /// (`GitRepository.headFolders`), and HEAD is read only after one of them
    /// changed. Standalone files and linked worktrees have no project watcher
    /// of their own, which is why this exists; it used to read HEAD every 3
    /// seconds, waking the loop for as long as blame was on.
    func watchHead(of file: URL?, onRead: @escaping (GitHead?) -> Void) {
        guard file != watchedFile else { return }
        watchedFile = file
        headWatch?.stop()
        headWatch = file.map { HeadWatch(file: $0, onRead: onRead) }
    }

    @ObservationIgnored private var headWatch: HeadWatch?

    /// One file's watch. Its handler runs on the watcher's thread, reads HEAD
    /// there — a few file reads through libgit2 — and hands the answer to the
    /// frame loop; a watch replaced meanwhile says nothing.
    private final class HeadWatch: @unchecked Sendable {
        private let file: URL
        private let onRead: (GitHead?) -> Void
        private var watcher: FolderWatcher?
        private var stopped = false
        private let lock = NSLock()

        init(file: URL, onRead: @escaping (GitHead?) -> Void) {
            self.file = file
            self.onRead = onRead
            // `index` is rewritten by every `git status`, in the folder HEAD
            // lives in, so changes come in bursts; one read per burst.
            watcher = FolderWatcher(quiet: 0.2, patience: 1.0) { [weak self] _ in self?.changed() }
            DispatchQueue.global(qos: .utility).async { [weak self] in self?.rewatch() }
        }

        func stop() {
            lock.withLock { stopped = true }
            watcher?.stop()
        }

        /// The folders to watch now: a checkout may have moved HEAD to a
        /// branch whose file is somewhere else.
        private func rewatch() {
            guard let repository = GitRepository.containing(file),
                  let folders = try? repository.headFolders() else { return }
            watcher?.watch(folders)
        }

        private func changed() {
            guard !lock.withLock({ stopped }) else { return }
            rewatch()
            let head = GitHead.read(containing: file)
            let ref = HeadWatchRef(self)
            MainQueue.async {
                guard let watch = ref.watch, !watch.lock.withLock({ watch.stopped }) else { return }
                watch.onRead(head)
            }
        }
    }

    private final class HeadWatchRef: @unchecked Sendable {
        weak var watch: HeadWatch?
        init(_ watch: HeadWatch) { self.watch = watch }
    }

    func invalidate(path: URL? = nil) {
        if let path {
            let path = path.standardizedFileURL
            files = files.filter { $0.key.path != path }
            requests = requests.filter { $0.key.path != path }
        } else {
            files.removeAll()
            requests.removeAll()
        }
    }

    func hoverHint(_ inside: Bool) {
        overHint = inside
        updateDeadline()
    }

    func hoverCard(_ inside: Bool) {
        guard card != nil else { return }
        overCard = inside
        updateDeadline()
    }

    private func updateDeadline() {
        if card == nil, overHint {
            schedule(after: 0.3)
        } else if card != nil, !overHint, !overCard {
            schedule(after: 0.15)
        } else {
            deadline = nil
        }
    }

    private func schedule(after delay: Double) {
        guard deadline == nil else { return }
        deadline = FrameScheduler.now() + delay
        FrameScheduler.requestRedraw(in: delay)
    }

    func clearHover() {
        deadline = nil
        overHint = false
        overCard = false
    }

    func tick(valid: Bool, open: @escaping () -> Void, dismiss: @escaping () -> Void) {
        if card != nil, !valid {
            FrameTasks.after(dismiss)
            return
        }
        guard let deadline else { return }
        let remaining = deadline - FrameScheduler.now()
        if remaining > 0 {
            FrameScheduler.requestRedraw(in: remaining)
            return
        }
        self.deadline = nil
        if card != nil { FrameTasks.after(dismiss) }
        else if valid, overHint { FrameTasks.after(open) }
    }
}

extension EditorSession {
    func toggleInlineBlame() {
        blame.enabled.toggle()
        AppSettings.set(blame.enabled, forKey: BlameState.settingsKey)
        if !blame.enabled { dismissBlameCard() }
    }

    private var canShowBlame: Bool {
        blame.enabled && active.isLoaded && active.preview == nil && active.tabState != .preview
            && visibleDiff == nil
    }

    func watchBlameHead() {
        let file = canShowBlame ? active.url : nil
        blame.watchHead(of: file) { [weak self] head in
            guard let self, self.active.url == file, self.canShowBlame,
                  self.baselineRequests[self.active.id] == nil,
                  self.baselineHeads[self.active.id] != head else { return }
            self.dismissBlameCard()
            self.refreshBaseline(self.activeIndex)
        }
    }

    private func blameLookup() -> (attribution: GitBlame, hunks: [DiffHunk])? {
        guard canShowBlame, let url = active.url, baselineRequests[active.id] == nil,
              let base = gitBaselines[active.id], let attribution = blame.attribution(.init(path: url.standardizedFileURL, head: base.head.oid),
                                                  repository: base.head.repository)
        else { return nil }
        return (attribution, baselineHunks(for: active.id, text: active.text, baseline: base))
    }

    func inlineBlameHint() -> EditorLineEndHint? {
        guard let (attribution, hunks) = blameLookup() else { return nil }
        return EditorLineEndHint(anchor: blame.anchor, text: { line in
            guard let old = TextDiff.unchangedOldLine(forNew: line, hunks: hunks),
                  let commit = attribution[old] else { return nil }
            return commit.hint(userEmail: attribution.userEmail, now: Date())
        }, onHover: { [blame] inside in blame.hoverHint(inside) })
    }

    var isBlameCardVisible: Bool {
        guard let card = blame.card, canShowBlame else { return false }
        return card.document == active.id && card.revision == revision
            && card.line == blame.anchor.line && card.scroll == blame.anchor.scroll
            && blame.anchor.frame != nil
    }

    func tickBlame() {
        let valid = blame.card == nil
            ? canShowBlame && blame.anchor.frame != nil
            : isBlameCardVisible
        blame.tick(valid: valid, open: { [weak self] in self?.openBlameCard() },
                   dismiss: { [weak self] in self?.dismissBlameCard() })
    }

    private func openBlameCard() {
        let pointer = PointerState.window
        guard let line = blame.anchor.line, let frame = blame.anchor.frame,
              frame.contains(CGPoint(x: CGFloat(pointer.x), y: CGFloat(pointer.y))),
              let (attribution, hunks) = blameLookup(),
              let old = TextDiff.unchangedOldLine(forNew: line, hunks: hunks),
              let commit = attribution[old] else { return }
        blame.card = BlameState.Card(document: active.id, revision: revision, line: line,
                                     scroll: blame.anchor.scroll, commit: commit,
                                     author: commit.authorLabel(userEmail: attribution.userEmail), now: Date())
    }

    func dismissBlameCard() {
        if blame.card != nil {
            if blame.cardEditor.isFocused { controller.focus() }
            blame.card = nil
        }
        blame.clearHover()
    }

    /// A focused read-only card can still copy and navigate its message.
    /// Editing keys go back to the document it was opened from.
    func handleBlameKey(_ event: InputEvent) -> Bool {
        guard blame.card != nil, event.x > 0 else { return false }
        if event.button == KeyCode.escape {
            dismissBlameCard()
            LavaApp.suppressRawKeyText()
            return true
        }
        let modifiers = Int32(event.y)
        let editingKey = [KeyCode.backspace, KeyCode.delete, KeyCode.enter, KeyCode.tab].contains(event.button)
        let printable = (32...96).contains(event.button)
            && modifiers & (KeyMods.control | KeyMods.alt | KeyMods.superKey) == 0
        let paste = event.button == KeyCode.v && modifiers & KeyMods.control != 0
        if printable || editingKey || paste { dismissBlameCard() }
        return false
    }
}
