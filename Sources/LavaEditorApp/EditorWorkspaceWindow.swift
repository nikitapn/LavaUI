import LavaUI

/// The host only takes a title at window creation. Keep the changing title in
/// the app's chrome, where it can follow workspace switches in either host.
struct EditorWorkspaceWindow: View {
    let session: EditorSession
    let appearance: EditorAppearance

    var body: some View {
        VStack(flexGrow: 1, spacing: 0) {
            if let name = session.workspaceName {
                Text("\(name) — LavaEditor", color: .primary, font: session.fonts.tab, align: .center)
                    .frame(height: .pt(30))
                    .windowDrag()
                    .agentId("workspace-title")
            }
            LavaEditorView(session: session, appearance: appearance)
        }
        .background(appearance.theme.panel)
        .overlay(
            isPresented: Binding(get: { session.pendingWorkspace != nil }, set: { _ in }),
            placement: OverlayPlacement { context in
                let size = context.idealSize
                return OverlayFrame(x: max(0, (context.viewport.width - size.width) / 2),
                                    y: max(0, (context.viewport.height - size.height) / 2),
                                    width: size.width, height: size.height)
            },
            style: OverlayStyle(background: appearance.theme.panel, border: appearance.theme.border,
                                padding: 16, scrim: Color(r: 0, g: 0, b: 0, a: 0.35), modal: true)
        ) {
            if let opening = session.pendingWorkspace {
                VStack(width: .pt(390), spacing: 12) {
                    Text("Open \(opening.url.deletingPathExtension().lastPathComponent)?", color: .primary)
                    Text("The current session has unsaved changes.", color: .muted)
                    HStack(alignment: .center, spacing: 8) {
                        Button("Cancel") { session.pendingWorkspace = nil }.agentId("workspace-cancel")
                        Button("Discard") { session.resolveWorkspaceOpening(save: false) }
                            .agentId("workspace-discard")
                        Button("Save All and Open") { session.resolveWorkspaceOpening(save: true) }
                            .agentId("workspace-save")
                    }
                }
            }
        }
    }
}
