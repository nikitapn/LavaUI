import Foundation
import LavaLSPCore
import LavaProjectCore
import LavaUI
import Observation
#if canImport(LavaEditorExtensionAPI)
import LavaEditorExtensionAPI
#endif

/// The Problems view's own state: which files are folded, which row the
/// keyboard is on, and the problems extensions reported. The language
/// servers' come from `LanguageServers.diagnostics` as they are.
@Observable
final class ProblemsModel {
    var collapsed: Set<String> = []
    /// The row the keyboard is on, by `ProblemList.Row.id`.
    var selected: String?
    /// Whether the list holds the keyboard.
    var focused = false
    @ObservationIgnored let scroll = ScrollPosition()
    @ObservationIgnored var viewportHeight: Float = 0

    /// Extensions' problems, by who reported them (`extension/command`)
    /// and then by file. Each report replaces that reporter's problems for
    /// that file, so a linter that finds nothing on a second run clears
    /// what it found on the first.
    private(set) var fromExtensions: [String: [String: [Problem]]] = [:]

    func publish(_ problems: [Problem], path: String, by reporter: String) {
        if problems.isEmpty {
            fromExtensions[reporter]?[path] = nil
            if fromExtensions[reporter]?.isEmpty == true { fromExtensions[reporter] = nil }
        } else {
            fromExtensions[reporter, default: [:]][path] = problems
        }
    }

    /// Reloading extensions forgets what the old ones said.
    func clearExtensions() {
        fromExtensions = [:]
    }

    func toggle(_ path: String) {
        if collapsed.remove(path) == nil { collapsed.insert(path) }
    }

    /// Scrolls only as far as it takes to show row `index`.
    func keepInSight(_ index: Int, rowHeight: Float) {
        scroll.keepRowInSight(index, rowHeight: rowHeight, viewportHeight: viewportHeight)
    }
}

extension EditorSession {
    /// Every problem known now: what the language servers last published,
    /// and what extensions reported.
    var problemList: ProblemList {
        var all: [Problem] = []
        for (path, diagnostics) in languageServers.diagnostics {
            // Columns are in the server's encoding, which is per server; a
            // file only has diagnostics while it is open, so its tab says
            // which server it was.
            let document = documents.first { $0.url?.standardizedFileURL.path == path }
            let encoding = document.flatMap { languageServers.ready($0.id)?.encoding } ?? .utf16
            all += diagnostics.map { diagnostic in
                Problem(path: path, range: diagnostic.range, encoding: encoding,
                        severity: diagnostic.severity ?? .error, message: diagnostic.message,
                        source: diagnostic.source)
            }
        }
        for files in problems.fromExtensions.values {
            for list in files.values { all += list }
        }
        return ProblemList(all)
    }

    /// View → Problems (Ctrl+Shift+M): the panel on its Problems view with
    /// the keyboard in the list; from the list, hides the panel and goes
    /// back to the text.
    func toggleProblems() {
        if terminal.isOpen, terminal.content == .problems, problems.focused {
            problems.focused = false
            setPanelOpen(false, focusEditor: true)
            return
        }
        showProblems()
    }

    func showProblems() {
        terminal.content = .problems
        setPanelOpen(true)
        problems.focused = true
    }

    /// Shows `problem` in its file. `focus` hands the keyboard to the
    /// editor — Enter, a double click — and is off while the list is walked
    /// with the arrows or clicked once, which keep it, as the search results
    /// do. The caret goes to where the problem starts.
    func openProblem(_ problem: Problem, focus: Bool) {
        let url = URL(fileURLWithPath: problem.path)
        open([url], mode: focus ? .treeDoubleClick : .preview)
        guard active.isLoaded, active.url?.standardizedFileURL == url.standardizedFileURL else { return }
        let positions = DocumentPositions(active.text, encoding: problem.encoding)
        guard let start = positions.characterOffset(at: problem.range.start) else { return }
        select(start..<start, focus: focus)
    }

    #if canImport(LavaEditorExtensionAPI)
    /// An extension's report, as problems for `path`.
    static func problems(_ diagnostics: [ExtensionDiagnostic], path: String, source: String) -> [Problem] {
        diagnostics.prefix(10_000).map { d in
            let severity = LavaLSPCore.DiagnosticSeverity(rawValue: Int(d.severity)) ?? .error
            let start = LSPPosition(line: Int(d.startLine), character: Int(d.startColumn))
            var end = LSPPosition(line: Int(d.endLine), character: Int(d.endColumn))
            if end < start { end = start }
            return Problem(path: path, range: LSPRange(start: start, end: end), encoding: .utf8,
                           severity: severity, message: String(d.message.prefix(4_000)), source: source)
        }
    }
    #endif
}

/// The Problems view: a heading per file, its problems under it. Rows are
/// drawn rather than built, like the search results, and walked the same
/// way — arrows, Home/End, the page keys, Left/Right to fold a file.
struct ProblemsView: View {
    @Bindable var session: EditorSession
    let appearance: EditorAppearance

    private var model: ProblemsModel { session.problems }
    private var theme: Theme { appearance.theme }

    var body: some View {
        let font = session.fonts.tab ?? FontStore.default
        let rowHeight = ((font?.lineHeight ?? 18) + 8).rounded()
        let list = session.problemList
        let rows = list.rows(collapsed: model.collapsed)
        // Read in the body, not in the rows the lazy list builds, so a move
        // of the selection alone redraws the highlight.
        let selected = model.selected
        let root = session.project?.tree.root.path
        return VStack(flexGrow: 1, spacing: 0) {
            if rows.isEmpty {
                Text("No problems have been detected.", color: .muted, font: session.fonts.status)
                    .padding(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                    .agentId("problems-empty")
                Spacer()
            } else {
                ScrollView(.vertical, position: model.scroll) {
                    LazyVStack(rows, rowHeight: rowHeight) { row in
                        switch row.kind {
                        case .file(let f):
                            fileRow(list.files[f], id: row.id, selected: row.id == selected,
                                    root: root, font: font, height: rowHeight)
                        case .problem(let f, let p):
                            problemRow(list.files[f].problems[p], id: row.id,
                                       selected: row.id == selected, font: font, height: rowHeight)
                        }
                    }
                }
                .flexGrow(1)
                .onFrame { [model] frame in model.viewportHeight = frame.h }
                .focusable(onKey: { [session] event in
                    Self.handleKey(event, session: session, rowHeight: rowHeight)
                })
                .focused(Binding(get: { model.focused }, set: { model.focused = $0 }))
                .agentId("problems-list")
            }
        }
        .agentId("problems-panel")
    }

    private func fileRow(
        _ file: ProblemList.File, id: String, selected: Bool, root: String?, font: UIFont?, height: Float
    ) -> some View {
        let shown = ProblemList.displayPath(file.path, root: root)
        let closed = model.collapsed.contains(file.path)
        let model = self.model
        let theme = self.theme
        return Canvas(label: "problems-file", width: .pct(100), height: .pt(height),
                      onTap: {
                          model.selected = id
                          model.toggle(file.path)
                      }) { list, frame in
            guard let font else { return }
            if selected { Self.selection(in: list, frame: frame, theme: theme) }
            let mid = frame.y + frame.h / 2
            let y = mid - font.lineHeight / 2
            let chevron: IconShape = closed ? .path("m9 18 6-6-6-6") : .path("m6 9 6 6 6-6")
            list.strokeIcon([chevron], x: frame.x + 8, y: mid - 7, size: 14, color: theme.textSecondary)
            let x = frame.x + 27
            list.text(shown.name, x: x - 4, y: y, w: frame.w, h: font.lineHeight,
                      color: theme.textPrimary, font: font)
            var after = x + font.shapedRun(shown.name).width + 8
            if !shown.folder.isEmpty {
                list.text(shown.folder, x: after - 4, y: y, w: frame.w, h: font.lineHeight,
                          color: theme.textDim, font: font)
                after += font.shapedRun(shown.folder).width + 8
            }
            let count = String(file.problems.count)
            let textWidth = font.shapedRun(count).width
            let pillWidth = max(18, textWidth + 10)
            list.roundedRect(x: after, y: mid - 8, w: pillWidth, h: 16, color: theme.selectionFill, radius: 8)
            list.text(count, x: after + (pillWidth - textWidth) / 2 - 4, y: y, w: textWidth,
                      h: font.lineHeight, color: theme.textPrimary, font: font)
        }
        .hoverBackground(selected ? .clear : theme.hover)
        .hoverSnap()
        .hoverInset(horizontal: 4, vertical: 1)
        .cornerRadius(5)
        .cursor(.pointer)
        .agentId("problems-file/\(file.path)")
    }

    private func problemRow(
        _ problem: Problem, id: String, selected: Bool, font: UIFont?, height: Float
    ) -> some View {
        let model = self.model
        let theme = self.theme
        let session = self.session
        let message = problem.message.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let severity = Self.editorSeverity(problem.severity)
        return Canvas(label: "problems-row", width: .pct(100), height: .pt(height),
                      onGesture: { gesture in
            guard gesture.phase == .began, gesture.button == 0 else { return }
            model.selected = id
            // A click shows it and leaves the keyboard on the list; a double
            // click goes to work on it.
            session.openProblem(problem, focus: gesture.clickCount > 1)
        }) { list, frame in
            guard let font else { return }
            if selected { Self.selection(in: list, frame: frame, theme: theme) }
            let mid = frame.y + frame.h / 2
            let y = mid - font.lineHeight / 2
            list.strokeIcon(Self.icon(severity), x: frame.x + 30, y: mid - 7, size: 14,
                            color: severity.defaultColor, strokeWidth: 1.6)
            let x = frame.x + 52
            let location = problem.location
            let locationWidth = font.shapedRun(location).width
            let source = problem.source.map { $0 + " " } ?? ""
            let sourceWidth = source.isEmpty ? 0 : font.shapedRun(source).width
            let messageRoom = max(0, frame.w - x - locationWidth - sourceWidth - 24)
            list.pushClip(x: x, y: frame.y, w: messageRoom, h: frame.h)
            list.text(message, x: x - 4, y: y, w: messageRoom + 8, h: font.lineHeight,
                      color: theme.textPrimary, font: font)
            list.popClip()
            let messageWidth = min(messageRoom, font.shapedRun(message).width)
            var after = x + messageWidth + 10
            if !source.isEmpty {
                list.text(source, x: after - 4, y: y, w: sourceWidth, h: font.lineHeight,
                          color: theme.textDim, font: font)
                after += sourceWidth
            }
            list.text(location, x: after - 4, y: y, w: locationWidth, h: font.lineHeight,
                      color: theme.textDim, font: font)
        }
        .hoverBackground(selected ? .clear : theme.hover)
        .hoverSnap()
        .hoverInset(horizontal: 4, vertical: 1)
        .cornerRadius(5)
        .cursor(.pointer)
        .tooltip(problem.message)
        .agentId("problems-row/\(id)")
    }

    static func editorSeverity(_ severity: LavaLSPCore.DiagnosticSeverity) -> LavaUI.DiagnosticSeverity {
        switch severity {
        case .error: .error
        case .warning: .warning
        case .information: .info
        case .hint: .hint
        }
    }

    /// Lucide's circle-x, triangle-alert and info, on their 24-unit grid.
    static func icon(_ severity: LavaUI.DiagnosticSeverity) -> [IconShape] {
        let circle = IconShape.path("M12 2a10 10 0 1 0 0 20a10 10 0 1 0 0-20")
        switch severity {
        case .error: return [circle, .path("m15 9-6 6"), .path("m9 9 6 6")]
        case .warning: return [.path("m21.73 18-8-14a2 2 0 0 0-3.48 0l-8 14A2 2 0 0 0 4 21h16a2 2 0 0 0 1.73-3"),
                               .path("M12 9v4"), .path("M12 17h.01")]
        case .info, .hint: return [circle, .path("M12 16v-4"), .path("M12 8h.01")]
        }
    }

    private static func selection(in list: DrawList, frame: CanvasFrame, theme: Theme) {
        list.roundedRect(x: frame.x + 4, y: frame.y + 1, w: frame.w - 8, h: frame.h - 2,
                         color: theme.selectionFill, radius: 5)
    }

    // MARK: - Keyboard

    /// The search results' keys (`ProjectTree.step`, a file being a folder
    /// of its problems): a problem the arrows reach is shown with the
    /// keyboard left here; Enter opens it to work in; on a file, Enter or
    /// Space folds it. Escape goes back to the text, leaving the panel up.
    private static func handleKey(_ event: KeyEvent, session: EditorSession, rowHeight: Float) -> Bool {
        let model = session.problems
        if event.key == KeyCode.escape {
            model.focused = false
            session.controller.focus()
            return true
        }
        guard event.mods == 0 else { return false }
        let list = session.problemList
        let rows = list.rows(collapsed: model.collapsed)
        let page = max(1, Int(model.viewportHeight / max(1, rowHeight)) - 1)
        let key: ProjectTreeKey
        switch event.key {
        case KeyCode.up: key = .up
        case KeyCode.down: key = .down
        case KeyCode.left: key = .left
        case KeyCode.right: key = .right
        case KeyCode.home: key = .home
        case KeyCode.end: key = .end
        case KeyCode.pageUp: key = .pageUp(rows: page)
        case KeyCode.pageDown: key = .pageDown(rows: page)
        case KeyCode.enter, KeyCode.space:
            guard let id = model.selected, let row = rows.first(where: { $0.id == id }) else { return true }
            if let problem = list.problem(row) {
                if event.key == KeyCode.enter { session.openProblem(problem, focus: true) }
            } else if case .file(let f) = row.kind {
                model.toggle(list.files[f].path)
            }
            return true
        default:
            return false
        }
        let navigation = rows.map { row -> ProjectRow in
            switch row.kind {
            case .file(let f):
                return ProjectRow(node: ProjectNode(name: row.id, path: row.id, isDirectory: true),
                                  depth: 0, isExpanded: !model.collapsed.contains(list.files[f].path))
            case .problem:
                return ProjectRow(node: ProjectNode(name: row.id, path: row.id, isDirectory: false),
                                  depth: 1, isExpanded: false)
            }
        }
        switch ProjectTree.step(key, from: model.selected, in: navigation) {
        case .select(let id):
            model.selected = id
            if let index = rows.firstIndex(where: { $0.id == id }) {
                model.keepInSight(index, rowHeight: rowHeight)
                if let problem = list.problem(rows[index]) { session.openProblem(problem, focus: false) }
            }
        case .expand(let id), .collapse(let id):
            model.toggle(id)
        case .none:
            break
        }
        return true
    }
}
