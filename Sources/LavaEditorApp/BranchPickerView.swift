import Foundation
import LavaGitCore
import LavaUI

/// The branch picker: a search field over worktrees and branches, near the
/// top of the window as a command palette is. Up/Down choose, Enter goes,
/// Escape or a click outside closes.
struct BranchPickerView: View {
    let session: EditorSession
    let picker: BranchPicker
    let appearance: EditorAppearance

    static let placement = OverlayPlacement { context in
        let width = min(620, max(1, context.viewport.width - 32))
        let height = min(context.idealSize.height, 520, max(1, context.viewport.height - 96))
        return OverlayFrame(x: (context.viewport.width - width) / 2, y: 56, width: width, height: height)
    }

    static func style(session: EditorSession, picker: BranchPicker, theme: Theme) -> OverlayStyle {
        var style = OverlayStyle(background: theme.panel, border: theme.border, cornerRadius: 16,
                                 padding: 0, scrim: Color(r: 0, g: 0, b: 0, a: 0.2), modal: true)
        style.onKey = { event in
            switch event.key {
            case KeyCode.escape: session.closeBranchPicker()
            case KeyCode.enter: if let row = picker.selected { session.choose(row) }
            case KeyCode.up: picker.move(by: -1)
            case KeyCode.down: picker.move(by: 1)
            default: return false
            }
            return true
        }
        style.onUnfocusedText = { character in
            guard !character.isNewline else { return }
            picker.query += String(character)
            picker.searchFocused = true
        }
        return style
    }

    var body: some View {
        let theme = appearance.theme
        let rows = picker.rows
        let selected = picker.selected
        return VStack(spacing: 0) {
            TextField(
                text: Binding(get: { picker.query }, set: { picker.query = $0 }),
                placeholder: "Switch to a branch or worktree",
                font: session.fonts.tab,
                focusRing: FocusRingStyle.none, restingOutline: false
            )
            .focused(Binding(get: { picker.searchFocused }, set: { picker.searchFocused = $0 }))
            .padding(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
            .background(theme.inset)
            .cornerRadius(10)
            .padding(10)
            .agentId("branch-search")

            if let error = picker.error {
                Text(error, color: appearance.theme.accent, font: session.fonts.status)
                    .padding(EdgeInsets(top: 0, leading: 16, bottom: 8, trailing: 16))
                    .agentId("branch-error")
            }
            if picker.loading {
                Text("Reading branches…", color: .muted, font: session.fonts.status).padding(16)
            } else if rows.isEmpty {
                Text(picker.query.isEmpty ? "No branches." : "Nothing matches “\(picker.query)”.",
                     color: .muted, font: session.fonts.status).padding(16)
            } else {
                ScrollView(.vertical) {
                    VStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                            self.row(row, isSelected: row == selected, theme: theme)
                        }
                    }
                    .padding(EdgeInsets(top: 0, leading: 6, bottom: 8, trailing: 6))
                }
                .flexGrow(0)
                .flexShrink(1)
                .agentId("branch-rows")
            }
        }
        .frame(width: .pct(100))
        // Pass the overlay's height constraint down to the scroll viewport.
        .flexShrink(1)
        .agentId("branch-picker")
    }

    @ViewBuilder
    private func row(_ row: BranchPicker.Row, isSelected: Bool, theme: Theme) -> some View {
        switch row {
        case .heading(let title):
            Text(title.uppercased(), color: .muted, font: session.fonts.status)
                .padding(EdgeInsets(top: 10, leading: 10, bottom: 4, trailing: 10))
        case .worktree(let worktree, let current):
            choice(row, isSelected: isSelected, theme: theme,
                   title: worktree.name,
                   detail: Self.abbreviated(worktree.root.path),
                   badge: worktree.branch ?? "detached",
                   trailing: current ? "open" : (worktree.isLocked ? "locked" : nil),
                   id: "branch-worktree-\(worktree.name)")
        case .branch(let branch, let elsewhere):
            choice(row, isSelected: isSelected, theme: theme,
                   title: branch.name, detail: Self.detail(branch), badge: nil,
                   trailing: branch.isHead ? "current" : elsewhere.map { "in \($0.name)" },
                   id: "branch-\(branch.name)")
        }
    }

    /// `↑2 ↓1 · subject`: how far from its upstream, and what its tip is.
    static func detail(_ branch: GitBranch) -> String {
        var parts: [String] = []
        if branch.ahead > 0 { parts.append("↑\(branch.ahead)") }
        if branch.behind > 0 { parts.append("↓\(branch.behind)") }
        if !branch.subject.isEmpty { parts.append(branch.subject) }
        return parts.joined(separator: " · ")
    }

    private func choice(
        _ row: BranchPicker.Row, isSelected: Bool, theme: Theme,
        title: String, detail: String, badge: String?, trailing: String?, id: String
    ) -> some View {
        let session = self.session
        return HStack(alignment: .center, spacing: 8, onClick: { session.choose(row) }) {
            VStack(spacing: 2) {
                HStack(alignment: .center, spacing: 8) {
                    Text(title, color: .primary, font: session.fonts.tab, lineLimit: 1)
                        .flexShrink(1)
                    if let badge {
                        Text(badge, color: appearance.languageText, font: session.fonts.status, lineLimit: 1)
                            .padding(EdgeInsets(top: 1, leading: 7, bottom: 1, trailing: 7))
                            .background(appearance.languageFill)
                            .cornerRadius(8)
                            .flexShrink(1)
                    }
                }
                if !detail.isEmpty {
                    Text(detail, color: .muted, font: session.fonts.status, lineLimit: 1)
                }
            }
            .flexGrow(1)
            .flexShrink(1)
            if let trailing {
                Text(trailing, color: .muted, font: session.fonts.status, lineLimit: 1)
            }
        }
        .padding(EdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10))
        .background(isSelected ? theme.selectionFill : .clear)
        .hoverBackground(isSelected ? theme.selectionFill : theme.hover)
        .cornerRadius(8)
        .cursor(.pointer)
        .scrollIntoView(when: isSelected)
        .agentId(id)
    }

    static func abbreviated(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
