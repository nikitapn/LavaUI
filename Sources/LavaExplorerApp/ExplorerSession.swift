import Foundation
import LavaExplorerCore
import LavaShell
import LavaUI
import Observation

/// The folder on screen, how it is sorted, and which row is selected.
///
/// Opening a file leaves this process: `xdg-open` is the desktop's handler,
/// the same way the editor reveals a path. Opening a folder stays here.
///
/// Unchecked `Sendable` for the reason LavaView's session is: every property
/// is read and written on the frame loop, and the one piece of work that
/// leaves it — a copy — hands its result back through `MainQueue.async`.
@Observable
final class ExplorerSession: @unchecked Sendable {
    var tabSet: ExplorerTabs
    var notice: String?
    var sidebarFraction: Float = 0.22
    /// Right-clicked row. Nil closes the overlay; the binding lives here
    /// because a `LazyVStack` cell does not keep `@State` when it unmounts.
    var contextEntry: FileEntry?
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
        self.tabSet = tabs
    }

    convenience init(
        path: String,
        source: any FileSource = LocalFileSource(),
        openFile: @escaping (String) -> Bool = OpenLocation.file,
        places: [Place]? = nil
    ) {
        self.init(paths: [path], source: source, openFile: openFile, places: places)
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
        tabSet.select(id: id)
        ViewInvalidation.markDirty()
    }

    func newTab(path: String? = nil) {
        dismissContext()
        tabSet.open(path: path ?? history.path, source: source)
        ViewInvalidation.markDirty()
    }

    func closeTab(id: Int) {
        dismissContext()
        if !tabSet.close(id: id) {
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
        ViewInvalidation.markDirty()
    }

    func dismissContext() {
        guard contextEntry != nil else { return }
        contextEntry = nil
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

    /// Files dropped on a tab: copied into that tab's folder.
    ///
    /// A copy and never a move, like the drag out of a row: nothing here can
    /// put a moved file back, and there is no Trash yet to find it in.
    func dropOnTab(id: Int, _ urls: [URL]) {
        ownDrag = []
        dismissContext()
        guard let tab = tabSet.tab(id: id) else { return }
        guard !copying, pendingCopy == nil else {
            notice = "Still copying — drop again when it is done"
            ViewInvalidation.markDirty()
            return
        }
        let plan = CopyPlan.make(
            sources: urls.map(\.path), into: tab.listing.path, source: source
        )
        guard !plan.items.isEmpty else {
            notice = Self.refusalNotice(plan, folder: tab.title)
            ViewInvalidation.markDirty()
            return
        }
        if plan.clashes.isEmpty {
            startCopy(plan, choice: .skip, folderTitle: tab.title)
        } else {
            pendingCopy = PendingCopy(plan: plan, folderTitle: tab.title)
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
        // Every tab on that folder, not just the one dropped on: the same
        // folder open twice should not disagree about what is in it.
        tabSet.updateTabs(showing: directory) { $0.reload(from: source) }
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
