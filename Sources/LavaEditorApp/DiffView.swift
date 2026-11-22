import Foundation
import LavaDiffCore
import LavaText
import LavaUI

/// Colours a diff is drawn in, light or dark to match the editor.
struct DiffColors {
    let added: Color
    let addedWord: Color
    let addedBar = Color(rgb24: 0x4c_9a_2a)
    let removed: Color
    let removedWord: Color
    let removedBar = Color(rgb24: 0xc4_3d_2f)
    /// Behind the blank rows that keep a line beside its counterpart.
    let filler: Color
    /// The hatching over them.
    let stripe: Color
    let divider: Color

    init(_ appearance: EditorAppearance) {
        let theme = appearance.theme
        if appearance.usesPaper {
            added = Color(rgb24: 0xe5_f2_d5)
            addedWord = Color(rgb24: 0xbf_e0_9c)
            removed = Color(rgb24: 0xfb_e2_dc)
            removedWord = Color(rgb24: 0xf2_b8_ab)
            filler = Color(rgb24: 0xf1_ea_df)
            stripe = Color(rgb24: 0xe2_d8_c8)
        } else {
            added = Color(rgb24: 0x1d_33_26)
            addedWord = Color(rgb24: 0x2d_57_3b)
            removed = Color(rgb24: 0x3a_1f_23)
            removedWord = Color(rgb24: 0x66_2c_33)
            filler = theme.inset
            stripe = Color(rgb24: 0x34_37_3f)
        }
        divider = theme.border
    }
}

/// Two editors, old on the left and new on the right, scrolling as one.
///
/// The left one is read-only. The right one is the document itself when the
/// comparison is against its own text — edits there re-diff as you type —
/// and read-only otherwise (what is staged, a deleted file). Blank hatched
/// rows on either side keep a line beside its replacement; they are not text
/// in either file, so they take no number and no caret.
struct DiffPane: View {
    @Bindable var session: EditorSession
    let model: DiffModel
    let appearance: EditorAppearance
    /// The document editor's style, so both sides look like the editor.
    let style: CodeStyle

    var body: some View {
        let theme = appearance.theme
        let colors = DiffColors(appearance)
        let alignment = model.alignment
        var sideStyle = style
        sideStyle.gapFill = colors.filler
        sideStyle.gapStripe = colors.stripe
        sideStyle.placeholder = nil
        let newText = model.isEditable ? session.text : .constant(model.newText)
        return VStack(flexGrow: 1, spacing: 0) {
            toolbar(theme: theme, colors: colors)
            HStack(flexGrow: 1, spacing: 0) {
                column(title: model.oldTitle, theme: theme) {
                    EditorView(
                        text: .constant(model.oldText),
                        isReadOnly: true,
                        highlighter: model.highlighter,
                        style: sideStyle,
                        font: session.documentFont,
                        showLineNumbers: session.showLineNumbers,
                        wraps: false,
                        visibleLines: 24,
                        lineMarks: Self.marks(alignment.old, fill: colors.removed, bar: colors.removedBar, sign: "−"),
                        onZoom: { session.zoom(by: $0) },
                        lineGaps: alignment.old.gaps.map { EditorLineGap(line: $0.line, rows: $0.rows) },
                        rangeFills: alignment.old.words.map { EditorRangeFill(range: $0, color: colors.removedWord) },
                        scrollLink: model.scrollLink
                    )
                    .flexGrow(1)
                    .agentId("diff-old")
                }
                Divider(.vertical, style: DividerStyle(thickness: 1, spacing: 0, color: colors.divider)).agentId("diff-divider")
                column(title: model.newTitle + (model.isEditable ? "" : " · read-only"), theme: theme) {
                    EditorView(
                        text: newText,
                        isReadOnly: !model.isEditable || session.active.hasInvalidUTF8,
                        highlighter: model.highlighter,
                        style: sideStyle,
                        font: session.documentFont,
                        showLineNumbers: session.showLineNumbers,
                        wraps: false,
                        visibleLines: 24,
                        decorations: model.isEditable ? session.languageDecorations() : [],
                        lineMarks: Self.marks(alignment.new, fill: colors.added, bar: colors.addedBar, sign: "+"),
                        controller: model.newController,
                        onZoom: { session.zoom(by: $0) },
                        semanticHighlights: model.isEditable ? session.languageHighlights() : nil,
                        lineGaps: alignment.new.gaps.map { EditorLineGap(line: $0.line, rows: $0.rows) },
                        rangeFills: alignment.new.words.map { EditorRangeFill(range: $0, color: colors.addedWord) },
                        scrollLink: model.scrollLink,
                        // The document's own history when this side is the
                        // document, so edits made here undo after Done.
                        stateStore: model.isEditable ? session.editorStates : nil,
                        stateKey: model.documentID
                    )
                    .flexGrow(1)
                    .agentId("diff-new")
                }
            }
        }
        .background(theme.inset)
    }

    private static func marks(
        _ side: DiffAlignment.Side, fill: Color, bar: Color, sign: String
    ) -> [EditorLineMark] {
        side.changed.filter { !$0.isEmpty }.map {
            EditorLineMark(lines: $0, bar: bar, fill: fill, sign: sign)
        }
    }

    /// Half the width, a title over an editor. Halves by percentage, not by
    /// growing: an editor's natural width is its widest line, and two growing
    /// editors would split the room by how long their lines are.
    private func column<Content: View>(
        title: String, theme: Theme, @ViewBuilder _ content: () -> Content
    ) -> some View {
        VStack(spacing: 0) {
            HStack(padding: 6, alignment: .center, spacing: 0) {
                Text(title, color: .secondary, font: session.fonts.status)
                    .padding(.leading, 6)
                    .flexShrink(1)
                Spacer()
            }
            .background(theme.panel)
            content()
        }
        .frame(width: .pct(50))
        .flexShrink(1)
    }

    // MARK: - Bar

    private func toolbar(theme: Theme, colors: DiffColors) -> some View {
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
                Text("+\(diff.added)", color: colors.addedBar, font: session.fonts.status)
                    .agentId("diff-added")
                Text("−\(diff.removed)", color: colors.removedBar, font: session.fonts.status)
                    .agentId("diff-removed")
            }
            Spacer()
            Button("‹ Previous") { session.stepDiff(forward: false) }
                .agentId("diff-previous")
            Button("Next ›") { session.stepDiff(forward: true) }
                .agentId("diff-next")
            Button("Done") { session.closeDiff() }
                .agentId("diff-done")
        }
        .background(theme.panel)
    }
}
