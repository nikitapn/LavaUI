import Foundation
import LavaProjectCore
import LavaUI

/// Project-wide search. Only visible rows become views, including the file
/// headings, so collapsing a file does not change the cost of painting a row.
struct SearchPanel: View {
    @Bindable var session: EditorSession
    let project: ProjectSession
    let appearance: EditorAppearance

    private var model: SearchPanelModel { session.projectSearch }
    private var root: URL { project.tree.root }
    private var theme: Theme { appearance.theme }

    var body: some View {
        let font = session.fonts.tab ?? FontStore.default
        let rowHeight = ((font?.lineHeight ?? 18) + 8).rounded()
        return VStack(flexGrow: 1, spacing: 0) {
            controls(rowHeight: rowHeight)
            if model.root == root, let result = model.result {
                let rows = model.rows
                // Read in the body, not in the rows the lazy list builds, so a
                // move of the selection alone redraws the highlight.
                let selected = model.selected
                ScrollView(.vertical, position: model.scroll) {
                    LazyVStack(rows, rowHeight: rowHeight) { entry in
                        switch entry.row {
                        case .file(let file):
                            fileRow(result.files[file], id: entry.id, selected: entry.id == selected,
                                    font: font, height: rowHeight)
                        case .line(let file, let line):
                            lineRow(result.files[file].lines[line], path: result.files[file].path,
                                    id: entry.id, selected: entry.id == selected,
                                    font: font, height: rowHeight)
                        }
                    }
                }
                .flexGrow(1)
                .onFrame { [model] frame in model.viewportHeight = frame.h }
                // A click on a result gives the list the keyboard; the arrows
                // then walk it, showing each match as they reach it.
                .focusable(onKey: { [session, project, model] event in
                    Self.handleKey(event, session: session, project: project, model: model,
                                   rowHeight: rowHeight)
                })
                .focused(Binding(get: { model.resultsFocused }, set: { model.resultsFocused = $0 }))
                .agentId("search-results")
            } else {
                Spacer()
            }
        }
        .agentId("search-panel")
    }

    private func controls(rowHeight: Float) -> some View {
        VStack(spacing: 7) {
            Text("Search", color: .primary, font: session.fonts.tabSelected)
            HStack(alignment: .center, spacing: 2) {
                field(\.query, placeholder: "Search", id: "search-query", autoFocus: true,
                      selectionOnFocus: .all,
                      onKey: { [session, project, model] event in
                          // Down leaves the field for the results, as in
                          // any search box with a list under it.
                          guard event.key == KeyCode.down, event.mods == 0 else { return false }
                          return Self.enterResults(session: session, project: project, model: model,
                                                   rowHeight: rowHeight)
                      })
                    .focused(Binding(get: { model.queryFocused }, set: { model.queryFocused = $0 }))
                toggle("Aa", "Match Case", id: "search-case", option: \.caseSensitive)
                toggle("ab", "Match Whole Word", id: "search-word", option: \.wholeWord)
                toggle(".*", "Use Regular Expression", id: "search-regex", option: \.regularExpression)
            }
            field(\.include, placeholder: "Files to include", id: "search-include")
                .tooltip("Files to include, separated by commas")
            field(\.exclude, placeholder: "Files to exclude", id: "search-exclude")
                .tooltip("Files to exclude, separated by commas")
            Text(model.summary(for: root), color: .muted, font: session.fonts.status, lineLimit: 2)
                .agentId("search-summary")
        }
        .padding(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
        .flexShrink(0)
    }

    private func field(
        _ key: WritableKeyPath<ProjectSearchOptions, String>, placeholder: String,
        id: String, autoFocus: Bool = false, selectionOnFocus: TextField.FocusSelection = .none,
        onKey: ((KeyEvent) -> Bool)? = nil
    ) -> some View {
        let field = TextField(
            text: Binding(get: { model.options(for: root)[keyPath: key] }, set: { value in
                var options = model.options(for: root)
                guard options[keyPath: key] != value else { return }
                options[keyPath: key] = value
                model.search(root: root, options: options)
            }),
            placeholder: placeholder, font: session.fonts.tab, autoFocus: autoFocus,
            selectionOnFocus: selectionOnFocus,
            restingOutline: true,
            onSubmit: { model.search(root: root, options: model.options(for: root), immediate: true) }
        )
        return (onKey.map { field.onKey($0) } ?? field)
        .flexGrow(1)
        .flexShrink(1)
        .agentId(id)
    }

    private func toggle(
        _ label: String, _ hint: String, id: String,
        option: WritableKeyPath<ProjectSearchOptions, Bool>
    ) -> some View {
        let enabled = model.options(for: root)[keyPath: option]
        return Text(label, color: enabled ? .accent : .muted, font: session.fonts.tabSelected,
                    align: .center, onClick: {
                        var options = model.options(for: root)
                        options[keyPath: option].toggle()
                        model.search(root: root, options: options, immediate: true)
                    })
            .frame(width: .pt(25), height: .pt(26))
            .flexShrink(0)
            .background(enabled ? theme.selectionFill : .clear)
            .hoverBackground(theme.hover)
            .cornerRadius(4)
            .cursor(.pointer)
            .tooltip(hint)
            .agentId(id)
    }

    private func fileRow(
        _ file: ProjectSearchFile, id: String, selected: Bool, font: UIFont?, height: Float
    ) -> some View {
        let name = file.path.split(separator: "/").last.map(String.init) ?? file.path
        let folder = String(file.path.dropLast(name.count + 1))
        let closed = model.collapsed.contains(file.path)
        let model = self.model
        let theme = self.theme
        return Canvas(label: "search-file", width: .pct(100), height: .pt(height),
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

            let count = String(file.count)
            let textWidth = font.shapedRun(count).width
            let pillWidth = max(18, textWidth + 10)
            let pillX = frame.x + frame.w - pillWidth - 12
            list.roundedRect(x: pillX, y: mid - 8, w: pillWidth, h: 16,
                             color: theme.selectionFill, radius: 8)
            list.text(count, x: pillX + (pillWidth - textWidth) / 2 - 4, y: y,
                      w: textWidth, h: font.lineHeight, color: theme.textPrimary, font: font)

            let x = frame.x + 27
            let available = max(0, pillX - x - 6)
            list.pushClip(x: x, y: frame.y, w: available, h: frame.h)
            list.text(name, x: x - 4, y: y, w: available, h: font.lineHeight,
                      color: theme.textPrimary, font: font)
            let folderX = x + font.shapedRun(name).width + 7
            if !folder.isEmpty, folderX < pillX - 6 {
                list.text(folder, x: folderX - 4, y: y, w: pillX - folderX - 6, h: font.lineHeight,
                          color: theme.textDim, font: font)
            }
            list.popClip()
        }
        .hoverBackground(selected ? .clear : theme.hover)
        .hoverInset(horizontal: 4, vertical: 1)
        .cornerRadius(5)
        .cursor(.pointer)
        .agentId("search-file/\(file.path)")
    }

    private func lineRow(
        _ line: ProjectSearchLine, path: String, id: String, selected: Bool,
        font: UIFont?, height: Float
    ) -> some View {
        let model = self.model
        let theme = self.theme
        let font = font ?? FontStore.default
        let number = String(line.number)
        let numberWidth = font?.shapedRun(number).width ?? 0
        let inset = max(44, numberWidth + 22)
        return Canvas(label: "search-match", width: .pct(100), height: .pt(height),
                      onGesture: { gesture in
            guard gesture.phase == .began, gesture.button == 0 else { return }
            let match: Int
            if let font, gesture.localX >= inset {
                let preview = MatchPreview(line, font: font, width: gesture.frame.w - inset - 10)
                match = preview.spans.firstIndex { $0.contains(gesture.localX - inset) } ?? 0
            } else {
                match = 0
            }
            model.selected = id
            // As in the project tree: a click shows the match and leaves the
            // keyboard on the results, for the arrows; a double click keeps
            // the tab and goes to work in it. Handing the editor the keyboard
            // on every click took it straight back from the list the press
            // had just focused, and the arrows went to the document.
            let url = project.tree.url(of: path)
            let opens = gesture.clickCount > 1
            session.openProjectMatch(url, line: line, match: match, focus: opens)
            if opens { Self.keepTab(of: url, session: session) }
        }) { list, frame in
            guard let font else { return }
            if selected { Self.selection(in: list, frame: frame, theme: theme) }
            let x = frame.x + inset
            let y = frame.y + (frame.h - font.lineHeight) / 2
            list.text(number, x: x - numberWidth - 13, y: y, w: numberWidth, h: font.lineHeight,
                      color: theme.textDim, font: font)
            let width = max(0, frame.w - inset - 10)
            let preview = MatchPreview(line, font: font, width: width)
            list.pushClip(x: x, y: frame.y, w: width, h: frame.h)
            for span in preview.highlightRuns {
                list.roundedRect(x: x + span.lowerBound, y: y, w: span.upperBound - span.lowerBound,
                                 h: font.lineHeight, color: appearance.languageFill, radius: 3)
            }
            list.text(line.preview, x: x - preview.pan - 4, y: y, w: width, h: font.lineHeight,
                      color: theme.textPrimary, font: font)
            list.popClip()
        }
        .hoverBackground(selected ? .clear : theme.hover)
        .hoverInset(horizontal: 4, vertical: 1)
        .cornerRadius(5)
        .cursor(.pointer)
        .agentId("search-match/\(path):\(line.number)")
    }

    /// The selected row's plate, the shape of the hover chip around it —
    /// the project tree's, so the sidebar's two lists read alike.
    private static func selection(in list: DrawList, frame: CanvasFrame, theme: Theme) {
        list.roundedRect(x: frame.x + 4, y: frame.y + 1, w: frame.w - 8, h: frame.h - 2,
                         color: theme.selectionFill, radius: 5)
    }

    // MARK: - Keyboard

    /// From the query field into the results: the first match is selected
    /// and shown, and the list takes the keyboard.
    private static func enterResults(
        session: EditorSession, project: ProjectSession, model: SearchPanelModel, rowHeight: Float
    ) -> Bool {
        let rows = model.rows
        guard !rows.isEmpty else { return false }
        let target = rows.first { if case .line = $0.row { return true } else { return false } } ?? rows[0]
        select(target.id, session: session, project: project, model: model, rowHeight: rowHeight)
        model.resultsFocused = true
        return true
    }

    /// Arrows, Home/End and the page keys walk the results
    /// (`ProjectTree.step`, a file being a folder of its lines), and a match
    /// they reach is shown with the keyboard left here. Enter on a match
    /// opens it to work in; on a file it folds. Up from the first row goes
    /// back to the query.
    private static func handleKey(
        _ event: KeyEvent, session: EditorSession, project: ProjectSession,
        model: SearchPanelModel, rowHeight: Float
    ) -> Bool {
        guard event.mods == 0 else { return false }
        let rows = model.rows
        let page = max(1, Int(model.viewportHeight / max(1, rowHeight)) - 1)
        let key: ProjectTreeKey
        switch event.key {
        case KeyCode.up:
            if model.selected == nil || model.selected == rows.first?.id {
                        model.queryFocused = true
                return true
            }
            key = .up
        case KeyCode.down: key = .down
        case KeyCode.left: key = .left
        case KeyCode.right: key = .right
        case KeyCode.home: key = .home
        case KeyCode.end: key = .end
        case KeyCode.pageUp: key = .pageUp(rows: page)
        case KeyCode.pageDown: key = .pageDown(rows: page)
        case KeyCode.enter, KeyCode.space:
            guard let id = model.selected else { return true }
            if let hit = model.line(for: id) {
                if event.key == KeyCode.enter {
                    let url = project.tree.url(of: hit.path)
                    session.openProjectMatch(url, line: hit.line, match: 0)
                    keepTab(of: url, session: session)
                }
            } else {
                model.toggle(id)
            }
            return true
        default:
            return false
        }
        switch ProjectTree.step(key, from: model.selected, in: model.navigationRows) {
        case .select(let id):
            select(id, session: session, project: project, model: model, rowHeight: rowHeight)
        case .expand(let id), .collapse(let id):
            model.toggle(id)
        case .none:
            break
        }
        return true
    }

    /// The preview tab on `url` stops being a preview.
    private static func keepTab(of url: URL, session: EditorSession) {
        let target = url.standardizedFileURL
        if let index = session.documents.firstIndex(where: { $0.url?.standardizedFileURL == target }) {
            session.keepTabOpen(index)
        }
    }

    private static func select(
        _ id: String, session: EditorSession, project: ProjectSession,
        model: SearchPanelModel, rowHeight: Float
    ) {
        model.selected = id
        model.keepInSight(id, rowHeight: rowHeight)
        if let hit = model.line(for: id) {
            session.openProjectMatch(project.tree.url(of: hit.path), line: hit.line, match: 0,
                                     focus: false)
        }
    }
}

/// The same glyph positions drive the highlight and the click target. Pan
/// long prefixes away on a narrow sidebar so the first match stays visible.
private struct MatchPreview {
    let pan: Float
    let spans: [Range<Float>]

    var highlightRuns: [Range<Float>] {
        // A regex such as "." can put a hit on every character. Paint one
        // plate across adjacent hits while keeping their click ranges distinct.
        var runs: [Range<Float>] = []
        for span in spans {
            if let previous = runs.last, span.lowerBound <= previous.upperBound {
                runs[runs.count - 1] = previous.lowerBound..<max(previous.upperBound, span.upperBound)
            } else {
                runs.append(span)
            }
        }
        return runs
    }

    init(_ line: ProjectSearchLine, font: UIFont, width: Float) {
        let run = font.shapedRun(line.preview)
        let positions = line.highlights.map { range in
            let start = run.text.index(run.text.startIndex, offsetBy: range.lowerBound)
            let end = run.text.index(start, offsetBy: range.count)
            return (run.caretX(for: start), run.caretX(for: end))
        }
        let pan = max(0, (positions.first?.0 ?? 0) - max(0, width) * 0.28)
        self.pan = pan
        spans = positions.map { start, end in
            (start - pan)..<(max(start + 2, end) - pan)
        }
    }
}
