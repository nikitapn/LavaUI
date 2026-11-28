import Foundation
import LavaProjectCore
import LavaUI

/// What git says changed, and committing it — VS Code's Source Control view:
/// a message, a Commit button, then Staged Changes and Changes.
struct SourceControlPanel: View {
    @Bindable var session: EditorSession
    let project: ProjectSession
    let appearance: EditorAppearance

    /// Lucide glyphs (ISC), as SVG path data.
    enum Glyph {
        static let plus: [IconShape] = [.path("M5 12h14"), .path("M12 5v14")]
        static let minus: [IconShape] = [.path("M5 12h14")]
        static let discard: [IconShape] = [
            .path("M9 14 4 9l5-5"),
            .path("M4 9h10.5a5.5 5.5 0 0 1 5.5 5.5a5.5 5.5 0 0 1-5.5 5.5H11"),
        ]
        static let file: [IconShape] = [
            .path("M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7Z"),
            .path("M14 2v4a2 2 0 0 0 2 2h4"),
        ]
        static let refresh: [IconShape] = [
            .path("M3 12a9 9 0 0 1 9-9 9.75 9.75 0 0 1 6.74 2.74L21 8"), .path("M21 3v5h-5"),
            .path("M21 12a9 9 0 0 1-9 9 9.75 9.75 0 0 1-6.74-2.74L3 16"), .path("M8 16H3v5"),
        ]
        static let check: [IconShape] = [.path("M20 6 9 17l-5-5")]
    }

    var body: some View {
        let model = project.sourceControl
        let theme = appearance.theme
        let list = SourceControlList(project.changes)
        let rows = list.rows(collapsed: model.collapsed)
        let font = session.fonts.tab ?? FontStore.default
        let rowH = ((font?.lineHeight ?? 18) + 8).rounded()
        let colors = GitMarkColors(appearance)
        // Read here, not in the rows the lazy list builds, so a move of the
        // selection alone redraws its highlight and buttons.
        let selected = model.selected
        let session = self.session, project = self.project
        return VStack(flexGrow: 1, spacing: 0) {
            header(theme: theme)
            if !project.isInRepository {
                Text("This folder is not in a git repository.", color: .muted,
                     font: session.fonts.status)
                    .padding(EdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14))
            } else {
                commitBox(list: list, model: model, theme: theme)
                if let item = model.pendingDiscard { discardQuestion(item, theme: theme) }
                if let error = model.error { line(error, color: colors.deleted, id: "scm-error") }
                if let done = model.committed { line("Committed \(done)", color: colors.added, id: "scm-committed") }
                ScrollView(.vertical, position: model.scroll) {
                    LazyVStack(rows, rowHeight: rowH) { entry in
                        row(entry, selected: entry.id == selected,
                            font: font, colors: colors, theme: theme, rowH: rowH)
                    }
                }
                .flexGrow(1)
                .onFrame { [model] frame in model.viewportHeight = frame.h }
                // A click on a row gives the list the keyboard; the arrows
                // then walk it, showing each file's diff as they reach it.
                .focusable(onKey: { event in
                    Self.handleKey(event, session: session, project: project, rowHeight: rowH)
                })
                .focused(Binding(get: { model.listFocused }, set: { model.listFocused = $0 }))
                .agentId("scm-rows")
            }
        }
        .agentId("source-control-panel")
    }

    // MARK: - Top

    private func header(theme: Theme) -> some View {
        HStack(padding: 0, alignment: .center, spacing: 8) {
            Text("Source Control", color: .primary, font: session.fonts.tabSelected, lineLimit: 1)
                .flexShrink(1)
            Spacer()
            iconButton(Glyph.refresh, tooltip: "Refresh", id: "scm-refresh", theme: theme) {
                project.refreshStatus()
            }
        }
        .padding(EdgeInsets(top: 10, leading: 14, bottom: 8, trailing: 8))
    }

    private func commitBox(list: SourceControlList, model: SourceControlModel, theme: Theme) -> some View {
        let branch = project.branch.map { " on '\($0)'" } ?? ""
        let commitsAll = list.staged.isEmpty && !list.changes.isEmpty
        let enabled = !model.busy && !list.isClean && list.conflicts.isEmpty
        let label = model.busy ? "Working…" : (commitsAll ? "Commit All" : "Commit")
        let session = self.session
        return VStack(padding: 0, spacing: 8) {
            TextField(
                text: Binding(get: { model.message }, set: { model.message = $0 }),
                placeholder: "Message (Enter to commit\(branch))",
                font: session.fonts.tab,
                onSubmit: { session.commit() }
            )
            .onKey { [project] event in
                // Down leaves the message for the list under it.
                guard event.key == KeyCode.down, event.mods == 0, !model.message.contains("\n")
                else { return false }
                return Self.enterList(session: session, project: project)
            }
            .focused(Binding(get: { model.messageFocused }, set: { model.messageFocused = $0 }))
            .agentId("scm-message")
            HStack(height: .pt(34), padding: 0, alignment: .center, spacing: 6, onClick: {
                if enabled { session.commit() }
            }) {
                Spacer()
                Icon(Glyph.check, size: 15, color: .white, strokeWidth: 2.4)
                Text(label, color: .white, font: session.fonts.tabSelected)
                Spacer()
            }
            .background(enabled ? theme.accent : theme.textDim)
            .cornerRadius(8)
            .cursor(enabled ? .pointer : .arrow)
            .tooltip(commitsAll ? "Nothing is staged: commit every change, new files included" : "Commit what is staged")
            .agentId("scm-commit")
        }
        .padding(EdgeInsets(top: 0, leading: 12, bottom: 10, trailing: 12))
    }

    private func discardQuestion(_ item: SourceControlList.Item, theme: Theme) -> some View {
        let question = item.isUntracked
            ? "Move \(item.name) to the Trash? It is not tracked, so git cannot bring it back."
            : "Discard the changes to \(item.name)? They are not staged, so git cannot bring them back."
        let session = self.session, project = self.project
        return VStack(padding: 10, spacing: 8) {
            Text(question, color: .primary, font: session.fonts.status)
            HStack(alignment: .center, spacing: 8) {
                Button(item.isUntracked ? "Move to Trash" : "Discard") { session.confirmDiscard() }
                    .agentId("scm-discard-confirm")
                Button("Cancel") { project.sourceControl.pendingDiscard = nil }
                    .agentId("scm-discard-cancel")
            }
        }
        .background(theme.inset)
        .cornerRadius(8)
        .padding(EdgeInsets(top: 0, leading: 12, bottom: 8, trailing: 12))
    }

    private func line(_ text: String, color: Color, id: String) -> some View {
        Text(text, color: color, font: session.fonts.status)
            .padding(EdgeInsets(top: 0, leading: 14, bottom: 8, trailing: 14))
            .agentId(id)
    }

    private func iconButton(
        _ glyph: [IconShape], tooltip: String, id: String, theme: Theme,
        action: @escaping () -> Void
    ) -> some View {
        HStack(padding: 5, alignment: .center, onClick: action) {
            Icon(glyph, size: 15, color: theme.textSecondary, strokeWidth: 2)
        }
        .hoverBackground(theme.hover)
        .cornerRadius(6)
        .cursor(.pointer)
        .tooltip(tooltip)
        .agentId(id)
    }

    // MARK: - Rows

    /// An action button drawn into a row, and what it does.
    private struct RowAction {
        var glyph: [IconShape]
        var run: () -> Void
    }

    private func actions(for row: SourceControlList.Row) -> [RowAction] {
        let session = self.session
        switch row {
        case .header(let group, _):
            let items = SourceControlList(project.changes).items(group)
            switch group {
            case .staged: return [RowAction(glyph: Glyph.minus) { session.unstage(items) }]
            case .changes: return items.isEmpty ? [] : [RowAction(glyph: Glyph.plus) { session.stage(items) }]
            case .conflicts: return []
            }
        case .item(let item):
            let url = project.repository?.root.appendingPathComponent(item.path)
            var out: [RowAction] = []
            if item.change != .deleted, let url {
                out.append(RowAction(glyph: Glyph.file) { session.open([url]) })
            }
            switch item.group {
            case .staged:
                out.append(RowAction(glyph: Glyph.minus) { session.unstage([item]) })
            case .changes, .conflicts:
                if item.group == .changes {
                    out.append(RowAction(glyph: Glyph.discard) { session.requestDiscard(item) })
                }
                // Staging a conflicted file is how git is told it is resolved.
                out.append(RowAction(glyph: Glyph.plus) { session.stage([item]) })
            }
            return out
        }
    }

    private static let actionWidth: Float = 24
    private static let letterWidth: Float = 26

    private func row(
        _ row: SourceControlList.Row, selected: Bool, font: UIFont?, colors: GitMarkColors,
        theme: Theme, rowH: Float
    ) -> some View {
        let model = project.sourceControl
        let key = row.id
        let actions = model.hovered == key || selected ? actions(for: row) : []
        let session = self.session
        return Canvas(
            label: "scm-row", width: .pct(100), height: .pt(rowH),
            onGesture: { gesture in
                guard gesture.phase == .ended, gesture.button == 0,
                      gesture.localX >= 0, gesture.localX < gesture.frame.w,
                      gesture.localY >= 0, gesture.localY < gesture.frame.h else { return }
                // Buttons are right-aligned, ahead of the letter column.
                let right = gesture.frame.w - Self.letterWidth
                let slot = Int((right - gesture.localX) / Self.actionWidth)
                if gesture.localX < right, slot >= 0, slot < actions.count {
                    actions[actions.count - 1 - slot].run()
                    return
                }
                switch row {
                case .header(let group, _):
                    if model.collapsed.contains(group) { model.collapsed.remove(group) }
                    else { model.collapsed.insert(group) }
                case .item(let item):
                    model.selected = key
                    session.compareChange(item)
                }
            },
            onHover: { inside in
                if inside { model.hovered = key } else if model.hovered == key { model.hovered = nil }
            }
        ) { list, frame in
            guard let font else { return }
            if selected {
                list.roundedRect(x: frame.x + 6, y: frame.y + 1, w: frame.w - 12, h: frame.h - 2,
                                 color: theme.selectionFill, radius: 5)
            }
            let midY = frame.y + frame.h / 2
            let textY = frame.y + (frame.h - font.lineHeight) / 2
            var right = frame.x + frame.w - Self.letterWidth
            // The buttons, drawn where the gesture above looks for them.
            for (i, action) in actions.reversed().enumerated() {
                let x = right - Float(i + 1) * Self.actionWidth
                list.strokeIcon(action.glyph, x: x + 4, y: midY - 8, size: 16,
                                color: theme.textSecondary, strokeWidth: 2)
            }
            right -= Float(actions.count) * Self.actionWidth
            switch row {
            case .header(let group, let count):
                let chevronX = frame.x + 12
                let c = theme.textSecondary
                if model.collapsed.contains(group) {
                    list.line(x1: chevronX + 2, y1: midY - 4, x2: chevronX + 6, y2: midY, color: c)
                    list.line(x1: chevronX + 6, y1: midY, x2: chevronX + 2, y2: midY + 4, color: c)
                } else {
                    list.line(x1: chevronX, y1: midY - 2, x2: chevronX + 4, y2: midY + 2, color: c)
                    list.line(x1: chevronX + 4, y1: midY + 2, x2: chevronX + 8, y2: midY - 2, color: c)
                }
                list.text(group.title, x: frame.x + 26 - 4, y: textY, w: right, h: font.lineHeight,
                          color: theme.textPrimary, font: font)
                // The count as a pill in the letter column.
                let label = String(count)
                let w = max(20, font.shapedRun(label).width + 10)
                let px = frame.x + frame.w - 8 - w
                list.roundedRect(x: px, y: midY - 9, w: w, h: 18, color: theme.selectionFill, radius: 9)
                let tw = font.shapedRun(label).width
                list.text(label, x: px + (w - tw) / 2 - 4, y: textY, w: w, h: font.lineHeight,
                          color: theme.textSecondary, font: font)
            case .item(let item):
                let ink = colors.color(for: item)
                let nameX = frame.x + 30
                let name = String(item.name)
                let nameW = font.shapedRun(name).width
                list.pushClip(x: nameX, y: frame.y, w: max(0, right - nameX - 4), h: frame.h)
                list.text(name, x: nameX - 4, y: textY, w: nameW + 8, h: font.lineHeight,
                          color: ink, font: font)
                if !item.folder.isEmpty {
                    list.text(item.folder, x: nameX + nameW + 8 - 4, y: textY, w: right,
                              h: font.lineHeight, color: theme.textDim, font: font)
                }
                list.popClip()
                let letter = item.letter
                let lw = font.shapedRun(letter).width
                list.text(letter, x: frame.x + frame.w - 14 - lw - 4, y: textY, w: lw + 8,
                          h: font.lineHeight, color: ink, font: font)
            }
        }
        // Same chip as the explorer's; see `ProjectExplorer.row`.
        .hoverBackground(selected ? .clear : theme.hover)
        .hoverInset(horizontal: 6, vertical: 1)
        .cornerRadius(5)
        .hoverSnap()
        .cursor(.pointer)
        .agentId(key)
    }
}

extension SourceControlPanel {
    // MARK: - Keyboard

    /// From the message into the list: the first file is selected and its
    /// diff shown, and the list takes the keyboard.
    fileprivate static func enterList(session: EditorSession, project: ProjectSession) -> Bool {
        let model = project.sourceControl
        let rows = SourceControlList(project.changes).rows(collapsed: model.collapsed)
        guard let first = rows.first(where: { if case .item = $0 { return true } else { return false } })
                ?? rows.first else { return false }
        select(first.id, session: session, project: project, rowHeight: nil)
        model.listFocused = true
        return true
    }

    /// The same keys as the project tree and the search results
    /// (`ProjectTree.step`, a group being a folder of its files), and a file
    /// they reach shows its diff with the keyboard left here. On a file,
    /// Space stages or unstages it and moves on to the next in its group,
    /// Delete asks to discard it, and Enter opens it to work in; on a group,
    /// Enter and Space fold it. While a discard is being asked about, Enter
    /// answers yes and Escape no. Up from the top row goes to the message.
    fileprivate static func handleKey(
        _ event: KeyEvent, session: EditorSession, project: ProjectSession, rowHeight: Float
    ) -> Bool {
        let model = project.sourceControl
        if model.pendingDiscard != nil {
            switch event.key {
            case KeyCode.enter:
                session.confirmDiscard()
                return true
            case KeyCode.escape:
                model.pendingDiscard = nil
                return true
            default:
                break
            }
        }
        guard event.mods == 0 else { return false }
        let list = SourceControlList(project.changes)
        let rows = list.rows(collapsed: model.collapsed)
        let page = max(1, Int(model.viewportHeight / max(1, rowHeight)) - 1)
        let current = rows.first { $0.id == model.selected }
        let key: ProjectTreeKey
        switch event.key {
        case KeyCode.up:
            if model.selected == nil || model.selected == rows.first?.id {
                model.messageFocused = true
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
        case KeyCode.enter, KeyCode.space, KeyCode.delete:
            switch current {
            case .header(let group, _)?:
                guard event.key != KeyCode.delete else { return true }
                if model.collapsed.remove(group) == nil { model.collapsed.insert(group) }
            case .item(let item)?:
                act(on: item, key: event.key, list: list, session: session, project: project,
                    rowHeight: rowHeight)
            case nil:
                break
            }
            return true
        default:
            return false
        }
        switch ProjectTree.step(key, from: model.selected,
                                in: list.navigationRows(collapsed: model.collapsed)) {
        case .select(let id):
            select(id, session: session, project: project, rowHeight: rowHeight)
        case .expand(let id), .collapse(let id):
            if let group = rows.first(where: { $0.id == id }).flatMap(Self.group(of:)) {
                if model.collapsed.remove(group) == nil { model.collapsed.insert(group) }
            }
        case .none:
            break
        }
        return true
    }

    private static func act(
        on item: SourceControlList.Item, key: Int32, list: SourceControlList,
        session: EditorSession, project: ProjectSession, rowHeight: Float
    ) {
        let model = project.sourceControl
        let id = SourceControlList.Row.item(item).id
        switch key {
        case KeyCode.enter:
            guard item.change != .deleted, let root = project.repository?.root else { return }
            if session.visibleDiff != nil { session.closeDiff() }
            session.open([root.appendingPathComponent(item.path)])
            FrameTasks.after { [controller = session.controller] in controller.focus() }
        case KeyCode.space:
            // Chosen before the list changes: the status comes back from a
            // worker, and by then this row is gone from its group.
            let next = list.selectionAfterRemoving(id, collapsed: model.collapsed)
            if item.group == .staged { session.unstage([item]) } else { session.stage([item]) }
            if let next { select(next, session: session, project: project, rowHeight: rowHeight) }
        case KeyCode.delete:
            guard item.group == .changes else { return }
            session.requestDiscard(item)
        default:
            break
        }
    }

    private static func group(of row: SourceControlList.Row) -> SourceControlList.Group? {
        if case .header(let group, _) = row { return group }
        return nil
    }

    /// Selects row `id`, keeps it in sight, and shows a file's diff.
    private static func select(
        _ id: String, session: EditorSession, project: ProjectSession, rowHeight: Float?
    ) {
        let model = project.sourceControl
        model.selected = id
        let rows = SourceControlList(project.changes).rows(collapsed: model.collapsed)
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        if let rowHeight {
            model.scroll.keepRowInSight(index, rowHeight: rowHeight, viewportHeight: model.viewportHeight)
        }
        if case .item(let item) = rows[index] { session.compareChange(item) }
    }
}

extension GitMarkColors {
    func color(for item: SourceControlList.Item) -> Color {
        if item.group == .conflicts { return conflicted }
        if item.isUntracked { return added }
        switch item.change {
        case .added: return added
        case .deleted: return deleted
        case .updatedUnmerged: return conflicted
        default: return modified
        }
    }
}
