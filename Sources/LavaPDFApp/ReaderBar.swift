import Foundation
import LavaUI

/// The strip along the top: window buttons, the title, where you are, and the
/// zoom. A client-framed window has no other title bar, so this is also the
/// drag handle.
struct ReaderBar: View {
    @Bindable var session: ReaderSession

    static let height: Float = 40

    var body: some View {
        HStack(height: .pt(Self.height), padding: 8, alignment: .center, spacing: 8) {
            if WindowBridge.drawsOwnChrome {
                WindowControls().windowChrome()
            }
            if !session.outline.isEmpty {
                button(.lines, tip: "Outline", id: "sidebar", on: session.sidebarOpen) {
                    session.toggleSidebar()
                }
            }
            // The one thing on the bar whose length nobody chose for it, so the
            // one thing that gives way: truncated, before any control moves.
            Text(session.hasDocument ? session.fileName : "LavaPDF", color: Theme.current.textPrimary,
                 lineLimit: 1)
                .flexShrink(1)
                .windowDrag()
                .agentId("title")
            // Room to grab the window by even when the title has taken the
            // rest — enough for a pointer, not so much the title shows nothing.
            Spacer()
                .frame(height: .pt(Self.height), minWidth: 24)
                .windowDrag()
            if session.hasDocument {
                Text("\(session.currentPage + 1) / \(session.pageCount)", color: Theme.current.textDim)
                    .agentId("page")
                button(.minus, tip: "Zoom Out", id: "zoom-out") { session.stepZoom(-1) }
                Text("\(session.zoomPercent)%", color: Theme.current.textSecondary)
                    .agentId("zoom")
                button(.plus, tip: "Zoom In", id: "zoom-in") { session.stepZoom(1) }
                button(.fitWidth, tip: "Fit Width", id: "fit-width", on: session.mode == .fitWidth) {
                    session.setMode(.fitWidth)
                }
                button(.fitPage, tip: "Fit Page", id: "fit-page", on: session.mode == .fitPage) {
                    session.setMode(.fitPage)
                }
            }
        }
        .background(Theme.current.panel)
    }

    /// A square around a `Mark`; the click and the hover are the stack's, so
    /// the target and the fill are one box. A mode that is on sits on the
    /// selection fill, as the Explorer's toolbar does.
    private func button(
        _ mark: Mark.Kind, tip: String, id: String, on: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        let theme = Theme.current
        return HStack(
            width: .pt(28), height: .pt(28), padding: 0,
            alignment: .center, spacing: 0, onClick: action
        ) {
            Spacer()
            Mark(mark, size: 14, color: theme.textPrimary)
            Spacer()
        }
        .background(on ? theme.selectionFill : Color.clear)
        .hoverBackground(on ? theme.selectionFill : theme.hover)
        .cornerRadius(4)
        .cursor(.pointer)
        .flexShrink(0)
        .tooltip(tip)
        .agentId(id)
    }
}

/// Floats over the document's top-right corner while finding: the field, how
/// many matches, and the steps, laid out after VS Code's find widget.
struct FindBar: View {
    @Bindable var session: ReaderSession

    /// Wide enough for "No results" and "Searching…", and for "128 of 4096";
    /// fixed, so the panel does not change width under the pointer as the
    /// count changes, and its left edge does not jump while typing.
    static let statusWidth: Float = 104

    var body: some View {
        let found = !session.matches.isEmpty
        return HStack(padding: 4, alignment: .center, spacing: 2) {
            TextField(
                text: $session.query, placeholder: "Find in document",
                autoFocus: true, selectionOnFocus: .all,
                onSubmit: { session.findNext() }
            )
            // Shrinks rather than pushing the steps off a narrow window.
            .frame(width: .pt(200))
            .flexShrink(1)
            .agentId("find-field")
            Text(session.findStatus, color: statusColor, lineLimit: 1)
                .padding(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 4))
                .frame(width: .pt(Self.statusWidth))
                .flexShrink(0)
                .agentId("find-status")
            FindIcon(mark: .arrowUp, enabled: found, tip: "Previous Match", id: "find-previous") {
                session.findNext(-1)
            }
            FindIcon(mark: .arrowDown, enabled: found, tip: "Next Match", id: "find-next") {
                session.findNext(1)
            }
            FindIcon(mark: .cross, enabled: true, tip: "Close", id: "find-done") {
                session.closeFind()
            }
        }
        .agentId("find-bar")
    }

    /// Red for a search that came back empty, dim for the placeholder before
    /// one, and the ordinary secondary colour for a count. The theme has no
    /// error colour; this red reads on both the light and the dark panel.
    private var statusColor: Color {
        if session.findMissed { return Self.missColor }
        return session.findSearched ? Theme.current.textSecondary : Theme.current.textDim
    }

    static let missColor = Color(r: 0.94, g: 0.36, b: 0.36)
}

/// A square button around a `Mark`. The click and the hover are the stack's,
/// so the target and the fill are the same 26-point box (see `Mark`).
private struct FindIcon: View {
    let mark: Mark.Kind
    let enabled: Bool
    let tip: String
    let id: String
    let action: () -> Void

    var body: some View {
        let theme = Theme.current
        let color = enabled ? theme.textSecondary : theme.textDim.opacity(0.5)
        return HStack(
            width: .pt(26), height: .pt(26), padding: 0,
            alignment: .center, spacing: 0,
            onClick: enabled ? action : nil
        ) {
            Spacer()
            Mark(mark, size: mark == .cross ? 10 : 12, color: color)
            Spacer()
        }
        .hoverBackground(enabled ? theme.hover : .clear)
        .cornerRadius(4)
        .cursor(enabled ? .pointer : .arrow)
        .flexShrink(0)
        // Even while disabled: a greyed arrow is the one whose meaning a user
        // most needs to read.
        .tooltip(tip)
        .agentId(id)
    }
}

/// Under the bar when a file asks for a password: which file, the field, and
/// whether the last try was wrong. A bar rather than a dialog, so whatever
/// was already open stays readable behind the question.
struct PasswordBar: View {
    @Bindable var session: ReaderSession

    /// Two rows: the file's name is as long as whoever named it wanted, and
    /// sharing a row with the field it pushed the field off a narrow window.
    /// On its own line it truncates instead, and the field always fits.
    var body: some View {
        VStack(padding: 8, spacing: 6) {
            Text(prompt, color: session.passwordRejected ? Palette.warning : Theme.current.textSecondary,
                 lineLimit: 1)
                .flexShrink(1)
                .agentId("password-prompt")
            HStack(alignment: .center, spacing: 10) {
                TextField(
                    text: $session.passwordEntry, placeholder: "Password",
                    autoFocus: true, secure: true,
                    onSubmit: { session.submitPassword() }
                )
                .frame(width: .pt(240))
                .flexShrink(1)
                .agentId("password-field")
                Text("Open", color: .accent, align: .center, onClick: { session.submitPassword() })
                    .padding(EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8))
                    .hoverBackground(Theme.current.hover)
                    .cornerRadius(4)
                    .cursor(.pointer)
                    .agentId("password-open")
                Spacer()
                Text("Cancel", color: Theme.current.textDim, align: .center, onClick: { session.cancelPassword() })
                    .padding(EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8))
                    .hoverBackground(Theme.current.hover)
                    .cornerRadius(4)
                    .cursor(.pointer)
                    .agentId("password-cancel")
            }
        }
        .background(Theme.current.panel)
    }

    private var prompt: String {
        let name = ((session.locked ?? "") as NSString).lastPathComponent
        return session.passwordRejected
            ? "Wrong password for \(name)"
            : "\(name) is password-protected"
    }
}
