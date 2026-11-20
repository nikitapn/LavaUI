import Foundation
import LavaExplorerCore
import LavaUI

/// Many names at once. On the left the new names as text, one a line, in an
/// editor: typing, selecting a column of them, pasting a list from elsewhere
/// all just work. The toolbar's transforms rewrite that same text, so they
/// compose with typing. On the right, what would happen — only the lines
/// that change, and the ones that cannot.
///
/// It takes the place of the pane's list rather than opening a window: the
/// list is what it is about, and the address bar above stays, saying which
/// folder.
struct BulkRenamePane: View {
    @Bindable var session: ExplorerSession
    let draft: ExplorerSession.BulkRenameDraft

    /// The explorer's switch: the accent when on, as the panel's cards draw it.
    static var toggleStyle: ToggleStyle {
        let look = ExplorerLook.current
        return ToggleStyle(trackWidth: 36, trackHeight: 20, knobInset: 3,
                           offTrack: look.press, onTrack: look.accent,
                           knob: Color(r: 1, g: 1, b: 1), foreground: look.text,
                           labelGap: 8, duration: 0.15)
    }

    var body: some View {
        let look = ExplorerLook.current
        let fonts = explorerFonts
        let plan = draft.plan
        return VStack(flexGrow: 1, padding: 0, spacing: 0) {
            HStack(padding: 0, alignment: .center, spacing: 12) {
                VStack(flexGrow: 1, padding: 0, spacing: 2) {
                    Text("Rename \(ExplorerSession.items(draft.names.count))",
                         color: look.text, font: fonts?.display19, lineLimit: 1)
                    Text("Line n is item n’s new name. Type, paste a list, or use the tools.",
                         color: look.soft, font: fonts?.caption, lineLimit: 1)
                }
                .flexShrink(1)
                Toggle(
                    "Keep extensions",
                    isOn: session.bulkRenameField(\.keepExtensions, empty: true),
                    style: Self.toggleStyle,
                    font: fonts?.crumb
                )
                .agentId("bulk-keep-extensions")
            }
            .padding(EdgeInsets(top: 4, leading: 20, bottom: 12, trailing: 16))
            replaceRow
            caseAndNumberRow
            if let error = draft.transformError {
                Text(error, color: DiagnosticColors.error, font: fonts?.caption, lineLimit: 1)
                    .padding(EdgeInsets(top: 0, leading: 20, bottom: 6, trailing: 16))
                    .agentId("bulk-transform-error")
            }
            HSplitView(
                fraction: $session.bulkRenameFraction, minLeading: 200, minTrailing: 200,
                style: PaneChrome.splitStyle
            ) {
                VStack(flexGrow: 1, padding: 0, spacing: 0) {
                    EditorView(
                        text: session.bulkRenameText,
                        showLineNumbers: true,
                        decorations: Self.decorations(plan, text: draft.text),
                        controller: session.bulkRenameEditor
                    )
                    .flexGrow(1)
                    .agentId("bulk-editor")
                }
                .background(look.card)
                .border(look.divider)
                .cornerRadius(14)
                .clipped()
            } trailing: {
                ChangeList(session: session, plan: plan)
            }
            .flexGrow(1)
            .padding(EdgeInsets(top: 4, leading: 12, bottom: 0, trailing: 12))
            footer(plan)
        }
        .flexGrow(1)
    }

    /// Find and replace, in groups that keep together and wrap onto a second
    /// line in a narrow pane rather than run off its edge.
    private var replaceRow: some View {
        let look = ExplorerLook.current
        let fonts = explorerFonts
        return HStack(padding: 0, alignment: .center, spacing: 8, wraps: true) {
            HStack(padding: 0, alignment: .center, spacing: 8) {
                Text("Replace", color: look.soft, font: fonts?.crumbSemi)
                DialogField(
                    text: session.bulkRenameField(\.find, empty: ""),
                    placeholder: draft.regex ? "Pattern, e.g. IMG_(\\d+)" : "Find",
                    id: "bulk-find"
                ) { session.replaceInBulkRename() }
                    .flexGrow(1)
            }
            .frame(minWidth: 180)
            .flexGrow(1)
            .padding(.bottom, 8)
            HStack(padding: 0, alignment: .center, spacing: 8) {
                Text("with", color: look.soft, font: fonts?.crumbSemi)
                DialogField(
                    text: session.bulkRenameField(\.replacement, empty: ""),
                    placeholder: draft.regex ? "e.g. rome-$1" : "",
                    id: "bulk-replacement"
                ) { session.replaceInBulkRename() }
                    .flexGrow(1)
            }
            .frame(minWidth: 160)
            .flexGrow(1)
            .padding(.bottom, 8)
            HStack(padding: 0, alignment: .center, spacing: 8) {
                Toggle("Regex", isOn: session.bulkRenameField(\.regex, empty: false),
                       style: Self.toggleStyle, font: fonts?.crumb)
                    .agentId("bulk-regex")
                DialogButton("Replace All", id: "bulk-replace") { session.replaceInBulkRename() }
            }
            .flexShrink(0)
            .padding(.bottom, 8)
        }
        .padding(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 16))
    }

    /// The case buttons, then numbering — two groups, wrapping like the row
    /// above.
    private var caseAndNumberRow: some View {
        let look = ExplorerLook.current
        return HStack(padding: 0, alignment: .center, spacing: 8, wraps: true) {
            HStack(padding: 0, alignment: .center, spacing: 6) {
                DialogButton("lowercase", id: "bulk-lowercase") { session.applyBulkTransform(.lowercase) }
                DialogButton("UPPERCASE", id: "bulk-uppercase") { session.applyBulkTransform(.uppercase) }
                DialogButton("Title Case", id: "bulk-titlecase") { session.applyBulkTransform(.titlecase) }
            }
            // Never narrower than its buttons: what does not fit wraps.
            .flexShrink(0)
            .padding(.bottom, 8)
            Spacer().frame(width: .pt(0))
            HStack(padding: 0, alignment: .center, spacing: 8) {
                Text("Number as", color: look.soft, font: explorerFonts?.crumbSemi)
                DialogField(
                    text: session.bulkRenameField(\.template, empty: ""),
                    placeholder: "{name} {n:2}",
                    id: "bulk-template"
                ) { session.numberBulkRename() }
                    .frame(width: .pt(150))
                DialogButton("Number", id: "bulk-number") { session.numberBulkRename() }
            }
            .flexShrink(0)
            .padding(.bottom, 8)
        }
        .padding(EdgeInsets(top: 0, leading: 20, bottom: 2, trailing: 16))
    }

    private func footer(_ plan: BulkRename.Plan) -> some View {
        let look = ExplorerLook.current
        let fonts = explorerFonts
        let renamed = plan.moves.count
        let problems = plan.rows.filter { if case .problem = $0.outcome { true } else { false } }.count
        var summary = plan.problem.map { $0 + ". " } ?? ""
        summary += renamed == 0 ? "Nothing changes yet" : "\(ExplorerSession.items(renamed)) to rename"
        if problems > 0 { summary += " · \(problems) to fix" }
        return HStack(padding: 0, alignment: .center, spacing: 8) {
            Text(
                summary,
                color: plan.problem != nil || problems > 0 ? DiagnosticColors.error : look.soft,
                font: fonts?.captionTabular,
                lineLimit: 1
            )
            .flexShrink(1)
            .agentId("bulk-summary")
            Spacer()
            DialogButton("Reset", id: "bulk-reset") { session.resetBulkRename() }
            Text("Ctrl+Enter", color: look.soft, font: fonts?.caption)
            DialogButton("Cancel", id: "bulk-cancel") { session.cancelBulkRename() }
            DialogButton(renamed > 0 ? "Rename \(ExplorerSession.items(renamed))" : "Rename",
                         prominent: plan.canApply, id: "bulk-confirm") {
                if plan.canApply { session.commitBulkRename() }
            }
        }
        .padding(EdgeInsets(top: 10, leading: 20, bottom: 10, trailing: 16))
    }

    /// A red mark on every line that cannot be applied, and a quiet dot on
    /// every line that changes — the gutter alone then says what the list on
    /// the right says in words.
    static func decorations(_ plan: BulkRename.Plan, text: String) -> [EditorDecoration] {
        // Offsets from the buffer's own lines: a row's `newName` is trimmed.
        let lines = BulkRename.lines(of: text)
        var decorations: [EditorDecoration] = []
        var offset = 0
        for (index, row) in plan.rows.enumerated() where index < lines.count {
            let length = lines[index].count
            switch row.outcome {
            case .unchanged: break
            case .renamed:
                decorations.append(EditorDecoration(
                    range: offset..<offset + length, severity: .hint, underline: .none
                ))
            case .problem(let message):
                decorations.append(EditorDecoration(
                    range: offset..<offset + max(length, 1), severity: .error,
                    underline: .wavy, message: message
                ))
            }
            offset += length + 1
        }
        return decorations
    }
}

enum DiagnosticColors {
    /// A brick red that reads on the paper card as well as on a dark one.
    static let error = Color(r: 0.75, g: 0.25, b: 0.18)
}

/// "old → new" for each line that changes, and why for each that cannot.
/// Clicking one puts the caret on its line.
private struct ChangeList: View {
    @Bindable var session: ExplorerSession
    let plan: BulkRename.Plan

    private struct Line: Identifiable {
        var id: Int
        var row: BulkRename.Row
    }

    var body: some View {
        let look = ExplorerLook.current
        let lines = plan.rows.enumerated()
            .filter { $0.element.outcome != .unchanged }
            .map { Line(id: $0.offset, row: $0.element) }
        return VStack(flexGrow: 1, padding: 0, spacing: 0) {
            if lines.isEmpty {
                Text("Edit the names on the left; what changes shows here", color: look.soft,
                     font: explorerFonts?.caption)
                    .padding(14)
                Spacer()
            } else {
                ScrollView(.vertical) {
                    VStack(padding: 6, spacing: 0) {
                        ForEach(lines) { line in
                            row(line)
                        }
                    }
                }
                .flexGrow(1)
            }
        }
        .background(look.well)
        .cornerRadius(14)
        .clipped()
        .agentId("bulk-changes")
    }

    private func row(_ line: Line) -> some View {
        let look = ExplorerLook.current
        let fonts = explorerFonts
        let session = self.session
        let number = line.id + 1
        return VStack(padding: 0, spacing: 2, onClick: {
            session.bulkRenameEditor.reveal(line: number)
        }) {
            HStack(padding: 0, alignment: .center, spacing: 6) {
                Text("\(number)", color: look.faint, font: fonts?.captionTabular)
                    .frame(width: .pt(32))
                Text(line.row.name, color: look.soft, font: fonts?.crumb, lineLimit: 1)
                    .flexShrink(1)
                Text("\u{2192}", color: look.faint, font: fonts?.crumb)
                Text(line.row.newName.isEmpty ? "(empty)" : line.row.newName, color: look.text,
                     font: fonts?.crumbSemi, lineLimit: 1)
                    .flexShrink(1)
            }
            if case .problem(let message) = line.row.outcome {
                Text(message, color: DiagnosticColors.error, font: fonts?.caption, lineLimit: 1)
                    .padding(EdgeInsets(top: 0, leading: 38, bottom: 0, trailing: 0))
            }
        }
        .padding(EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8))
        .hoverBackground(look.card)
        .cornerRadius(10)
        .cursor(.pointer)
        .agentId("bulk-change-\(number)")
    }
}
