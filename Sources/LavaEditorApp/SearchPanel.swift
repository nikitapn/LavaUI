import Foundation
import LavaUI

/// Search across the project's files. Placeholder until the real panel lands.
struct SearchPanel: View {
    @Bindable var session: EditorSession
    let project: ProjectSession
    let appearance: EditorAppearance

    var body: some View {
        VStack(flexGrow: 1, padding: 14, spacing: 8) {
            Text("Search", color: .primary, font: session.fonts.tabSelected)
            Text("Not built yet.", color: .muted, font: session.fonts.status)
        }
        .agentId("search-panel")
    }
}
