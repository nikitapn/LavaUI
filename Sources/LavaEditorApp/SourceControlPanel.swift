import Foundation
import LavaUI

/// What git says changed, and committing it. Placeholder until the real panel lands.
struct SourceControlPanel: View {
    @Bindable var session: EditorSession
    let project: ProjectSession
    let appearance: EditorAppearance

    var body: some View {
        VStack(flexGrow: 1, padding: 14, spacing: 8) {
            Text("Source Control", color: .primary, font: session.fonts.tabSelected)
            Text("Not built yet.", color: .muted, font: session.fonts.status)
        }
        .agentId("source-control-panel")
    }
}
