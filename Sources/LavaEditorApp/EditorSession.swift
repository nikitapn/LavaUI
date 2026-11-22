import Foundation
import LavaEditorSettings
import LavaProjectCore
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
    var documents: [EditorDocument] = [] {
        // Every edit, save, reload and close passes through here, which is the
        // one place project search can hear about all of them. It debounces.
        didSet {
            refreshActivePreview()
            projectSearch.buffersChanged()
            scheduleLanguageSync()
            if diff != nil { scheduleDiffRefresh() }
            if documents.count < oldValue.count || documents.first?.id != oldValue.first?.id {
                pruneEditorStates()
            }
        }
    }
    var activeIndex = 0 {
        // The tab in front is the one whose highlighting a server is asked for.
        didSet {
            guard activeIndex != oldValue else { return }
            refreshActivePreview()
            hoverCard = nil
            completion = nil
            scheduleLanguageSync()
        }
    }

    private(set) var recentFiles: [String] = Array(
        (AppSettings.value(forKey: "recentFiles", as: [String].self) ?? []).prefix(10)
    )

    var recentProjectPaths: [RecentProjectKind: [String]] = [:]
    /// The workspace this window is, if any. Remembered across launches, so
    /// a window that was a workspace comes back as one — without that, the
    /// next launch restored the implicit session and the workspace was only
    /// reachable through Open Recent.
    var workspaceURL: URL? {
        didSet {
            AppSettings.set(workspaceURL?.path ?? "", forKey: "lastWorkspace")
            if oldValue != workspaceURL { scheduleSettingsReload() }
        }
    }
    var pendingWorkspace: WorkspaceOpening?
    @ObservationIgnored var hasCheckpointed = false

    let projectSearch = SearchPanelModel()
    var find = FindState()
    var findQueryFocused = false
    /// Open, and what the user has typed into it, for `Go to Line`.
    var gotoOpen = false
    var gotoLine = ""
    var gotoFocused = false

    /// Installed extensions; see `ExtensionCatalog`.
    var extensions = ExtensionCatalog.discover()
    #if canImport(LavaEditorExtensionAPI)
    @ObservationIgnored weak var visibleSurface: EmbeddedPreview?
    #endif
    var extensionRunning = false
    /// The Agents view's rows. See `AgentsModel`.
    let agents = AgentsModel()
    /// Ctrl+I's box between lines, while it is open. See `InlineChat`.
    var inlineChat: InlineChat?
    /// Where the editor drew the box's gap. Always the same object: the
    /// editor's zone wrapper stays in the tree whether a chat is open or not.
    @ObservationIgnored let chatAnchor = EditorZoneAnchor(line: 0)
    /// Git → Switch Branch or Worktree…, while it is up. See `BranchPicker`.
    var branchPicker: BranchPicker?
    @ObservationIgnored var switchingBranch = false
    var lineActions: [Int: [EditorLineAction]] = [:]
    var actionSnapshot: (document: Int, revision: Int, path: String, text: String)?
    var actionGeneration: UInt64 = 0
    @ObservationIgnored var discoveryTimer: DispatchWorkItem?
    var scanningActions = false
    /// `currentLineActions` for a revision the last answer is behind.
    @ObservationIgnored var shiftedLineActions: (revision: Int, actions: [Int: [EditorLineAction]])?
    var runningLineAction = false
    /// One line under the toolbar. Not a toast: a write that failed should
    /// still be readable a minute later.
    var notice: String?

    /// A close the user has to confirm, because the document has unsaved
    /// changes. Holds the document's id rather than its index — the array can
    /// move underneath a pending question.
    private(set) var pendingClose: Int?
    private var closeQueue: [Int] = []

    /// Bumped on every edit. `FindState.searchedRevision` compares against it.
    var revision = 0

    var wraps: Bool {
        get { EditorToggle.wordWrap.value(in: editorPreferences) }
        set { setEditorSetting(.wordWrap, to: newValue) }
    }
    var showLineNumbers: Bool {
        get { EditorToggle.lineNumbers.value(in: editorPreferences) }
        set { setEditorSetting(.lineNumbers, to: newValue) }
    }
    private var editorPreferences = EditorPreferences.defaults
    @ObservationIgnored let settingsFiles = EditorSettingsFiles()
    let languageServers = LanguageServers()
    @ObservationIgnored var languageSyncScheduled = false
    /// The hover card on screen, and the character the pointer rests on.
    var hoverCard: EditorHoverCard?
    @ObservationIgnored var hoverTarget: Int?
    /// The completion list, and a counter that retires stale requests.
    var completion: CompletionSession?
    @ObservationIgnored var completionGeneration = 0
    /// Set while a completion is being inserted, so the edit it makes is not
    /// taken for typing.
    @ObservationIgnored var insertingCompletion = false

    /// Local document zoom; the tab strip and toolbars keep their UI font.
    private(set) var fonts: EditorFonts
    @ObservationIgnored private var fontPreferences: DocumentFontPreferences?
    @ObservationIgnored var fontSettingsWarning: String?
    private var zoomedDocument: (regular: UIFont, bold: UIFont?)?
    var documentFont: UIFont? { zoomedDocument?.regular ?? fonts.document }
    var documentBoldFont: UIFont? { zoomedDocument == nil ? fonts.documentBold : zoomedDocument?.bold }
    @ObservationIgnored private weak var fontEditor: Editor?
    /// The engine images are decoded into — file-type icons in a canvas
    /// paint need it, and have no view of their own to ask.
    var imageEditor: Editor? { fontEditor }
    @ObservationIgnored private var zoomFonts: [Int: (regular: UIFont, bold: UIFont?)] = [:]
    @ObservationIgnored private var zoomRemainder: Float = 0

    let controller = EditorController()
    private var nextID = 1

    /// The comparison on screen instead of the editor, when there is one. It
    /// belongs to a document, and shows only while that document is in front.
    var diff: DiffModel?
    /// The terminals under the editor. See `TerminalPanel`.
    let terminal = TerminalPanel()

    /// Undo history, caret and selection per document, so switching tabs or
    /// opening a comparison does not throw them away. Keyed by document id.
    @ObservationIgnored let editorStates = EditorStateStore()
    @ObservationIgnored private var pruneScheduled = false

    /// Forgets the history of documents that have closed. After the frame
    /// rather than at once: a tab being dragged is removed and inserted again
    /// in two steps, and its history must survive the gap between them.
    private func pruneEditorStates() {
        guard !pruneScheduled else { return }
        pruneScheduled = true
        FrameTasks.after { [weak self] in
            guard let self else { return }
            self.pruneScheduled = false
            self.editorStates.retain(Set(self.documents.map { AnyHashable($0.id) }))
        }
    }

    /// Bumped per edit while a comparison is up; see `scheduleDiffRefresh`.
    @ObservationIgnored var diffGeneration = 0

    /// The open folder, if any. See `EditorSession+Project`.
    var project: ProjectSession? {
        didSet {
            if oldValue?.tree.root != project?.tree.root { scheduleSettingsReload() }
        }
    }
    var showsSidebar = true
    /// Which view the sidebar shows. See `ActivityBar`.
    var sidebarView: SidebarView = .explorer
    var sidebarFraction: Float = 0.24

    /// HEAD's copy of each open document that has one, by document id. See
    /// `EditorSession+Git`.
    var gitBaselines: [Int: GitBaseline] = [:]
    @ObservationIgnored var baselineGeneration = 0
    @ObservationIgnored var marksCache: (key: MarksKey, marks: [EditorLineMark])?
    /// Fill changed lines as well as marking them in the gutter.
    var highlightsChangedLines: Bool {
        get { EditorToggle.highlightChangedLines.value(in: editorPreferences) }
        set { setEditorSetting(.highlightChangedLines, to: newValue) }
    }

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
        fonts = EditorFonts(editor: editor)
        documents = [EditorDocument(id: takeID(), url: nil, text: "")]
        projectSearch.buffers = { [weak self] root in self?.searchBuffers(under: root) ?? [] }
        startLanguageServers()
        for kind in RecentProjectKind.allCases {
            let paths = AppSettings.value(forKey: kind.settingsKey, as: [String].self) ?? []
            recentProjectPaths[kind] = RecentProjectPaths.normalized(paths)
        }
        startEditorSettings()
    }

    func applyEditorPreferences(_ preferences: EditorPreferences) {
        if editorPreferences != preferences { editorPreferences = preferences }
        let font = DocumentFontPreferences(
            family: preferences.fontFamily, size: preferences.fontSize, lineHeight: preferences.lineHeight
        )
        guard fontPreferences != font else { return }
        fontPreferences = font
        fontSettingsWarning = fonts.updateDocument(preferences, editor: fontEditor)
        zoomFonts.removeAll()
        zoomedDocument = nil
        zoomRemainder = 0
    }

    private struct DocumentFontPreferences: Equatable {
        let family: String
        let size: Float
        let lineHeight: Float
    }

    /// Restore before command-line files are opened, so an explicit file wins
    /// selection while reusing an existing tab from the previous session.
    func restoreSession() {
        if let path = AppSettings.value(forKey: "lastWorkspace", as: String.self), !path.isEmpty,
           FileManager.default.fileExists(atPath: path)
        {
            openWorkspace(URL(fileURLWithPath: path))
            if workspaceURL != nil { return }
        }
        restoreImplicitSession()
    }

    /// The session kept in settings when no workspace is open.
    func restoreImplicitSession() {
        guard let saved = AppSettings.value(forKey: "session", as: EditorSessionSnapshot.self) else { return }
        applySession(saved, revealActive: true)
    }

    func applySession(_ saved: EditorSessionSnapshot, revealActive: Bool) {
        closeFolder()
        showsSidebar = saved.showsSidebar ?? true
        sidebarFraction = min(0.6, max(0.1, saved.sidebarFraction ?? 0.24))

        var seen = Set<String>()
        let files = saved.files.filter { $0.path.hasPrefix("/") && seen.insert($0.path).inserted }
        cancelPendingClose()
        documents = EditorTabPolicy.restored(files.map {
            EditorDocument(id: takeID(), url: URL(fileURLWithPath: $0.path), text: "",
                           tabState: $0.tabState ?? .open,
                           position: $0.position?.editorPosition, isLoaded: false)
        })
        if documents.isEmpty {
            documents = [EditorDocument(id: takeID(), url: nil, text: "")]
        }
        activeIndex = documents.firstIndex { $0.url?.path == saved.activePath } ?? 0
        tabScroll.scrollToTop()

        zoomedDocument = nil
        zoomRemainder = 0
        if let root = saved.projectRoot, root.hasPrefix("/") {
            restoreProject(root, expanded: Set(saved.expandedFolders ?? []))
        }
        reloadEditorSettings()
        // Older snapshots recorded 17 even when the user had never zoomed.
        // Let that value inherit the document size from settings.
        if let size = saved.fontSize, size != 17 { zoomDocument(to: size) }
        controller.restore(active.position ?? .start)
        loadIfNeeded(activeIndex)
        if revealActive {
            followActive()
        } else if let url = active.url, let project {
            project.selected = project.tree.path(of: url)
        }
    }

    /// Called after the editor emits, including scroll-only redraws. Reading
    /// the controller here avoids polling or observed writes on every frame.
    func checkpointSession() {
        hasCheckpointed = true
        SessionPersistence.shared.checkpoint(sessionSnapshot(), workspace: workspaceURL)
    }

    func sessionSnapshot(useLivePosition: Bool = true) -> EditorSessionSnapshot {
        let live = useLivePosition && active.isLoaded ? controller.position() : nil
        let files = documents.compactMap { document -> EditorSessionSnapshot.File? in
            guard let url = document.url else { return nil }
            let position = (document.id == active.id ? live : nil) ?? document.position ?? .start
            return .init(path: url.standardizedFileURL.path, position: .init(position), tabState: document.tabState)
        }
        return .init(
            files: files, activePath: (active.url ?? documents.first { $0.id == active.preview?.sourceID }?.url)?.standardizedFileURL.path,
            fontSize: zoomedDocument.map { Int($0.regular.pixelSize.rounded()) },
            projectRoot: project?.tree.root.path,
            expandedFolders: project.map { $0.tree.expanded.subtracting([""]).sorted() },
            showsSidebar: project == nil && workspaceURL == nil ? nil : showsSidebar,
            sidebarFraction: project == nil && workspaceURL == nil ? nil : sidebarFraction
        )
    }

    func zoom(by notches: Float) {
        guard notches.isFinite, let current = documentFont ?? FontStore.default else { return }
        zoomRemainder += notches
        let steps = Int(min(40, max(-40, zoomRemainder.rounded(.towardZero))))
        guard steps != 0 else { return }
        zoomRemainder -= Float(steps)
        zoomDocument(to: Int(current.pixelSize.rounded()) + steps)
    }

    private func zoomDocument(to requestedSize: Int) {
        guard let editor = fontEditor, let base = fonts.document ?? FontStore.default else { return }
        let baseSize = Int(base.pixelSize.rounded())
        let size = min(max(48, baseSize), max(min(8, baseSize), requestedSize))
        if size == baseSize {
            zoomedDocument = nil
            return
        }
        if let current = zoomedDocument?.regular, Int(current.pixelSize.rounded()) == size {
            zoomRemainder = 0
            return
        }
        if let cached = zoomFonts[size] {
            zoomedDocument = cached
            return
        }
        guard let font = resizedDocumentFont(base, size: Float(size), editor: editor) else {
            notice = "Could not load the editor font at \(size) px."
            return
        }
        let bold = fonts.documentBold.flatMap { resizedDocumentFont($0, size: Float(size), editor: editor) }
        zoomFonts[size] = (font, bold)
        zoomedDocument = (font, bold)
    }

    private func resizedDocumentFont(_ base: UIFont, size: Float, editor: Editor) -> UIFont? {
        guard let font = UIFont(path: base.path, pixelSize: size, faceIndex: base.faceIndex,
                                raster: base.raster, lineHeightMultiple: editorPreferences.lineHeight),
              font.registerWithEngine(editor) else { return nil }
        font.useFallbacks(base.fallbacks.map {
            FontFallback(path: $0.path, pixelSize: size)
        }, into: editor)
        return font
    }

    func takeID() -> Int {
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
                guard self.documents[self.activeIndex].saveUnavailable == nil else { return }
                guard self.documents[self.activeIndex].text != newValue else { return }
                // Bytes, not characters: `utf8.count` is stored, a character
                // count walks the buffer. One typed character is one to four.
                let grew = newValue.utf8.count - self.documents[self.activeIndex].text.utf8.count
                self.documents[self.activeIndex].text = newValue
                self.markModified()
                self.revision &+= 1
                // Matches found against the previous text point at characters
                // that have moved. Re-run rather than clear, so the bar keeps
                // working while the user types into the document.
                if self.find.isOpen, !self.find.query.isEmpty { self.runSearch() }
                if !self.insertingCompletion { self.textEdited(typedOne: (1...4).contains(grew)) }
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
        if let metrics = controller.metrics(forText: doc.text) {
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
        followActive()
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

    func loadIfNeeded(_ index: Int) {
        guard documents.indices.contains(index),
              !documents[index].isLoaded,
              documents[index].loadError == nil
        else { return }
        if !documents[index].load() {
            notice = "\(documents[index].name): \(documents[index].loadError ?? "could not be read")"
        } else if let url = documents[index].url {
            rememberFile(url)
            refreshBaseline(index)
        }
    }

    // MARK: - File actions

    func clearRecentFiles() {
        recentFiles = []
        AppSettings.set(recentFiles, forKey: "recentFiles")
    }

    private func rememberFile(_ url: URL) {
        // Match open()'s identity so reopening a recent path finds its tab.
        let path = url.standardizedFileURL.path
        var updated: [String] = []
        AppSettings.update([String].self, forKey: "recentFiles") { stored in
            updated = Array(([path] + (stored ?? []).filter { $0 != path }).prefix(10))
            return updated
        }
        recentFiles = updated
    }

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
        open(urls, mode: .normal)
    }

    func open(_ urls: [URL], mode: EditorTabPolicy.OpenMode) {
        guard !urls.isEmpty else { return }
        notice = nil
        stashPosition()
        let outgoingID = active.id
        var target: Int?
        for url in urls {
            let resolved = url.standardizedFileURL
            switch EditorTabPolicy.opening(resolved, mode: mode, in: documents) {
            case .activate(let existing, let keepOpen):
                target = existing
                if keepOpen { keepTabOpen(existing) }
                if documents[existing].isLoaded {
                    rememberFile(resolved)
                } else {
                    // Retry a previously failed open: a recent file may have
                    // been restored or its permissions fixed since then.
                    documents[existing].loadError = nil
                }
            case .append(let state, let preview):
                if let preview { keepTabOpen(preview) }
                documents.append(EditorDocument(id: takeID(), url: resolved, text: "",
                                                tabState: state, isLoaded: false))
                target = documents.count - 1
            case .replacePreview(let preview):
                forgetTab(documents[preview].id)
                documents[preview] = EditorDocument(id: takeID(), url: resolved, text: "",
                                                    tabState: .preview, isLoaded: false)
                target = preview
            }
        }
        guard let target else { return }
        // Straight to the index rather than through `activate`, which stashes
        // the outgoing position — already done above, and doing it twice would
        // record the *incoming* document's zero.
        activeIndex = target
        controller.restore(documents[target].position ?? .start)
        loadIfNeeded(target)
        if active.id != outgoingID {
            hoverCard = nil
            completion = nil
            find.search = TextSearch()
            if find.isOpen, !find.query.isEmpty { runSearch() }
        }
        // Replaces a single untouched scratch document. Opening a file into a
        // window that has never been typed in should not leave an empty tab
        // behind, and every editor does this.
        if documents.count > 1,
           let scratch = documents.firstIndex(where: {
               $0.preview == nil && $0.url == nil && $0.tabState == .open && !$0.isModified && $0.text.isEmpty
           }),
           !documents.contains(where: { $0.preview?.sourceID == documents[scratch].id }),
           scratch != activeIndex
        {
            forgetTab(documents[scratch].id)
            documents.remove(at: scratch)
            if scratch < activeIndex { activeIndex -= 1 }
        }
        followActive()
    }

    @discardableResult
    func save() -> Bool { saveDocument(activeIndex) }

    @discardableResult
    func saveAs() -> Bool { saveDocument(activeIndex, choosePath: true) }

    /// Save All can write a background tab without changing the mounted buffer
    /// or recording its caret on a different document.
    func saveDocument(_ index: Int, choosePath: Bool = false) -> Bool {
        guard documents.indices.contains(index) else { return false }
        let document = documents[index]
        if let error = document.saveUnavailable {
            notice = "Could not save \(document.name): \(error)"
            return false
        }
        let target: URL
        if let url = document.url, !choosePath {
            target = url
        } else {
            guard let url = FileDialog.saveFile(title: "Save As", defaultName: document.name) else { return false }
            target = url
        }
        if let error = documents[index].save(to: target) {
            notice = "Could not save \(target.lastPathComponent): \(error)"
            return false
        }
        keepTabOpen(index)
        if let url = documents[index].url { rememberFile(url) }
        // The file may have just become tracked, or the user committed from
        // a terminal while it was open; saving is a cheap moment to ask.
        refreshBaseline(index)
        if !choosePath, document.url != nil { project?.refreshStatus() }
        notice = "Saved \(documents[index].name)"
        return true
    }

    func reload() {
        guard documents.indices.contains(activeIndex),
              documents[activeIndex].url != nil else { return }
        if documents[activeIndex].load() {
            controller.restore(documents[activeIndex].position ?? .start)
            refreshBaseline(activeIndex)
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
        guard pendingClose == nil, documents.indices.contains(target) else { return }
        if documents[target].isModified {
            if target != activeIndex { activate(target) }
            pendingClose = documents[target].id
            return
        }
        close(target)
    }

    func close(_ index: Int) {
        guard documents.indices.contains(index) else { return }
        let sourceID = documents[index].id
        for preview in documents.filter({ $0.preview?.sourceID == sourceID }) {
            if let tab = documents.firstIndex(where: { $0.id == preview.id }) { close(tab) }
        }
        guard let index = documents.firstIndex(where: { $0.id == sourceID }) else { return }
        if pendingClose == documents[index].id { pendingClose = nil }
        forgetTab(documents[index].id)
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
        guard documents[from].tabState != .pinned else { return }
        let destination = EditorTabPolicy.dragDestination(dest, in: documents.filter { $0.id != id })
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
        let proposed = remaining.firstIndex { document in
            guard let frame = tabFrames[document.id] else { return false }
            return x < frame.x + frame.w * 0.5
        } ?? remaining.count
        let destination = EditorTabPolicy.dragDestination(proposed, in: remaining)
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
            cancelPendingClose()
            return
        }
        if shouldSave, !saveDocument(index) {
            cancelPendingClose()
            return
        }
        close(index)
        continueClosingTabs()
    }

    var closingDocument: EditorDocument? {
        documents.first { $0.id == pendingClose }
    }

    func cancelPendingClose() {
        pendingClose = nil
        closeQueue.removeAll()
    }

    func requestCloseTabs(_ action: EditorTabPolicy.BulkClose, from index: Int) {
        guard pendingClose == nil else { return }
        closeQueue = EditorTabPolicy.closing(action, from: index, in: documents)
        continueClosingTabs()
    }

    private func continueClosingTabs() {
        while pendingClose == nil, !closeQueue.isEmpty {
            let id = closeQueue.removeFirst()
            if let index = documents.firstIndex(where: { $0.id == id && $0.tabState != .pinned }) {
                requestClose(index)
            }
        }
    }

    func keepTabOpen(_ index: Int) {
        let state = documents[index].tabState
        if state == .preview { documents[index].tabState = state.keptOpen }
    }

    func toggleTabPin(_ index: Int) {
        let activeID = active.id
        let pinning = documents[index].tabState != .pinned
        EditorTabPolicy.togglePin(at: index, in: &documents)
        if let index = documents.firstIndex(where: { $0.id == activeID }) { activeIndex = index }
        if pinning { tabScroll.scrollToTop() }
    }

    func forgetTab(_ id: Int) {
        gitBaselines[id] = nil
        tabFrames[id] = nil
        if diff?.documentID == id { closeDiff() }
    }

    // MARK: - Find and replace

    func openFind(replace: Bool) {
        FocusManager.clear()
        find.isOpen = true
        find.showsReplace = replace
        findQueryFocused = true
        if !find.query.isEmpty { runSearch() }
    }

    func closeFind() {
        find.isOpen = false
        findQueryFocused = false
        find.search = TextSearch()
        controller.focus()
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
        keepTabOpen(activeIndex)
        documents[activeIndex].isModified = true
    }

    var matchingExtensionCommands: [InstalledCommand] {
        guard active.preview == nil else { return [] }
        return extensions.commands.filter { $0.command.kind == .selectionEdit && $0.command.matches(language: active.language.rawValue, url: active.url) }
    }

    func reloadExtensions() {
        ExtensionHost.reload()
        extensions = ExtensionCatalog.discover()
        for tab in documents { tab.preview?.invalidate() }
        refreshActivePreview()
        actionSnapshot = nil
        refreshLineActions()
        notice = extensions.errors.isEmpty ? "Loaded \(extensions.commands.count) extension commands"
            : extensions.errors.joined(separator: "\n")
    }

    func formatSelection(using installed: InstalledCommand) {
        guard installed.command.matches(language: active.language.rawValue, url: active.url) else { return }
        guard !extensionRunning, active.saveUnavailable == nil else { return }
        guard let position = controller.position(), position.anchor != position.focus else {
            notice = "Select text to format first"
            return
        }
        let range = min(position.anchor, position.focus)..<max(position.anchor, position.focus)
        let text = active.text
        guard range.lowerBound >= 0,
              let end = text.index(text.startIndex, offsetBy: range.upperBound, limitedBy: text.endIndex)
        else { return }
        let start = text.index(text.startIndex, offsetBy: range.lowerBound)
        guard text.utf8.distance(from: start, to: end) <= SelectionExtension.limit else {
            notice = "Selection exceeds 8 MiB."
            return
        }
        let selection = String(text[start..<end])
        let documentID = active.id
        let originalRevision = revision
        let startByte = text.utf8.distance(from: text.startIndex, to: start)
        let owner = LanguageSessionRef(self)
        extensionRunning = true
        notice = "Running \(installed.command.title)…"
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try SelectionExtension.run(installed, text: selection, document: documentID,
                                                           revision: originalRevision, startByte: startByte) }
            MainQueue.async {
                guard let session = owner.session else { return }
                session.extensionRunning = false
                switch result {
                case .failure(let error):
                    session.notice = "\(installed.command.title): \(error.localizedDescription)"
                case .success(let replacement):
                    session.notice = nil
                    guard session.active.id == documentID, session.revision == originalRevision,
                          session.active.saveUnavailable == nil,
                          session.active.text.utf8.elementsEqual(text.utf8),
                          let current = session.controller.position(),
                          current.anchor == position.anchor, current.focus == position.focus else {
                        session.notice = "Selection changed. Extension edit discarded."
                        return
                    }
                    guard !selection.utf8.elementsEqual(replacement.utf8),
                          session.controller.replace([range], with: replacement) == 1 else { return }
                    session.revision &+= 1
                    session.markModified()
                    if session.find.isOpen { session.runSearch() }
                }
            }
        }
    }

    // MARK: - Go to line

    func openGoto() {
        FocusManager.clear()
        gotoOpen = true
        gotoLine = ""
        gotoFocused = true
    }

    func closeGoto() {
        gotoOpen = false
        gotoFocused = false
        controller.focus()
    }

    func performGoto() {
        defer { closeGoto() }
        guard let line = Int(gotoLine.trimmingCharacters(in: .whitespaces)), line > 0 else {
            notice = "Not a line number: \(gotoLine)"
            return
        }
        controller.reveal(line: line)
    }

    // MARK: - Command line

    func openArguments(_ arguments: [String], relativeTo directory: URL) {
        func fileURL(_ path: String) -> URL {
            URL(fileURLWithPath: path, relativeTo: directory).standardizedFileURL
        }

        // `--diff old new`: the new file opens as a document and the old one
        // is only read, as the left column.
        if let flag = arguments.firstIndex(of: "--diff"), arguments.count > flag + 2 {
            let old = fileURL(arguments[flag + 1])
            let new = fileURL(arguments[flag + 2])
            var rest = arguments
            rest.removeSubrange(flag...(flag + 2))
            openArguments(rest, relativeTo: directory)
            compare(old, with: new)
            return
        }
        var urls = arguments
            .filter { !$0.hasPrefix("-") }
            .map(fileURL)
        if let workspace = urls.first(where: {
            $0.pathExtension.lowercased() == EditorWorkspace.pathExtension && !Self.isDirectory($0)
        }) {
            openWorkspace(workspace)
            return
        }
        // A folder on the command line is the project, as `code .` makes it.
        if let folder = urls.first(where: { $0.hasDirectoryPath || Self.isDirectory($0) }) {
            openFolder(folder)
            urls.removeAll { $0.hasDirectoryPath || Self.isDirectory($0) }
        }
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
