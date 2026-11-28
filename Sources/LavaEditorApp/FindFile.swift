import Foundation
import LavaProjectCore
import LavaUI
import Observation

enum FindFileMode { case directory, project }

/// Shared by successive minibuffers so reopening does not walk the project
/// again while its file list is fresh. Its state is only used on the UI loop.
@Observable
final class FindFileState: @unchecked Sendable {
    var picker: FindFile?
    @ObservationIgnored var chord = makeFindFileChord()
    var chordPending = false

    func resetChord() {
        chord.reset()
        if chordPending { chordPending = false }
    }
    @ObservationIgnored private var projects: [URL: ProjectIndex] = [:]
    @ObservationIgnored private var refreshing: Set<URL> = []

    func loadProject(_ root: URL, into picker: FindFile) {
        let cached = projects[root]
        if let cached {
            picker.useProject(cached)
            if Date().timeIntervalSince(cached.loadedAt) < 5 { return }
        }
        guard refreshing.insert(root).inserted else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let index = ProjectFiles.list(root: root).map { ProjectIndex(root: root, absolutePaths: $0) }
            MainQueue.async { [weak self] in
                guard let self else { return }
                self.refreshing.remove(root)
                if let index { self.projects[root] = index }
                guard let picker = self.picker, picker.projectRoot == root else { return }
                if let index {
                    picker.useProject(index)
                } else if self.projects[root] == nil {
                    picker.pending = false
                    picker.message = "Could not list project files."
                }
            }
        }
    }
}

struct ProjectIndex: Sendable {
    let loadedAt = Date()
    let paths: [String]
    let filter: FilePathFilter

    init(root: URL, absolutePaths: [String]) {
        let prefixLength = root.path.count + 1
        paths = absolutePaths.map { String($0.dropFirst(prefixLength)) }.sorted()
        filter = FilePathFilter(paths)
    }
}

@Observable
final class FindFile: @unchecked Sendable {
    // Workers only pass immutable results back to this main-loop model.
    struct Row: Identifiable, Sendable {
        let name: String
        let url: URL
        let isDirectory: Bool
        var ranges: [Range<Int>] = []
        var id: URL { url }
    }

    let projectRoot: URL?
    let returnFocus: CommandPalette.ReturnFocus
    @ObservationIgnored let height = CommandPalette.TallestHeight()
    @ObservationIgnored let scroll = ScrollPosition()
    @ObservationIgnored private let base: URL
    @ObservationIgnored private let home: String
    @ObservationIgnored private var directory: URL?
    @ObservationIgnored private var entries: [FindFileEntry] = []
    @ObservationIgnored private var directoryFilter = FilePathFilter([])
    @ObservationIgnored private var project: ProjectIndex?
    @ObservationIgnored private var rankRequest: DispatchWorkItem?
    @ObservationIgnored private var rankGeneration = 0
    @ObservationIgnored private var details: [URL: FindFileDetails?] = [:]
    @ObservationIgnored private var pendingRewrite: (raw: String, text: String)?
    private static let ranking = DispatchQueue(label: "lavaeditor.find-file", qos: .userInitiated)

    private(set) var text: String
    private(set) var rows: [Row] = []
    private(set) var total = 0
    var pending = false
    var message: String?
    var selection = 0
    var fieldFocused = true

    static var homeDirectory: URL {
        if let path = ProcessInfo.processInfo.environment["HOME"], path.hasPrefix("/") {
            return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    init(base: URL, projectRoot: URL?, returnFocus: CommandPalette.ReturnFocus) {
        self.base = base
        self.projectRoot = projectRoot
        self.returnFocus = returnFocus
        home = Self.homeDirectory.path
        text = projectRoot == nil ? FindFilePath.directoryText(base, home: home) : ""
        pending = projectRoot != nil
        if projectRoot == nil { updateDirectory() }
    }

    var prompt: String {
        projectRoot.map { "[\($0.lastPathComponent)] Find file:" } ?? "Find file:"
    }

    var selected: Row? { rows.indices.contains(selection) ? rows[selection] : nil }

    func move(by delta: Int) {
        selection = min(max(0, rows.count - 1), max(0, selection + delta))
    }

    func edit(_ raw: String) {
        guard projectRoot == nil else {
            changeText(raw)
            return
        }
        // A paste can deliver several characters before the field reconciles.
        var edited = raw
        if let rewrite = pendingRewrite, raw.hasPrefix(rewrite.raw) {
            edited = rewrite.text + raw.dropFirst(rewrite.raw.count)
        }
        edited = FindFilePath.restarting(edited, after: text)
        if edited == text + "/" {
            let path = FindFilePath(text)
            if !path.query.isEmpty {
                let literal = path.destination(relativeTo: base, home: home)
                if !FileManager.default.fileExists(atPath: literal.path),
                   total == 1, let row = rows.first, row.isDirectory {
                    edited = path.completing(row.name, directory: true)
                }
            }
        }
        if edited == raw {
            changeText(edited)
        } else {
            pendingRewrite = (raw, edited)
            replaceText(edited)
        }
    }

    func backUp() -> Bool {
        guard projectRoot == nil, !FocusManager.hasTextSelection, text.hasSuffix("/") else { return false }
        if let parent = FindFilePath(text).parentText(home: home) {
            replaceText(parent)
        }
        return true
    }

    func complete(_ row: Row) {
        if projectRoot != nil {
            replaceText(row.name)
        } else {
            replaceText(FindFilePath(text).completing(row.name, directory: row.isDirectory))
        }
    }

    var destination: URL? {
        guard projectRoot == nil, !FindFilePath(text).query.isEmpty else { return nil }
        return FindFilePath(text).destination(relativeTo: base, home: home)
    }

    func enterDirectory(_ url: URL) {
        replaceText(FindFilePath.directoryText(url, home: home))
    }

    func details(for row: Row) -> FindFileDetails? {
        if let cached = details[row.url] { return cached }
        let value = FindFileDetails.read(row.url)
        details[row.url] = .some(value)
        return value
    }

    func useProject(_ index: ProjectIndex) {
        project = index
        rankProject()
    }

    func cancel() {
        rankRequest?.cancel()
        rankGeneration += 1
    }

    /// The field takes the keyboard with its caret at the end
    /// (`selectionOnFocus: .end`), and a rewrite keeps a caret that was at
    /// the end there (`TextField` follows the end of text it is handed).
    /// This once sent the field an End key a frame later — which, while the
    /// field was still taking focus, moved the caret of whatever had it.
    func focusAtEnd() {
        fieldFocused = true
        FrameTasks.after { [weak self] in self?.pendingRewrite = nil }
    }

    private func replaceText(_ value: String) {
        changeText(value)
        focusAtEnd()
    }

    private func changeText(_ value: String) {
        guard text != value else { return }
        text = value
        message = nil
        if projectRoot == nil { updateDirectory() }
        else { rankProject() }
    }

    private func show(_ rows: [Row], total: Int) {
        self.rows = rows
        self.total = total
        selection = 0
        scroll.scroll(to: 0)
    }

    private func updateDirectory() {
        let path = FindFilePath(text)
        let folder = path.directory(relativeTo: base, home: home)
        if folder != directory {
            directory = folder
            entries = (try? FindFileEntry.list(in: folder)) ?? []
            directoryFilter = FilePathFilter(entries.map(\.name))
        }
        let result = directoryFilter.rank(path.query)
        let rows = result.matches.map { match in
            let entry = entries[match.index]
            return Row(name: entry.name, url: folder.appendingPathComponent(entry.name),
                       isDirectory: entry.isDirectory)
        }
        show(rows, total: result.total)
    }

    private func rankProject() {
        guard let projectRoot, let project else { return }
        cancel()
        let generation = rankGeneration
        let query = text
        // The last matches stay up until the new ones replace them. Cleared
        // first, every keystroke drew one frame of an empty list between
        // two that usually agree on the top row — which read as that row
        // blinking. `pending` ("Finding files…") is for the first listing.
        let work = DispatchWorkItem { [weak self] in
            let result = project.filter.rank(query, limit: 250)
            let rows = result.matches.map { match in
                let path = project.paths[match.index]
                return Row(name: path, url: projectRoot.appendingPathComponent(path),
                           isDirectory: false, ranges: match.ranges)
            }
            MainQueue.async { [weak self] in
                guard let self, generation == self.rankGeneration else { return }
                self.pending = false
                self.show(rows, total: result.total)
            }
        }
        rankRequest = work
        Self.ranking.async(execute: work)
    }
}

extension EditorSession {
    func showFindFile(_ mode: FindFileMode) {
        findFile.resetChord()
        if commandPalette != nil { closeCommandPalette() }
        if findFile.picker != nil { closeFindFile() }
        let root = project?.tree.root.standardizedFileURL
        if mode == .project, root == nil {
            notice = "No project folder is open. Finding a file by path."
        }
        let base = active.url?.deletingLastPathComponent() ?? root ?? FindFile.homeDirectory
        let returnFocus: CommandPalette.ReturnFocus
        if let current = terminal.current, FocusManager.isFocused(current.focusID) {
            returnFocus = .terminal(current)
        } else {
            returnFocus = .node(FocusManager.focusedID)
        }
        let picker = FindFile(base: base, projectRoot: mode == .project ? root : nil, returnFocus: returnFocus)
        findFile.picker = picker
        picker.focusAtEnd()
        if let root = picker.projectRoot { findFile.loadProject(root, into: picker) }
    }

    func closeFindFile() {
        guard let picker = findFile.picker else { return }
        picker.cancel()
        findFile.picker = nil
        switch picker.returnFocus {
        case .terminal(let terminal):
            focusTerminal(terminal)
        case .node(let id):
            if let id, FocusManager.refocus(id) { return }
            controller.focus()
        }
    }

    func acceptFindFile(_ picker: FindFile, row: FindFile.Row? = nil) {
        let chosen = row ?? picker.selected
        if let chosen, chosen.isDirectory {
            picker.complete(chosen)
            return
        }
        guard let url = chosen?.url ?? picker.destination else { return }
        let files = FileManager.default
        var isDirectory: ObjCBool = false
        if files.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            if isDirectory.boolValue {
                picker.enterDirectory(url)
                return
            }
        } else if chosen == nil {
            let parent = url.deletingLastPathComponent()
            guard files.fileExists(atPath: parent.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                picker.message = "Parent directory does not exist."
                return
            }
            do {
                try Data().write(to: url, options: .withoutOverwriting)
            } catch {
                picker.message = "Could not create \(url.lastPathComponent): \(error.localizedDescription)"
                return
            }
        }
        let resolved = url.resolvingSymlinksInPath()
        guard (try? files.attributesOfItem(atPath: resolved.path)[.type]) as? FileAttributeType == .typeRegular else {
            picker.message = "Could not open \(url.lastPathComponent) as a file."
            return
        }
        closeFindFile()
        open([url], mode: .normal)
    }
}
