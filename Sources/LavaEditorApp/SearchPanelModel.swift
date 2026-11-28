import Foundation
import LavaProjectCore
import LavaUI
import Observation

/// Project search, live over unsaved edits.
///
/// ripgrep answers for what is on disk, once per query. A document with
/// unsaved edits answers for its own file instead: its text is searched in
/// Swift (`ProjectSearchText`) and laid over the disk result, and edits re-run
/// that part alone — never the walk. When a buffer stops standing in (saved,
/// reverted, closed without saving) its file is read again from disk, since
/// the walk's answer for it is older than whatever happened to it since.
@Observable
final class SearchPanelModel {
    enum Row {
        case file(Int)
        case line(file: Int, index: Int)
    }

    /// A row with an identity that survives a refresh: the path, and for a
    /// match its line. Results change under the pointer as the user types, and
    /// a list that remounted every row would drop hover and press each time.
    struct Entry: Identifiable {
        let id: String
        let row: Row
    }

    private(set) var root: URL?
    private(set) var options = ProjectSearchOptions()
    private(set) var result: ProjectSearchResult?
    private(set) var rows: [Entry] = []
    private(set) var collapsed: Set<String> = []
    private var searching = false
    private var failure: String?
    var queryFocused = false
    /// The result row the keyboard is on, by `Entry.id`.
    var selected: String?
    /// Whether the results hold the keyboard.
    var resultsFocused = false
    /// The results' visible height, from layout: what a page is.
    @ObservationIgnored var viewportHeight: Float = 0

    /// The documents with unsaved edits under a root, as they are now. The
    /// session supplies it; called on the main thread only.
    @ObservationIgnored var buffers: (URL) -> [ProjectSearchBuffer] = { _ in [] }

    @ObservationIgnored let scroll = ScrollPosition()
    @ObservationIgnored private var request: ProjectSearchCancellation?
    /// The walk's answer, plus any files read again since. Never shown as is.
    @ObservationIgnored private var disk: ProjectSearchResult?
    /// What each standing-in buffer said, keyed by path, with the text it said
    /// it about — how the next sync knows which buffers changed.
    @ObservationIgnored private var overlay: [String: Overlay] = [:]
    /// Bumped by every new search, so a buffer job for the previous query
    /// cannot land in this one.
    @ObservationIgnored private var epoch = 0
    @ObservationIgnored private var syncScheduled = false
    @ObservationIgnored private var syncRunning = false
    @ObservationIgnored private var syncAgain = false

    private struct Overlay: Sendable {
        let text: String
        /// Nil when the buffer does not replace its file: outside the globs,
        /// or a regular expression Swift's engine will not compile. The disk
        /// result for the path stays in that case.
        let file: ProjectSearchFile?
    }

    deinit { request?.cancel() }

    func options(for root: URL) -> ProjectSearchOptions {
        self.root == root ? options : ProjectSearchOptions()
    }

    func summary(for root: URL) -> String {
        guard self.root == root, !options.query.isEmpty else { return "Search in project files" }
        if searching { return "Searching…" }
        if let failure { return failure }
        guard let result, result.count > 0 else { return "No results found" }
        let matches = result.count == 1 ? "result" : "results"
        let files = result.files.count == 1 ? "file" : "files"
        let count = "\(result.count.formatted()) \(matches) in \(result.files.count.formatted()) \(files)"
        return result.capped ? "\(count)\nSearch limit reached" : count
    }

    func search(root: URL, options: ProjectSearchOptions, immediate: Bool = false) {
        request?.cancel()
        epoch += 1
        if self.root != root {
            self.root = root
            collapsed = []
        }
        self.options = options
        result = nil
        disk = nil
        overlay = [:]
        rows = []
        failure = nil
        searching = !options.query.isEmpty
        scroll.scroll(to: 0)
        guard searching else {
            request = nil
            return
        }

        let token = ProjectSearchCancellation()
        request = token
        let owner = SearchPanelRef(self)
        let snapshot = buffers(root)
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + (immediate ? 0 : 0.25)) {
            let outcome = Result {
                let disk = try ProjectSearchEngine.search(root: root, options: options, cancellation: token)
                return (disk, Self.overlays(for: snapshot, options: options))
            }
            MainQueue.async {
                guard let model = owner.model, model.request === token else { return }
                model.searching = false
                model.request = nil
                switch outcome {
                case .success(let (disk, overlay)):
                    model.disk = disk
                    model.overlay = overlay
                    model.publish()
                    // Edits made while ripgrep ran are newer than the snapshot.
                    model.syncBuffers()
                case .failure(let error):
                    model.failure = error.localizedDescription
                }
            }
        }
    }

    /// A document changed. Cheap when nothing is being searched; otherwise
    /// syncs the buffers once the typing pauses.
    func buffersChanged() {
        guard disk != nil, !syncScheduled else { return }
        syncScheduled = true
        let owner = SearchPanelRef(self)
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.15) {
            MainQueue.async {
                guard let model = owner.model else { return }
                model.syncScheduled = false
                model.syncBuffers()
            }
        }
    }

    /// The results as a tree for `ProjectTree.step`: a file heading is a
    /// folder whose children are its matching lines, which is exactly how
    /// the keys should treat it — Left folds a file or climbs to it from a
    /// line, Right unfolds it or steps onto its first line.
    var navigationRows: [ProjectRow] {
        rows.map { entry in
            switch entry.row {
            case .file(let index):
                let path = result?.files[index].path ?? entry.id
                return ProjectRow(node: ProjectNode(name: path, path: entry.id, isDirectory: true),
                                  depth: 0, isExpanded: !collapsed.contains(path))
            case .line:
                return ProjectRow(node: ProjectNode(name: entry.id, path: entry.id, isDirectory: false),
                                  depth: 1, isExpanded: false)
            }
        }
    }

    /// The matching line a row id names, with its file's path.
    func line(for id: String) -> (path: String, line: ProjectSearchLine)? {
        guard let result, let entry = rows.first(where: { $0.id == id }),
              case .line(let file, let index) = entry.row else { return nil }
        return (result.files[file].path, result.files[file].lines[index])
    }

    /// Scrolls only as far as it takes to show the row `id`.
    func keepInSight(_ id: String, rowHeight: Float) {
        guard viewportHeight > 0, let index = rows.firstIndex(where: { $0.id == id }) else { return }
        let top = Float(index) * rowHeight
        if top < scroll.offset {
            scroll.scroll(to: top)
        } else if top + rowHeight > scroll.offset + viewportHeight {
            scroll.scroll(to: top + rowHeight - viewportHeight)
        }
    }

    func toggle(_ path: String) {
        if collapsed.remove(path) == nil { collapsed.insert(path) }
        rebuildRows()
    }

    /// Searches the buffers whose text changed since they were last searched
    /// and reads again the files whose buffers went away. One job at a time:
    /// a sync asked for while one runs is run after it, against whatever the
    /// buffers are by then.
    private func syncBuffers() {
        guard let root, disk != nil else { return }
        if syncRunning {
            syncAgain = true
            return
        }
        let current = buffers(root)
        let standing = Set(current.map(\.path))
        let changed = current.filter { overlay[$0.path]?.text != $0.text }
        let gone = overlay.keys.filter { !standing.contains($0) }
        guard !changed.isEmpty || !gone.isEmpty else { return }

        syncRunning = true
        let epoch = self.epoch
        let options = self.options
        let owner = SearchPanelRef(self)
        DispatchQueue.global(qos: .userInitiated).async {
            let fresh = Self.overlays(for: changed, options: options)
            // A failure leaves the walk's older answer for those paths, which
            // is what the panel showed before the buffer existed.
            let reread = gone.isEmpty ? nil : try? ProjectSearchEngine.search(
                root: root, options: options, cancellation: ProjectSearchCancellation(), paths: gone
            )
            MainQueue.async {
                guard let model = owner.model else { return }
                model.syncRunning = false
                guard model.epoch == epoch else { return }
                for path in gone { model.overlay[path] = nil }
                if let reread { model.disk = model.disk?.rereading(gone, from: reread) }
                model.overlay.merge(fresh) { _, new in new }
                model.publish()
                if model.syncAgain {
                    model.syncAgain = false
                    model.syncBuffers()
                }
            }
        }
    }

    private static func overlays(
        for buffers: [ProjectSearchBuffer], options: ProjectSearchOptions
    ) -> [String: Overlay] {
        var out: [String: Overlay] = [:]
        for buffer in buffers {
            let file = (try? ProjectSearchText.search(buffer, options: options)) ?? nil
            out[buffer.path] = Overlay(text: buffer.text, file: file)
        }
        return out
    }

    private func publish() {
        guard let disk else { return }
        result = disk.replacing(overlay.compactMapValues(\.file))
        rebuildRows()
    }

    private func rebuildRows() {
        guard let result else { return }
        var next: [Entry] = []
        for (index, file) in result.files.enumerated() {
            next.append(Entry(id: file.path, row: .file(index)))
            if !collapsed.contains(file.path) {
                next += file.lines.indices.map {
                    Entry(id: "\(file.path)\n\(file.lines[$0].number)", row: .line(file: index, index: $0))
                }
            }
        }
        rows = next
    }
}

/// Only dereferenced in MainQueue.async. A worker must not keep the window
/// alive, or its pending search could never cancel on teardown.
private final class SearchPanelRef: @unchecked Sendable {
    weak var model: SearchPanelModel?
    init(_ model: SearchPanelModel) { self.model = model }
}
