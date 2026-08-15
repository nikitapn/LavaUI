import Foundation
import LavaUI
import Observation
import TraceLoomCore

/// Shared document + chrome state for TraceLoom.
///
/// Menu actions live outside the view tree (`LavaHost.run(menu:)`), while the
/// UI is a `View` with `@State`. Connecting them with closures that capture
/// `@State` does not work — those wrappers are value copies. An `@Observable`
/// class is the join: the menu mutates the same instance the view reads, and
/// Observation marks the view body dirty the same way as local `@State`.
///
/// Pattern:
/// ```swift
/// let session = TraceLoomSession()
/// LavaHost.run(editor: editor, menu: { … session.openLogFile() … }) {
///     TraceLoom(session: session)
/// }
/// ```
///
/// It holds *several* logs. Everything that belongs to one log — its text, its
/// rules, its zoom, where its editor was scrolled — lives in `LogDocument`;
/// what is left here is window chrome and the workspace those documents were
/// loaded from.
@Observable
final class TraceLoomSession {
    /// Never empty: closing the last document leaves a fresh sample rather
    /// than a window with nothing to be active. That invariant is what lets
    /// `active` be non-optional, and it is worth more than the empty state.
    var documents: [LogDocument]
    var activeIndex: Int = 0

    /// Where `saveWorkspace()` writes without asking. Nil until a workspace is
    /// opened or saved once.
    var workspaceURL: URL?

    /// Non-nil while a file load is in flight (status line under the header).
    var loadingPath: String?
    /// Outcome of the last load until the next one starts.
    var notice: TraceLoomNotice?

    var showSettings = false

    /// `lanes` gives each series its own strip; `overlay` stacks them in one
    /// plot so a long rule list does not squash every chart to a few pixels.
    /// Window chrome, not document state: it is how you want to *look* at
    /// charts, and carrying it per tab would make the same log look different
    /// depending on which one you came from.
    var timelineLayout: TimelineLayout = .lanes

    /// Share of the window below the header that the timeline gets; the log
    /// editor takes the rest. Lives here rather than in the view so the split
    /// survives whatever else rebuilds the body — and so a future "restore my
    /// layout" has one number to write down.
    var timelineSplit: Float = 0.62

    /// The log editor's handle, owned here rather than by the view because
    /// switching documents has to save the outgoing scroll position and hand
    /// the incoming one back — and switching happens from the menubar as well
    /// as from the switcher, where `@State` is out of reach.
    @ObservationIgnored let logEditor = EditorController()

    /// Document ids are handed out from here rather than a global counter, so
    /// two sessions in one process (tests, a second window) cannot collide.
    @ObservationIgnored private var nextDocumentID = 1

    init(
        rules: String = TraceLoom.sampleRules,
        log: String = TraceLoom.sampleLog
    ) {
        documents = []
        documents = [sampleDocument(rules: rules, log: log)]
    }

    // MARK: - The active document

    var active: LogDocument {
        get { documents.indices.contains(activeIndex) ? documents[activeIndex] : documents[0] }
        set {
            guard documents.indices.contains(activeIndex) else { return }
            documents[activeIndex] = newValue
        }
    }

    /// Bindable proxies. The view binds `$session.log` exactly as it did when
    /// there was one log, and neither the editor nor the parser needs to know
    /// that the text it is bound to belongs to a tab.
    var log: String {
        get { active.log }
        set { active.log = newValue }
    }

    var rules: String {
        get { active.rules }
        set { active.rules = newValue }
    }

    var zoomStart: Double? {
        get { active.zoomStart }
        set { active.zoomStart = newValue }
    }

    var zoomEnd: Double? {
        get { active.zoomEnd }
        set { active.zoomEnd = newValue }
    }

    // MARK: - Switching

    /// Brings document `index` to the front, saving where the outgoing one was
    /// and restoring where the incoming one left off.
    func activate(_ index: Int) {
        guard documents.indices.contains(index), index != activeIndex else { return }
        stashEditorPosition()
        activeIndex = index
        // Applied on the editor's next reconcile, which is the first moment the
        // new text is in it — see `EditorController.restore`.
        logEditor.restore(documents[index].position ?? .start)
        loadIfNeeded(index)
    }

    /// Records the live editor position on the active document. Called before
    /// anything that swaps the buffer out from under the editor.
    func stashEditorPosition() {
        guard documents.indices.contains(activeIndex),
              // A document whose file has not arrived yet is showing an empty
              // buffer, and an empty buffer's position is zero. Saving that
              // would overwrite the offset the workspace restored, before the
              // text it refers to has even been read.
              documents[activeIndex].isLoaded,
              let position = logEditor.position()
        else { return }
        documents[activeIndex].position = position
    }

    // MARK: - File actions (menu + in-window chrome)

    func openLogFile() {
        let urls = FileDialog.openFiles(
            title: "Open Log Files",
            filters: [FileDialog.Filter(name: "Log/text files", extensions: ["log", "txt"])]
        )
        loadLog(from: urls)
    }

    /// Shared by the file dialog, menu, and `.onDrop`. Each file becomes its
    /// own tab; one that is already open is brought forward instead of opened
    /// twice.
    func loadLog(from urls: [URL]) {
        guard !urls.isEmpty else { return }
        notice = nil
        var target: Int?
        for url in urls {
            if let existing = documents.firstIndex(where: { $0.url == url }) {
                target = existing
                continue
            }
            // Rules come from the document in front. Opening a second log is
            // nearly always "the same thing, a different run", and retyping the
            // rule set for it would be the first thing anyone did anyway.
            documents.append(
                LogDocument(
                    id: takeDocumentID(),
                    name: url.lastPathComponent,
                    url: url,
                    rules: active.rules,
                    isLoaded: false
                )
            )
            target = documents.count - 1
        }
        if let target { select(target) }
    }

    /// `activate`, but tolerant of already being there — the caller may have
    /// just created the document it is asking for.
    private func select(_ index: Int) {
        guard documents.indices.contains(index) else { return }
        if index != activeIndex {
            activate(index)
        } else {
            loadIfNeeded(index)
        }
    }

    /// Closes the document in front. The last one is replaced by a fresh
    /// sample rather than removed.
    func closeActiveDocument() {
        guard documents.indices.contains(activeIndex) else { return }
        if documents.count == 1 {
            documents = [sampleDocument()]
            activeIndex = 0
            logEditor.restore(.start)
            return
        }
        documents.remove(at: activeIndex)
        activeIndex = min(activeIndex, documents.count - 1)
        logEditor.restore(documents[activeIndex].position ?? .start)
        loadIfNeeded(activeIndex)
    }

    /// Brings the built-in sample forward, adding it back if it was closed.
    func reloadSample() {
        notice = nil
        if let existing = documents.firstIndex(where: { $0.url == nil }) {
            documents[existing].rules = TraceLoom.sampleRules
            documents[existing].log = TraceLoom.sampleLog
            documents[existing].zoomStart = nil
            documents[existing].zoomEnd = nil
            documents[existing].position = nil
            select(existing)
            logEditor.restore(.start)
            return
        }
        documents.append(sampleDocument())
        select(documents.count - 1)
    }

    func openSettings() {
        showSettings = true
    }

    func resetZoom() {
        zoomStart = nil
        zoomEnd = nil
    }

    /// Opens what was named on the command line: `traceloom a.log b.log`, or
    /// `traceloom yesterday.traceloom`, or both.
    ///
    /// Worth having beyond convenience — it is the only way to put a specific
    /// set of logs in front of the window without driving a file dialog, which
    /// is what the headless UI tests need and what a file manager's "open
    /// with" passes.
    func openArguments(_ arguments: [String]) {
        var logs: [URL] = []
        for argument in arguments where !argument.hasPrefix("-") {
            let url = URL(fileURLWithPath: argument)
            if url.pathExtension == Workspace.fileExtension {
                openWorkspace(at: url)
            } else {
                logs.append(url)
            }
        }
        if !logs.isEmpty { loadLog(from: logs) }
    }

    // MARK: - Workspaces

    /// Title-bar-ish name for the open workspace, for the header.
    var workspaceName: String? {
        workspaceURL?.deletingPathExtension().lastPathComponent
    }

    func newWorkspace() {
        documents = [sampleDocument()]
        activeIndex = 0
        workspaceURL = nil
        notice = nil
        logEditor.restore(.start)
    }

    func openWorkspace() {
        guard let url = FileDialog.openFile(
            title: "Open Workspace",
            filters: [
                FileDialog.Filter(
                    name: "TraceLoom workspaces", extensions: [Workspace.fileExtension]
                )
            ]
        ) else { return }
        openWorkspace(at: url)
    }

    func openWorkspace(at url: URL) {
        notice = nil
        do {
            apply(try Workspace.read(at: url), from: url)
        } catch {
            fail("\(error)")
        }
    }

    func saveWorkspace() {
        guard let workspaceURL else {
            saveWorkspaceAs()
            return
        }
        write(to: workspaceURL)
    }

    func saveWorkspaceAs() {
        guard let url = FileDialog.saveFile(
            title: "Save Workspace",
            filters: [
                FileDialog.Filter(
                    name: "TraceLoom workspaces", extensions: [Workspace.fileExtension]
                )
            ],
            defaultName: (workspaceName ?? "workspace") + ".\(Workspace.fileExtension)"
        ) else { return }
        // Zenity returns whatever was typed, extension or not.
        let named = url.pathExtension.isEmpty
            ? url.appendingPathExtension(Workspace.fileExtension)
            : url
        write(to: named)
    }

    /// The workspace as it stands, or nil when nothing in it could be saved.
    func currentWorkspace() -> Workspace? {
        stashEditorPosition()
        var entries: [WorkspaceDocument] = []
        var activeEntry = 0
        for (index, document) in documents.enumerated() {
            guard let entry = document.workspaceEntry else { continue }
            if index == activeIndex { activeEntry = entries.count }
            entries.append(entry)
        }
        guard !entries.isEmpty else { return nil }
        return Workspace(documents: entries, activeIndex: activeEntry)
    }

    private func write(to url: URL) {
        guard let workspace = currentWorkspace() else {
            // The sample has no path, so a session showing only the sample has
            // nothing a workspace could point at. Saying so beats writing an
            // empty file that silently restores to nothing.
            fail("Nothing to save yet — a workspace records logs opened from files")
            return
        }
        do {
            try workspace.write(to: url)
            workspaceURL = url
            notice = TraceLoomNotice(
                text: "Saved \(workspace.documents.count) log"
                    + (workspace.documents.count == 1 ? "" : "s")
                    + " to \(url.lastPathComponent)",
                isError: false
            )
        } catch {
            fail("\(error)")
        }
    }

    private func apply(_ workspace: Workspace, from url: URL) {
        guard !workspace.documents.isEmpty else {
            fail("\(url.lastPathComponent) has no logs in it")
            return
        }
        documents = workspace.documents.map {
            LogDocument.restoring($0, id: takeDocumentID())
        }
        activeIndex = min(max(0, workspace.activeIndex), documents.count - 1)
        workspaceURL = url
        logEditor.restore(documents[activeIndex].position ?? .start)
        // Only the document in front is read now; the rest are read the first
        // time they are selected.
        loadIfNeeded(activeIndex)
    }

    // MARK: - Loading

    /// Reads a document's log if it has a file and has not been read yet.
    private func loadIfNeeded(_ index: Int) {
        guard documents.indices.contains(index) else { return }
        let document = documents[index]
        guard !document.isLoaded, document.loadError == nil, let url = document.url else {
            return
        }
        loadingPath = url.path
        let id = document.id
        // Paint "Loading…" before the read/parse (can be multi-second).
        FrameTasks.after { [weak self] in self?.completeLoad(id: id, url: url) }
    }

    private func completeLoad(id: Int, url: URL) {
        defer { loadingPath = nil }
        // The document may have been closed while the read was queued.
        guard let index = documents.firstIndex(where: { $0.id == id }) else { return }
        do {
            let loaded = try LogFile.read(at: url)
            documents[index].log = loaded.text
            documents[index].isLoaded = true
            // Asked for again now the text exists. The restore queued when this
            // document was selected was applied to the empty buffer it had
            // then, and clamped to nothing — the offsets only mean something
            // once the log they were taken from is in the editor.
            if index == activeIndex, let position = documents[index].position {
                logEditor.restore(position)
            }
            if let warning = loaded.warning {
                notice = TraceLoomNotice(text: warning, isError: false)
                report(warning)
            }
        } catch {
            // Marked loaded so a missing file is reported once rather than on
            // every switch back to its tab; `loadError` is what the switcher
            // shows in its place.
            documents[index].isLoaded = true
            documents[index].loadError = "\(error)"
            fail("\(error)")
        }
    }

    private func fail(_ message: String) {
        notice = TraceLoomNotice(text: message, isError: true)
        report(message)
    }

    private func sampleDocument(
        rules: String = TraceLoom.sampleRules,
        log: String = TraceLoom.sampleLog
    ) -> LogDocument {
        LogDocument(id: takeDocumentID(), name: "Sample", rules: rules, log: log)
    }

    private func takeDocumentID() -> Int {
        defer { nextDocumentID += 1 }
        return nextDocumentID
    }

    private func report(_ message: String) {
        FileHandle.standardError.write(Data("TraceLoom: \(message)\n".utf8))
    }
}

enum TimelineLayout: String, CaseIterable, Sendable {
    case lanes
    case overlay
}

struct TraceLoomNotice {
    var text: String
    var isError: Bool
}
