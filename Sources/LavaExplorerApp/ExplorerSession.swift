import Foundation
import LavaExplorerCore
import LavaShell
import LavaUI
import Observation

/// The folders on screen, how they are laid out in panes, and which row is
/// selected where.
///
/// Opening a file leaves this process: `xdg-open` is the desktop's handler,
/// the same way the editor reveals a path. Opening a folder stays here.
///
/// Every command without a pane of its own — a key, a menu item, a toolbar
/// button — acts on the **active** pane. A press anywhere inside a pane makes
/// it active before the press itself runs (`.onAnyPress`), which is what lets
/// the rest of this file keep talking about "the current tab".
///
/// Unchecked `Sendable` for the reason LavaView's session is: every property
/// is read and written on the frame loop, and the one piece of work that
/// leaves it — a copy — hands its result back through `MainQueue.async`.
@Observable
final class ExplorerSession: @unchecked Sendable {
    var layout: PaneLayout
    var notice: String?
    var sidebarFraction: Float = 0.22
    /// Right-clicked row, and the pane it was in. Nil closes the overlay; the
    /// binding lives here because a `LazyVStack` cell does not keep `@State`
    /// when it unmounts. The pane matters because one folder can be open in
    /// two panes, and the same path would otherwise open two menus.
    var contextEntry: FileEntry?
    var contextPaneID: Int?
    /// Window coordinates of the right-click. `.below` pins the menu to the
    /// row's leading edge; a context menu belongs under the pointer.
    var menuX: Float = 0
    var menuY: Float = 0
    /// Closing the last tab closes the window, the way Explorer does.
    var requestClose: () -> Void = {}

    let places: [Place]
    let applications: [DesktopEntry]
    let source: any FileSource
    let openFile: (String) -> Bool

    init(
        paths: [String],
        source: any FileSource = LocalFileSource(),
        openFile: @escaping (String) -> Bool = OpenLocation.file,
        places: [Place]? = nil
    ) {
        self.source = source
        self.openFile = openFile
        self.places = places ?? Places.standard()
        self.applications = Self.loadApplications()
        let first = paths.first ?? NSHomeDirectory()
        var tabs = ExplorerTabs(
            tab: ExplorerTab.open(id: 1, path: first, source: source)
        )
        for path in paths.dropFirst() {
            tabs.open(path: path, source: source)
        }
        if !paths.isEmpty { tabs.select(id: 1) }
        self.layout = PaneLayout(tabs: tabs)
    }

    convenience init(
        path: String,
        source: any FileSource = LocalFileSource(),
        openFile: @escaping (String) -> Bool = OpenLocation.file,
        places: [Place]? = nil
    ) {
        self.init(paths: [path], source: source, openFile: openFile, places: places)
    }

    /// The active pane's tabs.
    var tabSet: ExplorerTabs {
        get { layout.activeTabs }
        set { layout.activeTabs = newValue }
    }

    var history: FolderHistory { tabSet.current.history }
    var listing: FolderListing { tabSet.current.listing }
    var selected: String? { tabSet.current.selected }
    var showHidden: Bool { tabSet.current.showHidden }
    var sort: FileSort { tabSet.current.sort }
    var sortDescending: Bool { tabSet.current.sortDescending }
    var title: String { tabSet.current.title }

    /// Address bar. Independent of `history.path` while it is being edited,
    /// so typing does not navigate a character at a time.
    var pathDraft: String {
        get { tabSet.current.pathDraft }
        set { tabSet.updateCurrent { $0.pathDraft = newValue } }
    }

    var selectedIndex: Int? {
        guard let selected else { return nil }
        return listing.entries.firstIndex { $0.path == selected }
    }

    var selectedEntry: FileEntry? {
        guard let selected else { return nil }
        return listing.entries.first { $0.path == selected }
    }

    var status: String {
        if let notice { return notice }
        if let error = listing.error { return error }
        let folders = listing.folderCount
        let files = listing.fileCount
        var parts: [String] = []
        if folders > 0 {
            parts.append(folders == 1 ? "1 folder" : "\(folders) folders")
        }
        if files > 0 {
            parts.append(files == 1 ? "1 file" : "\(files) files")
        }
        if parts.isEmpty { parts.append("Empty") }
        if let entry = selectedEntry {
            parts.append(entry.name)
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Panes

    func activatePane(_ id: Int) {
        guard layout.activePaneID != id else { return }
        layout.activate(pane: id)
        ViewInvalidation.markDirty()
    }

    /// One pane's address bar, which is not necessarily the active one's: a
    /// field shows what its own pane is on.
    func pathDraft(in paneID: Int) -> String {
        layout.pane(id: paneID)?.tabs.current.pathDraft ?? ""
    }

    func setPathDraft(_ value: String, in paneID: Int) {
        layout.updatePane(id: paneID) { pane in
            pane.tabs.updateCurrent { $0.pathDraft = value }
        }
    }

    func splitFraction(_ splitID: Int) -> Binding<Float> {
        Binding(
            get: { [unowned self] in layout.fraction(split: splitID) ?? 0.5 },
            set: { [unowned self] in layout.setFraction(split: splitID, $0) }
        )
    }

    // MARK: - Dragging a tab

    /// Where a dragged tab would land: into `paneID`, or into a new pane on
    /// `side` of it. Over a strip, `gap` is the place among its tabs and
    /// `caretX` the window x the preview marks it at.
    struct TabDropTarget: Equatable {
        var paneID: Int
        var side: PaneSide?
        var gap: Int? = nil
        var caretX: Float? = nil
    }

    struct TabDrag: Equatable {
        var tabID: Int
        var title: String
        /// Nil over anywhere a drop would do nothing — outside every pane, or
        /// into the pane the tab is already in.
        var target: TabDropTarget?
    }

    /// Observed, and written only when the target changes: the drop preview
    /// is drawn from it. The ghost that follows the pointer is redrawn on
    /// every move without it.
    var tabDrag: TabDrag?
    /// Where each pane and each tab was laid out, reported by the views
    /// themselves. Not observed — they change on layout, and nothing is drawn
    /// from them directly.
    @ObservationIgnored private var paneFrames: [Int: PaneRect] = [:]
    @ObservationIgnored private var tabFrames: [Int: PaneRect] = [:]

    func notePaneFrame(_ paneID: Int, _ frame: CanvasFrame) {
        paneFrames[paneID] = PaneRect(x: frame.x, y: frame.y, w: frame.w, h: frame.h)
    }

    func noteTabFrame(_ tabID: Int, _ frame: CanvasFrame) {
        tabFrames[tabID] = PaneRect(x: frame.x, y: frame.y, w: frame.w, h: frame.h)
    }

    func dragTab(_ tabID: Int, _ value: DragGestureValue) {
        switch value.phase {
        case .began:
            guard let tab = layout.tab(id: tabID) else { return }
            dismissContext()
            // A strip the wheel scrolled has moved its tabs without a layout
            // pass, so their frames are where they were before it scrolled.
            // One pass puts them right before the pointer asks where a gap is.
            ViewInvalidation.markNeedsLayout()
            tabDrag = TabDrag(
                tabID: tabID, title: tab.title,
                target: dropTarget(for: tabID, x: value.x, y: value.y)
            )
        case .changed:
            guard var drag = tabDrag, drag.tabID == tabID else { return }
            let target = dropTarget(for: tabID, x: value.x, y: value.y)
            guard target != drag.target else { return }
            drag.target = target
            tabDrag = drag
        case .ended:
            guard let drag = tabDrag, drag.tabID == tabID else { return }
            tabDrag = nil
            if let target = drag.target {
                if let side = target.side {
                    layout.splitTab(tabID, beside: target.paneID, on: side)
                } else {
                    layout.moveTab(tabID, to: target.paneID, gap: target.gap)
                }
                // A pane or tab that has gone must not still be aimed at by a
                // stale frame the next time a tab is dragged.
                let livePanes = Set(layout.panes.map(\.id))
                paneFrames = paneFrames.filter { livePanes.contains($0.key) }
                let liveTabs = Set(layout.panes.flatMap { $0.tabs.tabs.map(\.id) })
                tabFrames = tabFrames.filter { liveTabs.contains($0.key) }
            }
            ViewInvalidation.markDirty()
        }
    }

    private func dropTarget(for tabID: Int, x: Float, y: Float) -> TabDropTarget? {
        for pane in layout.panes {
            guard let rect = paneFrames[pane.id], rect.contains(x: x, y: y) else {
                continue
            }
            if y < rect.y + PaneChrome.stripHeight {
                return stripTarget(for: tabID, in: pane, rect: rect, x: x)
            }
            let side = PaneDropZone.side(
                atX: x, y: y, in: rect, stripHeight: PaneChrome.stripHeight
            )
            guard layout.canDrop(tab: tabID, on: pane.id, side: side) else { return nil }
            return TabDropTarget(paneID: pane.id, side: side)
        }
        return nil
    }

    /// Over a pane's strip: a place among its tabs — a reorder in the tab's
    /// own pane, a position in another's.
    private func stripTarget(
        for tabID: Int, in pane: ExplorerPane, rect: PaneRect, x: Float
    ) -> TabDropTarget? {
        let spans = pane.tabs.tabs.compactMap { tabFrames[$0.id] }.map { (x: $0.x, w: $0.w) }
        // Every tab has to have reported, or the count is off and so is every
        // gap after the one that did not. Into the pane is still a fair answer.
        guard spans.count == pane.tabs.tabs.count else {
            guard layout.canDrop(tab: tabID, on: pane.id, side: nil) else { return nil }
            return TabDropTarget(paneID: pane.id, side: nil)
        }
        let gap = PaneDropZone.gap(atX: x, tabSpans: spans)
        guard layout.canDrop(tab: tabID, on: pane.id, side: nil, gap: gap) else { return nil }
        // In the middle of the spacing between two tabs, or just past the last.
        let caret: Float
        if gap < spans.count {
            caret = spans[gap].x - 2
        } else if let last = spans.last {
            caret = last.x + last.w + 2
        } else {
            caret = rect.x + 4
        }
        return TabDropTarget(
            paneID: pane.id, side: nil, gap: gap,
            caretX: min(max(caret, rect.x + 2), rect.x + rect.w - 2)
        )
    }

    // MARK: - Navigation

    func go(_ path: String) {
        dismissContext()
        notice = nil
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let landing = FolderHistory.landing(argument: trimmed, source: source)
        let source = self.source
        tabSet.updateCurrent { tab in
            if tab.history.visit(landing.directory)
                || tab.listing.path != landing.directory
            {
                tab.selected = landing.select
                tab.reload(from: source)
            } else if let select = landing.select {
                tab.selected = select
            } else {
                tab.reload(from: source)
            }
        }
        ViewInvalidation.markDirty()
    }

    func goBack() {
        guard history.canGoBack else { return }
        dismissContext()
        notice = nil
        let source = self.source
        tabSet.updateCurrent { tab in
            tab.history.goBack()
            tab.selected = nil
            tab.reload(from: source)
        }
        ViewInvalidation.markDirty()
    }

    func goForward() {
        guard history.canGoForward else { return }
        dismissContext()
        notice = nil
        let source = self.source
        tabSet.updateCurrent { tab in
            tab.history.goForward()
            tab.selected = nil
            tab.reload(from: source)
        }
        ViewInvalidation.markDirty()
    }

    func goUp() {
        guard history.canGoUp else { return }
        dismissContext()
        notice = nil
        let source = self.source
        tabSet.updateCurrent { tab in
            tab.history.goUp()
            tab.selected = nil
            tab.reload(from: source)
        }
        ViewInvalidation.markDirty()
    }

    func goHome() {
        go(NSHomeDirectory())
    }

    func reload() {
        let source = self.source
        tabSet.updateCurrent { $0.reload(from: source) }
        ViewInvalidation.markDirty()
    }

    func toggleHidden() {
        tabSet.updateCurrent { $0.showHidden.toggle() }
        reload()
    }

    func setSort(_ next: FileSort) {
        tabSet.updateCurrent { tab in
            if tab.sort == next {
                tab.sortDescending.toggle()
            } else {
                tab.sort = next
                tab.sortDescending = false
            }
        }
        reload()
        dismissContext()
    }

    // MARK: - Tabs

    func selectTab(id: Int) {
        dismissContext()
        layout.selectTab(id)
        ViewInvalidation.markDirty()
    }

    func newTab(path: String? = nil) {
        dismissContext()
        layout.openTab(path: path ?? history.path, source: source)
        ViewInvalidation.markDirty()
    }

    func closeTab(id: Int) {
        dismissContext()
        if !layout.closeTab(id) {
            requestClose()
            return
        }
        ViewInvalidation.markDirty()
    }

    func cycleTab(by delta: Int) {
        dismissContext()
        tabSet.cycle(by: delta)
        ViewInvalidation.markDirty()
    }

    // MARK: - Selection

    func select(_ entry: FileEntry) {
        notice = nil
        tabSet.updateCurrent { $0.selected = entry.path }
        ViewInvalidation.markDirty()
    }

    func click(_ entry: FileEntry, clicks: Int) {
        dismissContext()
        if clicks >= 2 {
            tabSet.updateCurrent { $0.selected = entry.path }
            activate()
        } else {
            select(entry)
        }
    }

    func openContext(_ entry: FileEntry) {
        notice = nil
        tabSet.updateCurrent { $0.selected = entry.path }
        let pointer = PointerState.window
        menuX = pointer.x
        menuY = pointer.y
        contextEntry = entry
        contextPaneID = layout.activePaneID
        ViewInvalidation.markDirty()
    }

    func dismissContext() {
        guard contextEntry != nil else { return }
        contextEntry = nil
        contextPaneID = nil
        ViewInvalidation.markDirty()
    }

    func moveSelection(by step: Int) {
        guard !listing.entries.isEmpty else { return }
        let current = selectedIndex ?? (step > 0 ? -1 : listing.entries.count)
        let next = min(max(0, current + step), listing.entries.count - 1)
        let path = listing.entries[next].path
        tabSet.updateCurrent { $0.selected = path }
        ViewInvalidation.markDirty()
    }

    /// Folder → navigate. File → the desktop's handler.
    func activate() {
        guard let entry = selectedEntry else { return }
        notice = nil
        if entry.isDirectory {
            go(entry.path)
            return
        }
        if openFile(entry.path) {
            return
        }
        notice = "Could not open \(entry.name)"
        ViewInvalidation.markDirty()
    }

    func copySelectedPath() {
        let path = selected ?? listing.path
        ClipboardBridge.write(path)
        notice = "Copied path"
        dismissContext()
        ViewInvalidation.markDirty()
    }

    func mimeType(of entry: FileEntry) -> String {
        MimeApps.type(of: entry.path, isDirectory: entry.isDirectory)
    }

    /// Apps that claimed this type, or — if none did — every app that takes
    /// a file, so the list is never a dead end.
    func handlers(for entry: FileEntry) -> [DesktopEntry] {
        let mime = mimeType(of: entry)
        let matching = applications.filter { $0.handles(mime) }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
        if !matching.isEmpty { return matching }
        let takers = applications.filter(\.acceptsFiles)
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
        return takers.isEmpty ? applications : takers
    }

    func open(_ entry: FileEntry, with app: DesktopEntry) {
        dismissContext()
        if entry.isDirectory, app.id == "LavaExplorer" {
            go(entry.path)
            return
        }
        if app.launch(files: [entry.path]) {
            return
        }
        notice = "Could not open with \(app.name)"
        ViewInvalidation.markDirty()
    }

    func setDefault(_ app: DesktopEntry, for entry: FileEntry) {
        let mime = mimeType(of: entry)
        dismissContext()
        if app.id == "LavaExplorer" {
            _ = Self.installUserDesktopEntry()
        }
        if MimeApps.setDefault(app.desktopFileId, for: mime) {
            notice = "\(app.name) opens \(mime) now"
        } else {
            notice = "Could not set the default application"
        }
        ViewInvalidation.markDirty()
    }

    /// Installed apps, plus this process when it has no desktop file yet —
    /// a `swift run` session still has to appear in Open With / Set Default.
    private static func loadApplications() -> [DesktopEntry] {
        var apps = DesktopEntry.installed()
        guard !apps.contains(where: { $0.id == "LavaExplorer" }) else { return apps }
        apps.append(DesktopEntry(
            id: "LavaExplorer",
            name: "LavaExplorer",
            genericName: "File Manager",
            comment: "",
            icon: "lava-explorer",
            exec: "\(Self.executablePath()) %F",
            workingDirectory: "",
            terminal: false,
            categories: ["System", "FileManager"],
            keywords: [],
            mimeTypes: ["inode/directory"],
            startupWMClass: "LavaExplorer"
        ))
        return apps
    }

    /// A user-level `.desktop` so `xdg-mime default` has something to name
    /// after a `swift run`, not only after `packaging/install.sh`.
    @discardableResult
    private static func installUserDesktopEntry() -> Bool {
        let home = NSHomeDirectory()
        let directory = home + "/.local/share/applications"
        let path = directory + "/LavaExplorer.desktop"
        let bin = executablePath()
        let body = """
            [Desktop Entry]
            Type=Application
            Name=LavaExplorer
            GenericName=File Manager
            Exec=\(bin) %F
            TryExec=\(bin)
            Icon=lava-explorer
            Terminal=false
            Categories=System;FileManager;
            MimeType=inode/directory;
            StartupWMClass=LavaExplorer
            """
        do {
            try FileManager.default.createDirectory(
                atPath: directory, withIntermediateDirectories: true
            )
            try body.write(toFile: path, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    private static func executablePath() -> String {
        let raw = CommandLine.arguments[0]
        if raw.hasPrefix("/") { return raw }
        let cwd = FileManager.default.currentDirectoryPath
        return ((cwd as NSString).appendingPathComponent(raw) as NSString)
            .standardizingPath
    }

    func stub(_ verb: String) {
        dismissContext()
        switch verb {
        case "Delete":
            notice = "Delete is not implemented — not until Trash exists"
        default:
            notice = "\(verb) is not implemented yet"
        }
        ViewInvalidation.markDirty()
    }

    func defaultHandlerId(for entry: FileEntry) -> String? {
        MimeApps.defaultHandler(for: mimeType(of: entry))
    }

    func performContext(_ id: String, entry: FileEntry) {
        if id.hasPrefix("ctx.open-with.") {
            let appId = String(id.dropFirst("ctx.open-with.".count))
            if let app = applications.first(where: { $0.id == appId }) {
                open(entry, with: app)
            }
            return
        }
        if id.hasPrefix("ctx.set-default.") {
            let appId = String(id.dropFirst("ctx.set-default.".count))
            if let app = applications.first(where: { $0.id == appId }) {
                setDefault(app, for: entry)
            }
            return
        }
        switch id {
        case "ctx.open":
            tabSet.updateCurrent { $0.selected = entry.path }
            dismissContext()
            activate()
        case "ctx.open-tab":
            dismissContext()
            if entry.isDirectory { newTab(path: entry.path) }
        case "ctx.copy-path":
            tabSet.updateCurrent { $0.selected = entry.path }
            copySelectedPath()
        case "ctx.copy": stub("Copy")
        case "ctx.cut": stub("Cut")
        case "ctx.paste": stub("Paste")
        case "ctx.rename": stub("Rename")
        case "ctx.delete": stub("Delete")
        default:
            dismissContext()
        }
    }

    // MARK: - Copying

    /// A drop some of whose names are already taken, waiting on one answer
    /// for all of them. See `ClashChoice` for why one.
    struct PendingCopy {
        var plan: CopyPlan
        var folderTitle: String
    }

    /// Up while the clash bar is showing. Observed: the bar is drawn from it.
    var pendingCopy: PendingCopy?
    /// A copy is running on its worker. A second drop waits rather than
    /// racing the first for the same names.
    @ObservationIgnored private var copying = false

    /// What a drag carrying files is aimed at, for the view to light up.
    /// Observed, and written only as the target changes.
    enum DropHover: Equatable {
        case folder(paneID: Int, path: String)
        case pane(Int)
        case tab(Int)
        case place(String)
    }

    var dropHover: DropHover?

    func setDropHover(_ target: DropHover, _ on: Bool) {
        if on {
            if dropHover != target { dropHover = target }
        } else if dropHover == target {
            dropHover = nil
        }
    }

    // Every drop that lands somewhere in a pane is a copy into a folder; these
    // only say which folder. A copy and never a move, like the drag out of a
    // row: nothing here can put a moved file back, and there is no Trash yet
    // to find it in.

    /// Into that tab's folder — whichever pane the tab is in.
    func dropOnTab(id: Int, _ urls: [URL]) {
        guard let tab = layout.tab(id: id) else { return }
        copyDropped(urls, into: tab.listing.path, title: tab.title)
    }

    /// Into the folder a pane is showing: a drop on its list, not on a folder
    /// in it.
    func dropInPane(_ paneID: Int, _ urls: [URL]) {
        guard let pane = layout.pane(id: paneID) else { return }
        let tab = pane.tabs.current
        copyDropped(urls, into: tab.listing.path, title: tab.title)
    }

    /// Into a folder row.
    func dropInFolder(_ entry: FileEntry, _ urls: [URL]) {
        copyDropped(urls, into: entry.path, title: entry.name)
    }

    /// Into a place in the sidebar.
    func dropOnPlace(_ place: Place, _ urls: [URL]) {
        copyDropped(urls, into: place.path, title: place.title)
    }

    private func copyDropped(_ urls: [URL], into directory: String, title: String) {
        let own = !ownDrag.isEmpty && urls.map(\.path) == ownDrag
        ownDrag = []
        dropHover = nil
        dismissContext()
        guard !copying, pendingCopy == nil else {
            notice = "Still copying — drop again when it is done"
            ViewInvalidation.markDirty()
            return
        }
        let plan = CopyPlan.make(sources: urls.map(\.path), into: directory, source: source)
        guard !plan.items.isEmpty else {
            // A row picked up and let go of in the folder it came from is a
            // drag that changed its mind, not something to report.
            let changedItsMind = own && plan.refused.allSatisfy {
                if case .alreadyThere = $0 { return true }
                return false
            }
            if !changedItsMind {
                notice = Self.refusalNotice(plan, folder: title)
            }
            ViewInvalidation.markDirty()
            return
        }
        if plan.clashes.isEmpty {
            startCopy(plan, choice: .skip, folderTitle: title)
        } else {
            pendingCopy = PendingCopy(plan: plan, folderTitle: title)
            ViewInvalidation.markDirty()
        }
    }

    /// The clash bar's answer. Nil is Cancel: nothing is copied, not even the
    /// items that did not clash — the drop was one decision.
    func resolveCopy(_ choice: ClashChoice?) {
        guard let pending = pendingCopy else { return }
        pendingCopy = nil
        guard let choice else {
            ViewInvalidation.markDirty()
            return
        }
        startCopy(pending.plan, choice: choice, folderTitle: pending.folderTitle)
    }

    private func startCopy(_ plan: CopyPlan, choice: ClashChoice, folderTitle: String) {
        copying = true
        notice = "Copying \(Self.items(plan.items.count)) to \(folderTitle)…"
        ViewInvalidation.markDirty()
        // Off the frame loop: a folder of photos takes as long as the disk
        // takes, and the window has to keep answering while it does.
        Thread.detachNewThread { [weak self] in
            let outcome = FileCopier.run(plan, clashes: choice)
            MainQueue.async { [weak self] in
                self?.finishCopy(outcome, directory: plan.directory, folderTitle: folderTitle)
            }
        }
    }

    private func finishCopy(_ outcome: CopyOutcome, directory: String, folderTitle: String) {
        copying = false
        let source = self.source
        // Every tab on that folder in every pane, not just the one dropped
        // on: the same folder open twice should not disagree about what is in
        // it.
        layout.updateTabs(showing: directory) { $0.reload(from: source) }
        if let failure = outcome.failures.first {
            let name = (failure.path as NSString).lastPathComponent
            let more = outcome.failures.count > 1
                ? " (and \(outcome.failures.count - 1) more)" : ""
            notice = "Copied \(Self.items(outcome.copied)) to \(folderTitle); "
                + "\(name): \(failure.message)\(more)"
        } else if outcome.copied == 0 {
            notice = "Nothing copied to \(folderTitle)"
        } else {
            notice = "Copied \(Self.items(outcome.copied)) to \(folderTitle)"
        }
        ViewInvalidation.markDirty()
    }

    private static func refusalNotice(_ plan: CopyPlan, folder: String) -> String {
        switch plan.refused.first {
        case .alreadyThere?:
            return "Already in \(folder)"
        case .intoItself(let path)?:
            return "Cannot copy \((path as NSString).lastPathComponent) into itself"
        case .missing(let path)?:
            return "\((path as NSString).lastPathComponent) is not there any more"
        case nil:
            return "Nothing to copy"
        }
    }

    static func items(_ count: Int) -> String {
        count == 1 ? "1 item" : "\(count) items"
    }

    /// What this window last started dragging out.
    ///
    /// `.onDrop` covers the whole window, so a row let go of where it was
    /// picked up comes straight back as a drop — and a drop navigates, so a
    /// folder dragged a few pixels and released would open itself. Not
    /// observed: nothing draws it.
    @ObservationIgnored var ownDrag: [String] = []

    /// The paths a drag of `entry` carries. Selects it first, the way every
    /// file manager selects what is being dragged.
    func dragPaths(for entry: FileEntry) -> [String] {
        dismissContext()
        tabSet.updateCurrent { $0.selected = entry.path }
        ownDrag = [entry.path]
        return ownDrag
    }

    /// A drop is a place to go, not a copy. Copying files is an operation
    /// this sketch does not do.
    func acceptDrop(_ urls: [URL]) {
        let paths = urls.map(\.path)
        if !ownDrag.isEmpty, paths == ownDrag {
            ownDrag = []
            return
        }
        guard let url = urls.first else { return }
        go(url.path)
    }
}

/// `xdg-open` for a file the user double-clicked.
enum OpenLocation {
    static func file(_ path: String) -> Bool {
        guard let xdgOpen = which("xdg-open") else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: xdgOpen)
        process.arguments = [path]
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
