import Foundation
import LavaDiffCore
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
    @ObservationIgnored private var headProbe: DispatchWorkItem?

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

    /// Standalone files and linked worktrees may have no project ref watcher.
    /// Check HEAD without waking the window unless it actually moved.
    func watchHead(of file: URL?, onRead: @escaping (GitHead?) -> Void) {
        guard file != watchedFile else { return }
        headProbe?.cancel()
        headProbe = nil
        watchedFile = file
        currentProbe = nil
        if let file { scheduleHeadProbe(file, onRead: onRead) }
    }

    private func scheduleHeadProbe(_ file: URL, onRead: @escaping (GitHead?) -> Void) {
        let operation = HeadProbe(callback: onRead)
        let work = DispatchWorkItem { [weak self] in
            let head = GitHead.read(containing: file)
            MainQueue.async { [weak self] in
                guard let self, self.currentProbe === operation else { return }
                operation.callback(head)
                self.scheduleHeadProbe(file, onRead: operation.callback)
            }
        }
        currentProbe = operation
        headProbe = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3, execute: work)
    }

    // Carries a callback that is only invoked on the frame loop, and identifies
    // its probe if the user switches away and back before the worker completes.
    private final class HeadProbe: @unchecked Sendable {
        let callback: (GitHead?) -> Void
        init(callback: @escaping (GitHead?) -> Void) { self.callback = callback }
    }

    @ObservationIgnored private var currentProbe: HeadProbe?

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
