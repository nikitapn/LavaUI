import LavaUI

struct EditorTabs: View {
    @Bindable var session: EditorSession
    let appearance: EditorAppearance
    /// False when something to the left — the project sidebar — carries the
    /// window's buttons, as it does when it runs the full height of the window.
    var showsWindowControls = true
    @State private var contextMenu: TabContextMenu.Anchor? = nil

    static let stripHeight: Float = 54
    private static let tabHeight: Float = 42

    var body: some View {
        let theme = appearance.theme
        let menuStyle = TabContextMenu.style(theme: theme)
        let anchor = contextMenu
        return HStack(height: .pt(Self.stripHeight), padding: 0, alignment: .end, spacing: 4) {
            if showsWindowControls, WindowBridge.drawsOwnChrome {
                WindowControls(style: appearance.windowControls)
                    .padding(EdgeInsets(top: 0, leading: 20, bottom: 15, trailing: 14))
                    .flexShrink(0)
            } else {
                // Clear of the split's grab strip, so the first tab is not
                // flush against the sidebar's edge.
                Spacer().frame(width: .pt(6), height: .pt(Self.stripHeight)).flexGrow(0)
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
        .overlay(
            isPresented: Binding(get: { contextMenu != nil }, set: { if !$0 { contextMenu = nil } }),
            placement: OverlayPlacement { context in
                let width = context.idealSize.width
                let height = context.idealSize.height
                let x = min(max(0, anchor?.x ?? 0), max(0, context.viewport.width - width))
                let y = min(max(0, anchor?.y ?? 0), max(0, context.viewport.height - height))
                return OverlayFrame(x: x, y: y, width: width, height: height)
            },
            style: menuStyle.overlayStyle
        ) {
            if let anchor, let document = session.documents.first(where: { $0.id == anchor.id }) {
                TabContextMenu(session: session, document: document, style: menuStyle) {
                    contextMenu = nil
                }
            }
        }
    }

    private func tab(_ document: EditorDocument) -> some View {
        let selected = document.id == session.active.id
        let theme = appearance.theme
        let pinned = document.tabState == .pinned
        let uprightFont = selected ? session.fonts.tabSelected : session.fonts.tab
        let font = document.tabState == .preview ? session.fonts.tabPreview ?? uprightFont : uprightFont
        return TabStripItem(
            document.name, selected: selected, modified: document.isModified,
            outlined: false, fill: theme.inset,
            style: .init(height: Self.tabHeight, radius: 16,
                         font: font,
                         text: selected ? theme.textPrimary : theme.textSecondary,
                         modified: appearance.modified, closeHover: theme.selectionFill),
            closeID: pinned ? "unpin-tab-\(document.id)" : "close-tab-\(document.id)",
            leading: { [session] list, frame in
                FileIcons.draw(document.name, in: list, x: frame.x, y: frame.y, size: frame.w,
                               theme: theme, editor: session.imageEditor)
            },
            onUnpin: pinned ? {
                if let index = session.documents.firstIndex(where: { $0.id == document.id }) {
                    session.toggleTabPin(index)
                }
            } : nil,
            onSelect: {
                if let index = session.documents.firstIndex(where: { $0.id == document.id }) {
                    let point = PointerState.window
                    let clicks = ClickCounter.register(x: point.x, y: point.y)
                    if index == session.activeIndex || clicks > 1 { session.keepTabOpen(index) }
                    session.activate(index)
                }
            }, onClose: {
                if let index = session.documents.firstIndex(where: { $0.id == document.id }) {
                    session.requestClose(index)
                }
            }
        )
        .onFrame { session.tabFrames[document.id] = $0 }
        .onDragGesture { if !pinned { session.dragTab(document.id, $0) } }
        .onAnyPress { button in
            guard button == PointerButton.right else { return }
            let point = PointerState.window
            contextMenu = TabContextMenu.Anchor(id: document.id, x: point.x, y: point.y)
        }
        .agentId("tab-\(document.id)")
    }
}
