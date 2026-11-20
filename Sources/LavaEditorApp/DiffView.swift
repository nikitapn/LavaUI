import Foundation
import LavaDiffCore
import LavaText
import LavaUI

/// Colours a diff is drawn in, light or dark to match the editor.
struct DiffColors {
    let added: Color
    let addedWord: Color
    let removed: Color
    let removedWord: Color
    /// Behind the side of a row that has no line — the room the other side's
    /// extra lines take.
    let filler: Color
    let fold: Color
    let divider: Color

    init(_ appearance: EditorAppearance) {
        let theme = appearance.theme
        if appearance.usesPaper {
            added = Color(rgb24: 0xe5_f2_d5)
            addedWord = Color(rgb24: 0xbf_e0_9c)
            removed = Color(rgb24: 0xfb_e2_dc)
            removedWord = Color(rgb24: 0xf2_b8_ab)
            filler = Color(rgb24: 0xf1_ea_df)
            fold = Color(rgb24: 0xf1_e8_da)
        } else {
            added = Color(rgb24: 0x1d_33_26)
            addedWord = Color(rgb24: 0x2d_57_3b)
            removed = Color(rgb24: 0x3a_1f_23)
            removedWord = Color(rgb24: 0x66_2c_33)
            filler = theme.canvas
            fold = theme.panel
        }
        divider = theme.border
    }
}

/// Two columns, old on the left and new on the right, scrolling as one.
///
/// A list of rows rather than two editors pinned together: the blank rows
/// that keep a line beside its replacement are not text in either file, and
/// two editors would each need to be taught to draw lines they do not have and
/// to scroll in step. Here a row *is* the pair, so alignment and scrolling
/// come with the list. The cost is that this side cannot be edited — that is
/// the editor's job, one keystroke away.
struct DiffPane: View {
    @Bindable var session: EditorSession
    let model: DiffModel
    let appearance: EditorAppearance

    var body: some View {
        let theme = appearance.theme
        let font = session.documentFont ?? FontStore.default
        let lineH = font?.lineHeight ?? 20
        let colors = DiffColors(appearance)
        return VStack(flexGrow: 1, spacing: 0) {
            toolbar(theme: theme)
            titles(theme: theme, colors: colors)
            ScrollView(.vertical, position: session.diffScroll) {
                LazyVStack(model.rows.indices, rowHeight: lineH) { index in
                    row(index, font: font, lineH: lineH, colors: colors, theme: theme)
                }
            }
            .flexGrow(1)
            .agentId("diff-rows")
        }
        .background(theme.inset)
    }

    // MARK: - Bars

    private func toolbar(theme: Theme) -> some View {
        let diff = model.diff
        let summary: String
        if diff.isEmpty {
            summary = diff.newlineAtEndChanged ? "Only the newline at the end differs" : "No changes"
        } else {
            let count = diff.hunks.count
            summary = "\(count) change\(count == 1 ? "" : "s")"
        }
        return HStack(padding: 6, alignment: .center, spacing: 8) {
            Text(summary, color: .primary, font: session.fonts.statusEmphasis)
                .padding(.leading, 10)
                .agentId("diff-summary")
            if !diff.isEmpty {
                Text("+\(diff.added)", color: Color(rgb24: 0x4c_9a_2a), font: session.fonts.status)
                    .agentId("diff-added")
                Text("−\(diff.removed)", color: Color(rgb24: 0xc4_3d_2f), font: session.fonts.status)
                    .agentId("diff-removed")
            }
            Spacer()
            Button("‹ Previous") { session.stepDiff(forward: false) }
                .agentId("diff-previous")
            Button("Next ›") { session.stepDiff(forward: true) }
                .agentId("diff-next")
            Button(model.showsWholeFile ? "Fold Unchanged" : "Whole File") {
                model.showsWholeFile.toggle()
                session.diffScroll.scrollToTop()
            }
            .agentId("diff-whole-file")
            Button("Done") { session.closeDiff() }
                .agentId("diff-done")
        }
        .background(theme.panel)
    }

    /// What each column is, over its own half. Painted rather than laid out,
    /// so the split is the same arithmetic as the rows' and the divider runs
    /// on unbroken from the titles into them.
    private func titles(theme: Theme, colors: DiffColors) -> some View {
        let font = session.fonts.status ?? FontStore.default
        let height = (font?.lineHeight ?? 16) + 12
        let oldTitle = model.oldTitle
        let newTitle = model.newTitle
        return Canvas(label: "diff-titles", width: .pct(100), height: .pt(height)) { list, frame in
            guard let font else { return }
            list.rect(x: frame.x, y: frame.y, w: frame.w, h: frame.h, color: theme.panel)
            let half = ((frame.w - 1) / 2).rounded(.down)
            let textY = frame.y + (frame.h - font.lineHeight) / 2
            for (title, x, w) in [(oldTitle, frame.x, half),
                                  (newTitle, frame.x + half + 1, frame.w - half - 1)] {
                list.pushClip(x: x, y: frame.y, w: w - 10, h: frame.h)
                list.text(title, x: x + 10, y: textY, w: w, h: font.lineHeight,
                          color: theme.textSecondary, font: font)
                list.popClip()
            }
            list.rect(x: frame.x + half, y: frame.y, w: 1, h: frame.h, color: colors.divider)
        }
        .agentId("diff-titles")
    }

    // MARK: - Rows

    private func row(
        _ index: Int, font: UIFont?, lineH: Float, colors: DiffColors, theme: Theme
    ) -> some View {
        let row = model.rows[index]
        let model = self.model
        let style = Language.codeStyle(theme: theme)
        let isFold: Bool
        if case .folded = row.kind { isFold = true } else { isFold = false }
        return Canvas(
            label: "diff-row",
            width: .pct(100), height: .pt(lineH),
            onTap: isFold ? { model.unfold(index) } : nil
        ) { list, frame in
            guard let font else { return }
            DiffRowPainter(
                model: model, row: row, font: font, colors: colors, style: style, theme: theme
            ).paint(list, frame)
        }
        .cursor(isFold ? .pointer : .text)
    }
}

/// Draws one row: each half is a gutter with the line number, the line's
/// fill, the word-level highlights, then the coloured text.
struct DiffRowPainter {
    let model: DiffModel
    let row: DiffRow
    let font: UIFont
    let colors: DiffColors
    let style: CodeStyle
    let theme: Theme

    func paint(_ list: DrawList, _ frame: CanvasFrame) {
        if case .folded(let count) = row.kind {
            list.rect(x: frame.x, y: frame.y, w: frame.w, h: frame.h, color: colors.fold)
            let label = "⋯  \(count) unchanged line\(count == 1 ? "" : "s")"
            let width = font.shapedRun(label).width
            list.text(
                label, x: frame.x + (frame.w - width) / 2 - 4, y: frame.y,
                w: width + 8, h: frame.h, color: theme.textSecondary, font: font
            )
            return
        }
        let half = ((frame.w - 1) / 2).rounded(.down)
        let changes = model.changes(row)
        side(
            list, x: frame.x, y: frame.y, w: half, h: frame.h,
            line: row.old, isNew: false, words: changes?.old
        )
        list.rect(x: frame.x + half, y: frame.y, w: 1, h: frame.h, color: colors.divider)
        side(
            list, x: frame.x + half + 1, y: frame.y, w: frame.w - half - 1, h: frame.h,
            line: row.new, isNew: true, words: changes?.new
        )
    }

    private func side(
        _ list: DrawList, x: Float, y: Float, w: Float, h: Float,
        line: Int?, isNew: Bool, words: [Range<Int>]?
    ) {
        list.pushClip(x: x, y: y, w: w, h: h)
        defer { list.popClip() }

        guard let line else {
            list.rect(x: x, y: y, w: w, h: h, color: colors.filler)
            return
        }
        let changed = row.kind != .context
        if changed {
            list.rect(x: x, y: y, w: w, h: h, color: isNew ? colors.added : colors.removed)
            // A bar down the gutter's edge, so a change still reads at a
            // glance where the fill is faint.
            list.rect(
                x: x, y: y, w: 3, h: h,
                color: isNew ? Color(rgb24: 0x4c_9a_2a) : Color(rgb24: 0xc4_3d_2f)
            )
        }

        let digit = font.shapedRun("0").width
        let gutter = Float(model.lineNumberDigits) * digit + 28
        let number = String(line + 1)
        let numberW = font.shapedRun(number).width
        list.text(
            number, x: x + gutter - 14 - numberW - 4, y: y, w: numberW + 8, h: h,
            color: theme.textDim, font: font
        )

        let text = isNew ? model.newLines[line] : model.oldLines[line]
        let textX = x + gutter
        if let words, !words.isEmpty {
            let run = font.shapedRun(text)
            func columnX(_ column: Int) -> Float {
                let c = max(0, min(column, text.count))
                return run.caretX(for: text.index(text.startIndex, offsetBy: c))
            }
            for range in words {
                let a = columnX(range.lowerBound)
                let b = columnX(range.upperBound)
                list.rect(
                    x: textX + a, y: y + 2, w: max(2, b - a), h: h - 4,
                    color: isNew ? colors.addedWord : colors.removedWord
                )
            }
        }
        let spans = isNew ? model.spans(new: line) : model.spans(old: line)
        list.codeLine(text, spans: spans, style: style, font: font, x: textX, y: y, h: h)
    }
}
