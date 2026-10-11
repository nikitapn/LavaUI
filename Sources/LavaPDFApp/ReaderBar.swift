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
                button("☰", id: "sidebar", on: session.sidebarOpen) { session.toggleSidebar() }
            }
            Text(session.hasDocument ? session.fileName : "LavaPDF", color: Theme.current.textPrimary)
                .agentId("title")
            Spacer()
                .frame(height: .pt(Self.height), minWidth: 48)
                .windowDrag()
            if session.hasDocument {
                Text("\(session.currentPage + 1) / \(session.pageCount)", color: Theme.current.textDim)
                    .agentId("page")
                button("−", id: "zoom-out") { session.stepZoom(-1) }
                Text("\(session.zoomPercent)%", color: Theme.current.textSecondary)
                    .agentId("zoom")
                button("+", id: "zoom-in") { session.stepZoom(1) }
                button("Width", id: "fit-width", on: session.mode == .fitWidth) {
                    session.setMode(.fitWidth)
                }
                button("Page", id: "fit-page", on: session.mode == .fitPage) {
                    session.setMode(.fitPage)
                }
            }
        }
        .background(Theme.current.panel)
    }

    /// Padding before the hover, so the fill and the click target are one
    /// box — see the `.padding()` trap in AGENTS.md.
    private func button(
        _ label: String, id: String, on: Bool = false, action: @escaping () -> Void
    ) -> some View {
        Text(label, color: on ? .accent : Theme.current.textPrimary, align: .center, onClick: action)
            .padding(6)
            .hoverBackground(Theme.current.hover)
            .cornerRadius(4)
            .cursor(.pointer)
            .agentId(id)
    }
}

/// Under the bar while finding: the field, how many matches, and the steps.
struct FindBar: View {
    @Bindable var session: ReaderSession

    var body: some View {
        HStack(padding: 8, alignment: .center, spacing: 10) {
            TextField(
                text: $session.query, placeholder: "Find in document",
                autoFocus: true, selectionOnFocus: .all,
                onSubmit: { session.findNext() }
            )
            .frame(width: .pt(280))
            .agentId("find-field")
            Text(session.findStatus, color: Theme.current.textDim)
                .agentId("find-status")
            Spacer()
            step("Previous", id: "find-previous") { session.findNext(-1) }
            step("Next", id: "find-next") { session.findNext(1) }
            step("Done", id: "find-done") { session.closeFind() }
        }
        .background(Theme.current.panel)
    }

    private func step(_ label: String, id: String, action: @escaping () -> Void) -> some View {
        Text(label, color: Theme.current.textSecondary, onClick: action)
            .padding(4)
            .hoverBackground(Theme.current.hover)
            .cornerRadius(4)
            .cursor(.pointer)
            .agentId(id)
    }
}

/// Under the bar when a file asks for a password: which file, the field, and
/// whether the last try was wrong. A bar rather than a dialog, like the find
/// bar, so whatever was already open stays readable behind the question.
struct PasswordBar: View {
    @Bindable var session: ReaderSession

    var body: some View {
        HStack(padding: 8, alignment: .center, spacing: 10) {
            Text(prompt, color: session.passwordRejected ? Palette.warning : Theme.current.textSecondary)
                .agentId("password-prompt")
            TextField(
                text: $session.passwordEntry, placeholder: "Password",
                autoFocus: true, secure: true,
                onSubmit: { session.submitPassword() }
            )
            .frame(width: .pt(240))
            .agentId("password-field")
            Text("Open", color: .accent, align: .center, onClick: { session.submitPassword() })
                .padding(4)
                .hoverBackground(Theme.current.hover)
                .cornerRadius(4)
                .cursor(.pointer)
                .agentId("password-open")
            Spacer()
            Text("Cancel", color: Theme.current.textDim, align: .center, onClick: { session.cancelPassword() })
                .padding(4)
                .hoverBackground(Theme.current.hover)
                .cornerRadius(4)
                .cursor(.pointer)
                .agentId("password-cancel")
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
