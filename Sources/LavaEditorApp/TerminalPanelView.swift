import Foundation
import LavaTerminal
import LavaUI

/// The panel under the editor: a strip naming each terminal, and the one in
/// front.
struct TerminalPanelView: View {
    @Bindable var session: EditorSession
    let appearance: EditorAppearance

    var body: some View {
        let theme = appearance.theme
        let panel = session.terminal
        return VStack(flexGrow: 1, spacing: 0) {
            HStack(padding: 5, alignment: .center, spacing: 4) {
                Text("TERMINAL", color: .secondary, font: session.fonts.status)
                    .padding(.horizontal, 8)
                ForEach(Array(panel.tabs.enumerated()), id: \.offset) { index, terminal in
                    tab(index, terminal, isActive: index == panel.active, theme: theme)
                }
                pill("+", isActive: false, theme: theme) { session.newTerminal() }
                    .agentId("terminal-new")
                Spacer()
                if let current = panel.current {
                    pill("Kill", isActive: false, theme: theme) { session.closeTerminal(current) }
                        .agentId("terminal-kill")
                }
                pill("✕", isActive: false, theme: theme) { session.hideTerminal() }
                    .agentId("terminal-hide")
            }
            .background(theme.panel)
            if let current = panel.current, let font = panel.font ?? FontStore.default {
                TerminalGrid(
                    session: current, mono: font,
                    claimsKeyboard: false, background: theme.inset
                )
                .flexGrow(1)
                .agentId("terminal-grid")
            } else {
                Spacer()
            }
        }
        .background(theme.inset)
    }

    /// A prompt's `user@host:/a/long/path` comes down to its last folder; a
    /// program's own title (vim, htop) is kept, cut to fit a tab.
    static func shortTitle(_ terminal: TerminalSession) -> String {
        var title = terminal.title
        if title == "LavaTerm" || title.isEmpty { return "shell" }
        if let colon = title.firstIndex(of: ":"), title[..<colon].contains("@") {
            let path = title[title.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            title = path == "~" || path.isEmpty ? "~" : URL(fileURLWithPath: path).lastPathComponent
        }
        return title.count > 28 ? String(title.prefix(27)) + "…" : title
    }

    /// One terminal's name in the strip.
    private func tab(_ index: Int, _ terminal: TerminalSession, isActive: Bool, theme: Theme) -> some View {
        pill("\(index + 1): \(Self.shortTitle(terminal))", isActive: isActive, theme: theme) {
            session.selectTerminal(index)
        }
        .agentId("terminal-tab-\(index)")
    }

    /// Everything in the strip has the same shape: padding inside one node
    /// (padding before anything that paints, so the fill and the click are
    /// the same box), rounded, and a hover that the active tab does not get —
    /// selected wins over hovered, as in the sidebar.
    private func pill(
        _ title: String, isActive: Bool, theme: Theme, action: @escaping () -> Void
    ) -> some View {
        Text(
            title, color: isActive ? .primary : .secondary,
            font: isActive ? session.fonts.statusEmphasis : session.fonts.status,
            hoverFill: isActive ? .clear : theme.hover, cornerRadius: 5,
            onClick: action
        )
        .padding(EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8))
        .background(isActive ? theme.inset : .clear)
        .cornerRadius(5)
        .cursor(.pointer)
    }
}
