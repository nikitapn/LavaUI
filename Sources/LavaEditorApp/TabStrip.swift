import LavaUI

/// The editor supplies documents and reorder behavior; LavaUI owns tab chrome.
struct EditorTabs: View {
    @Bindable var session: EditorSession

    var body: some View {
        TabStrip(showsBaseline: false, position: session.tabScroll,
                 newButtonID: "new-document",
                 onViewport: { session.tabViewportFrame = $0 }, onNew: { session.newDocument() }) {
            ForEach(session.documents) { document in
                TabStripItem(document.name, selected: document.id == session.active.id,
                             modified: document.isModified, outlined: false,
                             fill: Theme.current.panel, closeID: "close-tab-\(document.id)",
                             onSelect: {
                                 if let index = session.documents.firstIndex(where: { $0.id == document.id }) {
                                     session.activate(index)
                                 }
                             }, onClose: {
                                 if let index = session.documents.firstIndex(where: { $0.id == document.id }) {
                                     session.requestClose(index)
                                 }
                             })
                    .onFrame { session.tabFrames[document.id] = $0 }
                    .onDragGesture { session.dragTab(document.id, $0) }
                    .agentId("tab-\(document.id)")
            }
        }
        .onFrame { session.tabStripFrame = $0 }
        .overlayLayer {
            Canvas(label: "tab-drop", width: .pct(100), height: .pct(100),
                   continuousRedraw: session.tabDrag != nil) { list, frame in
                session.advanceTabDrag()
                if let drag = session.tabDrag {
                    let x = min(max(drag.caretX, frame.x + 2), frame.x + frame.w - 2)
                    list.rect(x: x - 1, y: frame.y + 6, w: 2, h: frame.h - 10,
                              color: Theme.current.accent)
                }
            }
        }
        .agentId("tabs")
    }
}
