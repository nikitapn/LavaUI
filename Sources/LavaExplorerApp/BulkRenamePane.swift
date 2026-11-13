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

    var body: some View {
        let theme = Theme.current
        let plan = draft.plan
        return VStack(flexGrow: 1, padding: 0, spacing: 0) {
            HStack(padding: 10, alignment: .center, spacing: 8) {
                Text(
                    "Rename \(ExplorerSession.items(draft.names.count)): line n is item n's new name",
                    color: theme.textSecondary, lineLimit: 1
                )
                .flexShrink(1)
                Spacer()
                Toggle(
                    "Keep extensions",
                    isOn: session.bulkRenameField(\.keepExtensions, empty: true)
                )
                .agentId("bulk-keep-extensions")
            }
            replaceRow
            caseAndNumberRow
            if let error = draft.transformError {
                Text(error, color: DiagnosticColors.error, lineLimit: 1)
                    .padding(EdgeInsets(top: 0, leading: 10, bottom: 6, trailing: 10))
                    .agentId("bulk-transform-error")
            }
            HSplitView(
                fraction: $session.bulkRenameFraction, minLeading: 200, minTrailing: 200
            ) {
                EditorView(
                    text: session.bulkRenameText,
                    showLineNumbers: true,
                    decorations: Self.decorations(plan, text: draft.text),
                    controller: session.bulkRenameEditor
                )
                .flexGrow(1)
                .agentId("bulk-editor")
            } trailing: {
                ChangeList(session: session, plan: plan)
            }
            .flexGrow(1)
            footer(plan)
        }
        .flexGrow(1)
    }

    private var replaceRow: some View {
        HStack(padding: 0, alignment: .center, spacing: 8) {
            Text("Replace", color: Theme.current.textSecondary)
            TextField(
                text: session.bulkRenameField(\.find, empty: ""),
                placeholder: draft.regex ? "Pattern, e.g. IMG_(\\d+)" : "Find",
                onSubmit: { session.replaceInBulkRename() }
            )
            .flexGrow(1)
            .agentId("bulk-find")
            Text("with", color: Theme.current.textSecondary)
            TextField(
                text: session.bulkRenameField(\.replacement, empty: ""),
                placeholder: draft.regex ? "e.g. rome-$1" : "",
                onSubmit: { session.replaceInBulkRename() }
            )
            .flexGrow(1)
            .agentId("bulk-replacement")
            Toggle("Regex", isOn: session.bulkRenameField(\.regex, empty: false))
                .agentId("bulk-regex")
            Button("Replace All") { session.replaceInBulkRename() }
                .agentId("bulk-replace")
        }
        .padding(EdgeInsets(top: 0, leading: 10, bottom: 6, trailing: 10))
    }

    private var caseAndNumberRow: some View {
        HStack(padding: 0, alignment: .center, spacing: 8) {
            Button("lowercase") { session.applyBulkTransform(.lowercase) }
                .agentId("bulk-lowercase")
            Button("UPPERCASE") { session.applyBulkTransform(.uppercase) }
                .agentId("bulk-uppercase")
            Button("Title Case") { session.applyBulkTransform(.titlecase) }
                .agentId("bulk-titlecase")
            Spacer().frame(width: .pt(8))
            Text("Number as", color: Theme.current.textSecondary)
            TextField(
                text: session.bulkRenameField(\.template, empty: ""),
                placeholder: "{name} {n:2}",
                onSubmit: { session.numberBulkRename() }
            )
            .frame(width: .pt(150))
            .agentId("bulk-template")
            Button("Number") { session.numberBulkRename() }
                .agentId("bulk-number")
        }
        .padding(EdgeInsets(top: 0, leading: 10, bottom: 8, trailing: 10))
    }

    private func footer(_ plan: BulkRename.Plan) -> some View {
        let renamed = plan.moves.count
        let problems = plan.rows.filter { if case .problem = $0.outcome { true } else { false } }.count
        var summary = plan.problem.map { $0 + ". " } ?? ""
        summary += renamed == 0 ? "Nothing changes yet" : "\(ExplorerSession.items(renamed)) to rename"
        if problems > 0 { summary += " · \(problems) to fix" }
        return HStack(padding: 10, alignment: .center, spacing: 8) {
            Text(
                summary,
                color: plan.problem != nil || problems > 0 ? DiagnosticColors.error : Theme.current.textSecondary,
                lineLimit: 1
            )
            .flexShrink(1)
            .agentId("bulk-summary")
            Spacer()
            Button("Reset") { session.resetBulkRename() }
                .agentId("bulk-reset")
            Text("Ctrl+Enter", color: Theme.current.textDim)
            Button("Cancel") { session.cancelBulkRename() }
                .agentId("bulk-cancel")
            Button(renamed > 0 ? "Rename \(ExplorerSession.items(renamed))" : "Rename", isEnabled: plan.canApply) {
                session.commitBulkRename()
            }
            .agentId("bulk-confirm")
        }
        .background(Theme.current.panel)
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
    static let error = Color(r: 0.92, g: 0.35, b: 0.35)
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
        let theme = Theme.current
        let lines = plan.rows.enumerated()
            .filter { $0.element.outcome != .unchanged }
            .map { Line(id: $0.offset, row: $0.element) }
        return VStack(flexGrow: 1, padding: 0, spacing: 0) {
            if lines.isEmpty {
                Text("Edit the names on the left; what changes shows here", color: theme.textDim)
                    .padding(12)
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
        .background(theme.inset)
        .agentId("bulk-changes")
    }

    private func row(_ line: Line) -> some View {
        let theme = Theme.current
        let session = self.session
        let number = line.id + 1
        return VStack(padding: 0, spacing: 2, onClick: {
            session.bulkRenameEditor.reveal(line: number)
        }) {
            HStack(padding: 0, alignment: .center, spacing: 6) {
                Text("\(number)", color: theme.textDim)
                    .frame(width: .pt(32))
                Text(line.row.name, color: theme.textSecondary, lineLimit: 1)
                    .flexShrink(1)
                Text("\u{2192}", color: theme.textDim)
                Text(line.row.newName.isEmpty ? "(empty)" : line.row.newName, color: theme.textPrimary, lineLimit: 1)
                    .flexShrink(1)
            }
            if case .problem(let message) = line.row.outcome {
                Text(message, color: DiagnosticColors.error, lineLimit: 1)
                    .padding(EdgeInsets(top: 0, leading: 38, bottom: 0, trailing: 0))
            }
        }
        .padding(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
        .hoverBackground(theme.hover)
        .cornerRadius(4)
        .cursor(.pointer)
        .agentId("bulk-change-\(number)")
    }
}
