import LavaUI

struct EditorTabs: View {
    @Bindable var session: EditorSession
    let appearance: EditorAppearance

    private static let stripHeight: Float = 54
    private static let tabHeight: Float = 42

    var body: some View {
        let theme = appearance.theme
        return HStack(height: .pt(Self.stripHeight), padding: 0, alignment: .end, spacing: 4) {
            if WindowBridge.drawsOwnChrome {
                WindowControls(style: appearance.windowControls)
                    .padding(EdgeInsets(top: 0, leading: 20, bottom: 15, trailing: 14))
                    .flexShrink(0)
            }

            ScrollView(.horizontal, showsIndicator: false, position: session.tabScroll) {
                HStack(height: .pt(Self.tabHeight), padding: 0, alignment: .end, spacing: 4) {
                    ForEach(session.documents) { document in
                        tab(document)
                    }
                }
            }
            .flexGrow(0)
            .flexShrink(1)
            .onFrame { session.tabViewportFrame = $0 }

            HStack(height: .pt(Self.tabHeight), padding: 0, alignment: .center, spacing: 0) {
                HStack(padding: 9, alignment: .center, onClick: { session.newDocument() }) {
                    Mark(.plus, size: 11, color: theme.textSecondary, lineWidth: 1.8)
                }
                .hoverBackground(theme.hover)
                .cornerRadius(15)
                .cursor(.pointer)
                .tooltip("New Tab")
                .agentId("new-document")
            }
            .flexShrink(0)

            Spacer()
                .frame(height: .pt(Self.stripHeight), minWidth: 32)
                .windowDrag()
        }
        .background(theme.panel)
        .onFrame { session.tabStripFrame = $0 }
        .overlayLayer {
            Canvas(label: "tab-drop", width: .pct(100), height: .pct(100),
                   continuousRedraw: session.tabDrag != nil) { list, frame in
                session.advanceTabDrag()
                if let drag = session.tabDrag {
                    let x = min(max(drag.caretX, frame.x + 2), frame.x + frame.w - 2)
                    list.roundedRect(x: x - 1, y: frame.y + 15, w: 2, h: frame.h - 20,
                                     color: theme.accent, radius: 1)
                }
            }
        }
        .agentId("tabs")
    }

    private func tab(_ document: EditorDocument) -> some View {
        let selected = document.id == session.active.id
        let theme = appearance.theme
        return TabStripItem(
            document.name, selected: selected, modified: document.isModified,
            outlined: false, fill: theme.inset,
            style: .init(height: Self.tabHeight, radius: 16,
                         font: selected ? session.fonts.tabSelected : session.fonts.tab,
                         text: selected ? theme.textPrimary : theme.textSecondary,
                         modified: appearance.modified, closeHover: theme.selectionFill),
            closeID: "close-tab-\(document.id)",
            onSelect: {
                if let index = session.documents.firstIndex(where: { $0.id == document.id }) {
                    session.activate(index)
                }
            }, onClose: {
                if let index = session.documents.firstIndex(where: { $0.id == document.id }) {
                    session.requestClose(index)
                }
            }
        )
        .onFrame { session.tabFrames[document.id] = $0 }
        .onDragGesture { session.dragTab(document.id, $0) }
        .agentId("tab-\(document.id)")
    }
}
