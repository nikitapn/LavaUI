import LavaUI

/// The window's root: the editor, and the question asked before a workspace
/// replaces a session with unsaved changes.
///
/// Which workspace is open is said in the project sidebar's header, not in a
/// bar of its own: a strip across the top would sit over the sidebar that is
/// meant to run the window's full height.
struct EditorWorkspaceWindow: View {
    let session: EditorSession
    let appearance: EditorAppearance

    var body: some View {
        VStack(flexGrow: 1, spacing: 0) {
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
