import Foundation
import LavaUI
import LavaViewCore

/// The strip along the top: what is open, and everything that describes it.
///
/// This exists so that the `ControlBar` underneath does not. Every label here
/// is a different width for every picture — the filename most of all, but also
/// `2400 × 1600` against `120 × 90` and `1 / 5` against `137 / 400` — and while
/// they shared a row with the buttons, stepping through a folder slid the
/// buttons sideways under a pointer that had not moved. The Next you were
/// clicking repeatedly walked away from you.
///
/// Splitting them is what fixes that, not the order: the buttons are all
/// fixed-width, so once nothing variable shares their row they can be centred
/// and stay exactly where they were. Here, the same labels reflow freely and
/// it costs nothing, because none of them is a target.
///
/// It is also the title bar. A client-framed window has no other one, so this
/// is where the window buttons and the drag handle live.
struct TitleBar: View {
    @Bindable var session: ViewerSession

    static let height: Float = 40

    var body: some View {
        HStack(height: .pt(Self.height), padding: 8, alignment: .center, spacing: 8) {
            if WindowBridge.drawsOwnChrome {
                WindowControls().windowChrome()
            }
            Text(session.currentName, color: Theme.current.textPrimary)
                .agentId("file-name")
            if let badge = session.rotation.badge {
                // The dot is the unsaved marker, the same one a text editor
                // puts on a modified tab.
                Text(
                    session.hasUnsavedRotation ? "\(badge) •" : badge,
                    color: .accent
                )
                .agentId("rotation-badge")
            }
            // Save is here rather than beside the rotate arrows it belongs to,
            // for the reason this whole bar exists: a button that appears only
            // when there is something to save would, down in the control row,
            // re-centre every other button the instant you pressed a rotate
            // arrow. Up here it pushes labels, and it sits right after the
            // badge that explains why it appeared.
            if session.hasUnsavedRotation { saveButton }
            Spacer()
                .frame(height: .pt(Self.height), minWidth: 48)
            if !session.dimensions.isEmpty {
                Text(session.dimensions, color: Theme.current.textDim)
                    .agentId("dimensions")
            }
            if session.folder.count > 1 {
                Text(
                    "\(session.folder.position) / \(session.folder.count)",
                    color: Theme.current.textDim
                )
                .agentId("position")
            }
        }
        .background(Theme.current.panel)
    }

    private var saveButton: some View {
        Text("Save", color: .accent, onClick: { session.requestSave() })
            .padding(6)
            .hoverBackground(Theme.current.hover)
            .cornerRadius(4)
            .cursor(.pointer)
            .agentId("save")
    }
}
