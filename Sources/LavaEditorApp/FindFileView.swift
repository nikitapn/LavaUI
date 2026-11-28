import LavaUI

struct FindFileView: View {
    let session: EditorSession
    let picker: FindFile
    let appearance: EditorAppearance

    static func placement(for picker: FindFile) -> OverlayPlacement {
        let tallest = picker.height
        return OverlayPlacement { context in
            let cap = max(80, context.viewport.height * 0.45)
            let height = min(cap, max(tallest.value, context.idealSize.height))
            tallest.value = height
            return OverlayFrame(x: 0, y: context.viewport.height - height,
                                width: context.viewport.width, height: height)
        }
    }

    static func style(session: EditorSession, picker: FindFile, theme: Theme) -> OverlayStyle {
        var style = OverlayStyle(background: theme.panel, border: theme.border, cornerRadius: 0,
                                 padding: 0, modal: true)
        style.onKey = { event in
            switch event.key {
            case KeyCode.escape,
                 KeyCode.g where event.control,
                 KeyCode.x where event.alt:
                session.closeFindFile()
            case KeyCode.enter:
                session.acceptFindFile(picker)
            case KeyCode.tab:
                if let row = picker.selected { picker.complete(row) }
            case KeyCode.up,
                 KeyCode.p where event.control:
                picker.move(by: -1)
            case KeyCode.down,
                 KeyCode.n where event.control:
                picker.move(by: 1)
            case KeyCode.pageUp:
                picker.move(by: -10)
            case KeyCode.pageDown:
                picker.move(by: 10)
            case KeyCode.backspace where !event.control && !event.alt && !event.superKey:
                return picker.backUp()
            default:
                return false
            }
            return true
        }
        style.onUnfocusedText = { character in
            guard !character.isNewline else { return }
            picker.edit(picker.text + String(character))
            picker.fieldFocused = true
        }
        return style
    }

    var body: some View {
        let theme = appearance.theme
        let rowHeight = max(26, ((session.fonts.tab ?? FontStore.default)?.lineHeight ?? 0) + 8)
        let selection = picker.selection
        let selectedID = picker.selected?.id
        return VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                Text(picker.prompt, color: theme.accent, font: session.fonts.tab, lineLimit: 1)
                TextField(
                    text: Binding(get: { picker.text }, set: { picker.edit($0) }),
                    placeholder: picker.projectRoot == nil ? "Path" : "File name",
                    font: session.fonts.tab, selectionOnFocus: .end,
                    focusRing: FocusRingStyle.none, restingOutline: false
                )
                .focused(Binding(get: { picker.fieldFocused }, set: { picker.fieldFocused = $0 }))
                .flexGrow(1)
                .agentId("find-file-field")
                Text("\(selectedID == nil ? 0 : selection + 1)/\(picker.total)",
                     color: .muted, font: session.fonts.status, lineLimit: 1)
                    .agentId("find-file-count")
            }
            .padding(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))

            if let message = picker.message ?? (picker.pending ? "Finding files…" :
                (picker.rows.isEmpty ? "No matching files." : nil)) {
                Text(message, color: .muted, font: session.fonts.status)
                    .padding(EdgeInsets(top: 4, leading: 12, bottom: 8, trailing: 12))
                    .agentId("find-file-message")
            }
            if !picker.rows.isEmpty {
                ScrollView(.vertical, position: picker.scroll) {
                    LazyVStack(picker.rows, rowHeight: rowHeight, scrollTarget: selection) { row in
                        self.row(row, height: rowHeight, isSelected: row.id == selectedID, theme: theme)
                    }
                    .padding(EdgeInsets(top: 0, leading: 4, bottom: 4, trailing: 4))
                }
                // Placement measures before the lazy list mounts any cells.
                .frame(height: .pt(Float(picker.rows.count) * rowHeight + 4))
                .flexGrow(0)
                .flexShrink(1)
                .agentId("find-file-rows")
            }
        }
        .frame(width: .pct(100))
        .flexShrink(1)
        .agentId("find-file")
    }

    private func row(_ row: FindFile.Row, height: Float, isSelected: Bool, theme: Theme) -> some View {
        let details = picker.details(for: row)
        let session = self.session
        return HStack(alignment: .center, spacing: 8, onClick: { session.acceptFindFile(picker, row: row) }) {
            name(row, theme: theme)
                .flexGrow(1)
                .flexShrink(1)
            column(details?.permissions, width: 90)
            column(details?.size, width: 50)
            column(details?.modified, width: 112)
        }
        .padding(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
        .frame(height: .pt(height))
        .background(isSelected ? theme.selectionFill : .clear)
        .hoverBackground(isSelected ? theme.selectionFill : theme.hover)
        .hoverSnap()
        .cornerRadius(6)
        .cursor(.pointer)
        .scrollIntoView(when: isSelected)
    }

    private func column(_ value: String?, width: Float) -> some View {
        Text(value ?? "—", color: .muted, font: session.fonts.status, lineLimit: 1)
            .frame(width: .pt(width))
            .flexShrink(0)
    }

    @ViewBuilder
    private func name(_ row: FindFile.Row, theme: Theme) -> some View {
        if row.ranges.isEmpty {
            Text(row.name + (row.isDirectory ? "/" : ""), color: row.isDirectory ? theme.accent : .primary,
                 font: session.fonts.tab, lineLimit: 1)
        } else {
            let font = session.fonts.tab ?? FontStore.default
            let emphasis = session.fonts.tabSelected ?? font
            let runs = nameRuns(row)
            Canvas(label: row.name, height: .pt(font?.lineHeight ?? 18)) { draw, frame in
                guard frame.w > 0 else { return }
                draw.pushClip(x: frame.x, y: frame.y, w: frame.w, h: frame.h)
                var x = frame.x
                for run in runs where !run.text.isEmpty {
                    let face = run.matched ? emphasis : font
                    draw.text(run.text, x: x, y: frame.y, w: frame.w, h: frame.h,
                              color: run.matched ? theme.accent : theme.textPrimary, font: face)
                    x += face?.shape(run.text).reduce(0) { $0 + $1.advance } ?? 0
                    if x >= frame.x + frame.w { break }
                }
                draw.popClip()
            }
        }
    }

    private func nameRuns(_ row: FindFile.Row) -> [(text: String, matched: Bool)] {
        let chars = Array(row.name)
        var runs: [(String, Bool)] = []
        var start = 0
        for range in row.ranges {
            if start < range.lowerBound { runs.append((String(chars[start..<range.lowerBound]), false)) }
            runs.append((String(chars[range]), true))
            start = range.upperBound
        }
        if start < chars.count { runs.append((String(chars[start...]), false)) }
        return runs
    }

}
