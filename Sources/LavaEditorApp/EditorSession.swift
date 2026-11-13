import Foundation
import LavaText
import LavaUI
import Observation

/// What the find bar is doing.
///
/// Separate from the session because it is one coherent thing with its own
/// lifecycle — opened, typed into, closed — and because `TextSearch` holds
/// offsets into a buffer, so everything that can invalidate them wants to be
/// visible in one place.
struct FindState {
    var isOpen = false
    var showsReplace = false
    var query = ""
    var replacement = ""
    var caseSensitive = false
    var search = TextSearch()

    /// Buffer the offsets in `search` were found in. `TextSearch` holds no
    /// reference to the text on purpose, so this is what stops a stale match
    /// from being navigated to after an edit moved it.
    var searchedRevision = 0
}

/// Documents, chrome, and every action the menu can take.
///
/// Menu closures live outside the view tree, so they cannot capture `@State`
/// — those are value copies. An `@Observable` class is the join: the menu
/// mutates the same instance the view reads.
@Observable
final class EditorSession {
    /// Never empty. Closing the last document leaves a fresh empty one rather
    /// than a window with nothing in it, which is what lets `active` be
    /// non-optional everywhere else.
    var documents: [EditorDocument] = []
    var activeIndex = 0

    var find = FindState()
    /// Open, and what the user has typed into it, for `Go to Line`.
    var gotoOpen = false
    var gotoLine = ""

    /// One line under the toolbar. Not a toast: a write that failed should
    /// still be readable a minute later.
    var notice: String?

    /// A close the user has to confirm, because the document has unsaved
    /// changes. Holds the document's id rather than its index — the array can
    /// move underneath a pending question.
    var pendingClose: Int?

    /// Bumped on every edit. `FindState.searchedRevision` compares against it.
    var revision = 0

    var wraps: Bool { didSet { AppSettings.set(wraps, forKey: "wraps") } }
    var showLineNumbers: Bool {
        didSet { AppSettings.set(showLineNumbers, forKey: "lineNumbers") }
    }

    /// Local document zoom; the tab strip and toolbars keep their UI font.
    var documentFont: UIFont?
    @ObservationIgnored private weak var fontEditor: Editor?
    @ObservationIgnored private var zoomBase: UIFont?
    @ObservationIgnored private var zoomFonts: [Int: UIFont] = [:]
    @ObservationIgnored private var zoomRemainder: Float = 0

    let controller = EditorController()
    private var nextID = 1

    struct TabDrag {
        var documentID: Int
        var destination: Int
        var caretX: Float
    }
    var tabDrag: TabDrag?
    @ObservationIgnored var tabFrames: [Int: CanvasFrame] = [:]
    @ObservationIgnored var tabStripFrame = CanvasFrame(x: 0, y: 0, w: 0, h: 0)
    @ObservationIgnored var tabViewportFrame = CanvasFrame(x: 0, y: 0, w: 0, h: 0)
    @ObservationIgnored var tabPanTime: Double = 0
    @ObservationIgnored let tabScroll = ScrollPosition()

    /// Memo behind `activeLineCount`. Ignored by observation on purpose: it is
    /// derived from state that is already observed, and registering a write
    /// here would invalidate the view from inside the body that read it.
    @ObservationIgnored
    private var lineCountCache: (document: Int, bytes: Int, revision: Int, lines: Int)?

    init(editor: Editor? = nil) {
        fontEditor = editor
        wraps = AppSettings.bool(forKey: "wraps") ?? false
        showLineNumbers = AppSettings.bool(forKey: "lineNumbers") ?? true
        documents = [EditorDocument(id: takeID(), url: nil, text: "")]
    }

    func zoom(by notches: Float) {
        guard notches.isFinite, let editor = fontEditor,
              let base = zoomBase ?? FontStore.default else { return }
        zoomBase = base
        zoomRemainder += notches
        let steps = Int(min(40, max(-40, zoomRemainder.rounded(.towardZero))))
        guard steps != 0 else { return }
        zoomRemainder -= Float(steps)
        let current = Int((documentFont ?? base).pixelSize.rounded())
        let size = min(48, max(8, current + steps))
        guard size != current else { zoomRemainder = 0; return }
        if let cached = zoomFonts[size] {
            documentFont = cached
            return
        }
        guard let font = UIFont(path: base.path, pixelSize: Float(size),
                                faceIndex: base.faceIndex, raster: base.raster),
              font.registerWithEngine(editor) else {
            notice = "Could not load the editor font at \(size) px."
            return
        }
        font.useFallbacks(base.fallbacks.map {
            FontFallback(path: $0.path, pixelSize: Float(size))
        }, into: editor)
        zoomFonts[size] = font
        documentFont = font
    }

    private func takeID() -> Int {
        defer { nextID += 1 }
        return nextID
    }

    // MARK: - The document in front

    var active: EditorDocument {
        get { documents.indices.contains(activeIndex) ? documents[activeIndex] : documents[0] }
        set {
            guard documents.indices.contains(activeIndex) else { return }
            documents[activeIndex] = newValue
        }
    }

    /// The binding the editor writes through. The setter is the one place that
    /// knows an edit happened, so it is where `isModified` and `revision` are
    /// maintained.
    var text: Binding<String> {
        Binding(
            get: { [weak self] in self?.active.text ?? "" },
            set: { [weak self] newValue in
                guard let self, self.documents.indices.contains(self.activeIndex) else { return }
                guard self.documents[self.activeIndex].text != newValue else { return }
                self.documents[self.activeIndex].text = newValue
                self.documents[self.activeIndex].isModified = true
                self.revision &+= 1
                // Matches found against the previous text point at characters
                // that have moved. Re-run rather than clear, so the bar keeps
                // working while the user types into the document.
                if self.find.isOpen, !self.find.query.isEmpty { self.runSearch() }
            }
        )
    }

    /// Lines in the document in front, for the status bar.
    ///
    /// Counted off the UTF-8 bytes rather than by splitting the buffer, and
    /// then memoised: the status bar is rebuilt on every frame the window
    /// draws, and a scan of a 4 MB log is ~4 ms of it — spent to re-answer a
    /// number that can only have changed if the text did.
    ///
    /// Keyed on the byte count as well as `revision`, because a lazily-opened
    /// tab gets its text from `loadIfNeeded` rather than from the editing
    /// binding, and so arrives without a revision bump.
    var activeLineCount: Int {
        let doc = active
        let bytes = doc.text.utf8.count
        if let c = lineCountCache,
           c.document == doc.id, c.bytes == bytes, c.revision == revision
        {
            return c.lines
        }
        // The mounted editor has counted these already, for its gutter. Its
        // answer only counts if it is looking at *this* buffer: during a tab
        // switch it still holds the outgoing one for a frame.
        if let metrics = controller.metrics(), metrics.bytes == bytes {
            lineCountCache = (doc.id, bytes, revision, metrics.lines)
            return metrics.lines
        }
        // Otherwise count them here, over contiguous storage where there is
        // any: `reduce` on `String.UTF8View` goes through the view's iterator
        // a byte at a time, and on a buffer this size that is an order of
        // magnitude off a straight scan.
        let lines: Int
        if bytes == 0 {
            lines = 1
        } else {
            lines = doc.text.utf8.withContiguousStorageIfAvailable { buffer in
                var count = 1
                for byte in buffer where byte == 0x0A { count += 1 }
                return count
            } ?? doc.text.utf8.reduce(1) { $1 == 0x0A ? $0 + 1 : $0 }
        }
        lineCountCache = (doc.id, bytes, revision, lines)
        return lines
    }

    var windowTitle: String {
        let mark = active.isModified ? "• " : ""
        let where_ = active.url?.deletingLastPathComponent().path
        return "\(mark)\(active.name)\(where_.map { " — \($0)" } ?? "") — LavaEditor"
    }

    // MARK: - Switching

    /// Brings `index` to the front, saving where the outgoing document was and
    /// restoring where the incoming one left off.
    func activate(_ index: Int) {
        guard documents.indices.contains(index), index != activeIndex else { return }
        stashPosition()
        activeIndex = index
        // Applied on the editor's next reconcile, which is the first moment
        // the new text is in it — see `EditorController.restore`.
        controller.restore(documents[index].position ?? .start)
        loadIfNeeded(index)
        // Offsets into the document being left mean nothing in this one.
        find.search = TextSearch()
        if find.isOpen, !find.query.isEmpty { runSearch() }
    }

    /// Records the live editor position on the active document, before
    /// anything swaps the buffer out from under the editor.
    func stashPosition() {
        guard documents.indices.contains(activeIndex),
              documents[activeIndex].isLoaded,
              let position = controller.position()
        else { return }
        documents[activeIndex].position = position
    }

    private func loadIfNeeded(_ index: Int) {
        guard documents.indices.contains(index),
              !documents[index].isLoaded,
              documents[index].loadError == nil
        else { return }
        if !documents[index].load() {
            notice = "\(documents[index].name): \(documents[index].loadError ?? "could not be read")"
        }
    }

    // MARK: - File actions

    func newDocument() {
        stashPosition()
        documents.append(EditorDocument(id: takeID(), url: nil, text: ""))
        activeIndex = documents.count - 1
        controller.restore(.start)
        notice = nil
    }

    func openFileDialog() {
        let urls = FileDialog.openFiles(title: "Open Files")
        open(urls)
    }

    /// Shared by the dialog, the menu, dropped files and the command line. A
    /// file already open is brought forward rather than opened twice — two
    /// tabs onto one file are two buffers, and the second save silently
    /// discards the first.
    func open(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        notice = nil
        stashPosition()
        var target: Int?
        for url in urls {
            let resolved = url.standardizedFileURL
            if let existing = documents.firstIndex(where: { $0.url?.standardizedFileURL == resolved }) {
                target = existing
                continue
            }
            documents.append(
                EditorDocument(id: takeID(), url: resolved, text: "", isLoaded: false)
            )
            target = documents.count - 1
        }
        guard let target else { return }
        // Straight to the index rather than through `activate`, which stashes
        // the outgoing position — already done above, and doing it twice would
        // record the *incoming* document's zero.
        activeIndex = target
        controller.restore(documents[target].position ?? .start)
        loadIfNeeded(target)
        // Replaces a single untouched scratch document. Opening a file into a
        // window that has never been typed in should not leave an empty tab
        // behind, and every editor does this.
        if documents.count > 1,
           let scratch = documents.firstIndex(where: {
               $0.url == nil && !$0.isModified && $0.text.isEmpty
           }),
           scratch != activeIndex
        {
            documents.remove(at: scratch)
            if scratch < activeIndex { activeIndex -= 1 }
        }
    }

    @discardableResult
    func save() -> Bool {
        guard documents.indices.contains(activeIndex) else { return false }
        guard let url = documents[activeIndex].url else { return saveAs() }
        if let error = documents[activeIndex].save(to: url) {
            notice = "Could not save \(documents[activeIndex].name): \(error)"
            return false
        }
        notice = "Saved \(documents[activeIndex].name)"
        return true
    }

    @discardableResult
    func saveAs() -> Bool {
        guard documents.indices.contains(activeIndex) else { return false }
        guard let target = FileDialog.saveFile(
            title: "Save As", defaultName: documents[activeIndex].name
        ) else { return false }
        if let error = documents[activeIndex].save(to: target) {
            notice = "Could not save \(target.lastPathComponent): \(error)"
            return false
        }
        notice = "Saved \(documents[activeIndex].name)"
        return true
    }

    func reload() {
        guard documents.indices.contains(activeIndex),
              documents[activeIndex].url != nil else { return }
        if documents[activeIndex].load() {
            controller.restore(documents[activeIndex].position ?? .start)
            notice = "Reloaded \(documents[activeIndex].name)"
        } else {
            notice = "Could not reload: \(documents[activeIndex].loadError ?? "unknown error")"
        }
    }

    // MARK: - Closing

    /// Asks first when there is something to lose. The question is the whole
    /// reason closing is not one line: a text editor that drops unsaved work
    /// on Ctrl+W is a text editor nobody uses twice.
    func requestClose(_ index: Int? = nil) {
        let target = index ?? activeIndex
        guard documents.indices.contains(target) else { return }
        if documents[target].isModified {
            if target != activeIndex { activate(target) }
            pendingClose = documents[target].id
            return
        }
        close(target)
    }

    func close(_ index: Int) {
        guard documents.indices.contains(index) else { return }
        pendingClose = nil
        if documents.count == 1 {
            documents = [EditorDocument(id: takeID(), url: nil, text: "")]
            activeIndex = 0
            controller.restore(.start)
            return
        }
        let closingActive = index == activeIndex
        let activeID = active.id
        documents.remove(at: index)
        if closingActive {
            activeIndex = min(index, documents.count - 1)
            controller.restore(documents[activeIndex].position ?? .start)
            loadIfNeeded(activeIndex)
        } else if let i = documents.firstIndex(where: { $0.id == activeID }) {
            activeIndex = i
        }
    }

    /// Drops `id` at `dest` and keeps `activeIndex` on the same document.
    func reorderTab(id: Int, to dest: Int) {
        guard let from = documents.firstIndex(where: { $0.id == id }) else {
            return
        }
        let destination = min(max(0, dest), documents.count - 1)
        guard from != destination else { return }
        let activeID = active.id
        let document = documents.remove(at: from)
        documents.insert(document, at: destination)
        if let index = documents.firstIndex(where: { $0.id == activeID }) {
            activeIndex = index
        }
    }

    func dragTab(_ id: Int, _ value: DragGestureValue) {
        if value.phase == .ended {
            defer { tabDrag = nil }
            guard let drag = tabDrag, drag.documentID == id,
                  value.y >= tabStripFrame.y, value.y <= tabStripFrame.y + tabStripFrame.h else { return }
            reorderTab(id: id, to: drag.destination)
            return
        }
        // A renderer-side scroll moves tabs without a layout pass. Refresh
        // their frames before the next drag event resolves a destination.
        ViewInvalidation.markNeedsLayout()
        updateTabDrag(id, x: value.x)
    }

    func advanceTabDrag() {
        guard let drag = tabDrag else { return }
        let now = FrameScheduler.now()
        let dt = min(0.05, max(0, now - tabPanTime))
        tabPanTime = now
        let pointer = PointerState.window
        guard pointer.y >= tabViewportFrame.y,
              pointer.y <= tabViewportFrame.y + tabViewportFrame.h else { return }
        let direction: Float = pointer.x < tabViewportFrame.x + 24 ? -1
            : (pointer.x > tabViewportFrame.x + tabViewportFrame.w - 24 ? 1 : 0)
        if direction != 0 {
            tabScroll.scroll(to: tabScroll.offset + direction * 480 * Float(dt))
        }
        updateTabDrag(drag.documentID, x: pointer.x)
    }

    private func updateTabDrag(_ id: Int, x: Float) {
        let remaining = documents.filter { $0.id != id }
        let destination = remaining.firstIndex { document in
            guard let frame = tabFrames[document.id] else { return false }
            return x < frame.x + frame.w * 0.5
        } ?? remaining.count
        let caretX: Float
        if destination < remaining.count, let frame = tabFrames[remaining[destination].id] {
            caretX = frame.x - 2
        } else if let last = remaining.last, let frame = tabFrames[last.id] {
            caretX = frame.x + frame.w + 2
        } else {
            caretX = tabStripFrame.x + 4
        }
        if tabDrag?.documentID != id || tabDrag?.destination != destination || tabDrag?.caretX != caretX {
            tabDrag = TabDrag(documentID: id, destination: destination, caretX: caretX)
        }
    }

    /// Resolves the pending question. `save` writes first and keeps the
    /// document open if the write fails — losing the file to a failed save is
    /// the same loss the question exists to prevent.
    func resolvePendingClose(save shouldSave: Bool) {
        guard let id = pendingClose,
              let index = documents.firstIndex(where: { $0.id == id }) else {
            pendingClose = nil
            return
        }
        if shouldSave {
            activeIndex = index
            guard save() else { pendingClose = nil; return }
        }
        close(index)
    }

    // MARK: - Find and replace

    func openFind(replace: Bool) {
        find.isOpen = true
        find.showsReplace = replace
        if !find.query.isEmpty { runSearch() }
    }

    func closeFind() {
        find.isOpen = false
        find.search = TextSearch()
    }

    /// Recomputes matches against the buffer as it is now.
    ///
    /// Biased to the caret, so opening find jumps to the next match rather
    /// than back to the top of the file.
    func runSearch() {
        guard !find.query.isEmpty else {
            find.search = TextSearch()
            return
        }
        let caret = controller.position()?.focus ?? 0
        find.search.find(
            find.query, in: active.text,
            caseSensitive: find.caseSensitive, near: caret
        )
        find.searchedRevision = revision
        revealCurrentMatch()
    }

    func findNext() {
        guard find.search.isActive else { runSearch(); return }
        find.search.next()
        revealCurrentMatch()
    }

    func findPrevious() {
        guard find.search.isActive else { runSearch(); return }
        find.search.previous()
        revealCurrentMatch()
    }

    private func revealCurrentMatch() {
        guard let match = find.search.current else { return }
        controller.reveal(range: match)
    }

    func replaceCurrent() {
        guard find.search.current != nil else { return }
        // Against the buffer as it is now. Offsets from before an edit point
        // at characters that have moved, and replacing there corrupts text the
        // user never selected.
        if find.searchedRevision != revision { runSearch() }
        guard controller.replaceCurrent(find.search, with: find.replacement) else { return }
        revision &+= 1
        markModified()
        runSearch()
    }

    func replaceAll() {
        if find.searchedRevision != revision { runSearch() }
        let count = controller.replaceAll(find.search, with: find.replacement)
        guard count > 0 else {
            notice = "No matches to replace"
            return
        }
        revision &+= 1
        markModified()
        notice = "Replaced \(count) \(count == 1 ? "match" : "matches")"
        runSearch()
    }

    /// The editor wrote through its own binding, which set this already for a
    /// keystroke — but a replace goes through the controller, and the binding
    /// setter that would have noticed runs before `isModified` means anything.
    private func markModified() {
        guard documents.indices.contains(activeIndex) else { return }
        documents[activeIndex].isModified = true
    }

    // MARK: - Go to line

    func openGoto() {
        gotoOpen = true
        gotoLine = ""
    }

    func performGoto() {
        defer { gotoOpen = false }
        guard let line = Int(gotoLine.trimmingCharacters(in: .whitespaces)), line > 0 else {
            notice = "Not a line number: \(gotoLine)"
            return
        }
        controller.reveal(line: line)
    }

    // MARK: - Command line

    func openArguments(_ arguments: [String]) {
        let urls = arguments
            .filter { !$0.hasPrefix("-") }
            .map { URL(fileURLWithPath: $0) }
        open(urls)
    }

    /// True when anything anywhere is unsaved — what the window asks before
    /// letting itself be closed.
    var hasUnsavedWork: Bool { documents.contains { $0.isModified } }

    // MARK: - Path actions (status-bar context menu)

    /// Puts the active file's filesystem path on the clipboard.
    func copyActivePath() {
        guard let url = active.url else { return }
        ClipboardBridge.write(url.path)
    }

    /// Opens the active file's folder in the desktop file manager.
    ///
    /// The folder, not the file: `FileManager1.ShowItems` would highlight it,
    /// but that is a blocking D-Bus round trip, and a missing owner looks
    /// like a hang on the frame that opened the menu. `xdg-open` of the
    /// directory is what still works when no file manager is listening.
    func revealActiveInFileManager() {
        guard let url = active.url else { return }
        let folder = url.standardizedFileURL.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: folder.path) else {
            notice = "Folder no longer exists"
            return
        }
        if !FileLocation.open(folder) {
            notice = "Could not open file location"
        }
    }
}

/// Launch the desktop file manager for a directory. Same shape as
/// `FileDialog`: a subprocess, not Yoga, not a draw list.
private enum FileLocation {
    static func open(_ url: URL) -> Bool {
        guard let xdgOpen = which("xdg-open") else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: xdgOpen)
        process.arguments = [url.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            return true
        } catch {
            return false
        }
    }

    private static func which(_ binary: String) -> String? {
        for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
        {
            let candidate = "\(dir)/\(binary)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}
