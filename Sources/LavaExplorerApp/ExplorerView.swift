import Foundation
import LavaExplorerCore
import LavaShell
import LavaUI

/// Measurements a pane's chrome and the drop logic have to agree on.
enum PaneChrome {
    /// The tab strip, and the sidebar's title row beside it.
    static let stripHeight: Float = 36
    /// Shorter than the strip: the gap above is what makes the active tab
    /// read as a tab rather than a stripe.
    static let tabHeight: Float = 30
}

/// Places on the left; on the right, one or more panes, each a browser of its
/// own — tabs, an address bar and a details list. Drag a tab to the edge of a
/// pane to split it, or into another pane to move it there.
struct ExplorerView: View {
    @Bindable var session: ExplorerSession

    var body: some View {
        VStack(flexGrow: 1, padding: 0, spacing: 0) {
            HSplitView(
                fraction: $session.sidebarFraction,
                minLeading: 140,
                minTrailing: 360
            ) {
                Sidebar(session: session)
            } trailing: {
                PaneTree.build(session, session.layout.root)
            }
            if let pending = session.pendingCopy {
                ClashBar(session: session, pending: pending)
            }
            StatusBar(session: session)
        }
        .background(Theme.current.background)
        .onDrop { urls in session.acceptDrop(urls) }
        .overlayLayer { TabGhost(session: session) }
    }
}

// MARK: - Panes

/// The split tree as views. Erased at the recursion: a split of splits is a
/// type that contains itself.
private enum PaneTree {
    static func build(_ session: ExplorerSession, _ node: PaneNode) -> AnyView {
        switch node {
        case .pane(let pane):
            return AnyView(PaneView(session: session, paneID: pane.id))
        case .split(let split):
            let fraction = session.splitFraction(split.id)
            switch split.axis {
            case .horizontal:
                return AnyView(
                    HSplitView(fraction: fraction, minLeading: 240, minTrailing: 240) {
                        build(session, split.first)
                    } trailing: {
                        build(session, split.second)
                    }
                )
            case .vertical:
                return AnyView(
                    VSplitView(fraction: fraction, minTop: 160, minBottom: 160) {
                        build(session, split.first)
                    } bottom: {
                        build(session, split.second)
                    }
                )
            }
        }
    }
}

private struct PaneView: View {
    @Bindable var session: ExplorerSession
    let paneID: Int

    var body: some View {
        let pane = session.layout.pane(id: paneID)
        let active = session.layout.activePaneID == paneID
        return VStack(flexGrow: 1, padding: 0, spacing: 0) {
            if let pane {
                TabStrip(session: session, pane: pane, active: active)
                Toolbar(session: session, paneID: paneID, tab: pane.tabs.current)
                FilePane(session: session, paneID: paneID, tab: pane.tabs.current)
            }
        }
        // Before anything in the pane handles the press, so the row, button
        // or field it lands on already acts on this pane.
        .onAnyPress { _ in session.activatePane(paneID) }
        .onFrame { frame in session.notePaneFrame(paneID, frame) }
        .overlayLayer { PaneDropPreview(session: session, paneID: paneID) }
    }
}

/// Where a dragged tab would go if it were let go of now, over the pane it
/// would go to: half the pane for a split, all of it for a move.
private struct PaneDropPreview: View {
    @Bindable var session: ExplorerSession
    let paneID: Int

    var body: some View {
        let target = session.tabDrag?.target
        let shown = target?.paneID == paneID
        let side = shown ? target?.side : nil
        return Canvas(label: "drop-preview", width: .pct(100), height: .pct(100)) { list, frame in
            guard shown else { return }
            let theme = Theme.current
            if let caretX = target?.caretX {
                // Among the tabs: a bar in the gap it would take. Not a wash
                // over the pane — nothing about the pane changes.
                list.roundedRect(
                    x: caretX - 1, y: frame.y + 4, w: 2, h: PaneChrome.stripHeight - 8,
                    color: theme.accent, radius: 1
                )
                return
            }
            let area = PaneDropZone.preview(
                for: side, in: PaneRect(x: frame.x, y: frame.y, w: frame.w, h: frame.h)
            )
            let inset: Float = 4
            let x = area.x + inset
            let y = area.y + inset
            let w = max(0, area.w - inset * 2)
            let h = max(0, area.h - inset * 2)
            list.roundedRect(x: x, y: y, w: w, h: h, color: theme.accent.opacity(0.16), radius: 8)
            list.strokedRect(
                x: x, y: y, w: w, h: h, color: theme.accent.opacity(0.7), radius: 8, width: 2
            )
        }
    }
}

/// The tab being dragged, under the pointer. Drawn over the whole window so
/// it can cross from one pane to another.
private struct TabGhost: View {
    @Bindable var session: ExplorerSession

    var body: some View {
        let drag = session.tabDrag
        return Canvas(label: "tab-ghost", width: .pct(100), height: .pct(100)) { list, frame in
            guard let drag else { return }
            let theme = Theme.current
            let font = FontStore.default
            let pointer = PointerState.window
            let w: Float = 160
            let h = PaneChrome.tabHeight
            // Beside the pointer, but inside the window: splitting to the
            // right edge is exactly where a ghost hung off the right of the
            // pointer would be cut in half.
            let x = min(max(frame.x, pointer.x + 12), frame.x + frame.w - w - 4)
            let y = min(max(frame.y, pointer.y + 8), frame.y + frame.h - h - 4)
            let lineHeight = font?.lineHeight ?? 16
            list.roundedRect(x: x, y: y, w: w, h: h, color: theme.panel.opacity(0.92), radius: 6)
            list.strokedRect(
                x: x, y: y, w: w, h: h,
                color: drag.target == nil ? theme.border : theme.accent,
                radius: 6, width: 1
            )
            list.pushClip(x: x + 10, y: y, w: w - 20, h: h)
            list.text(
                drag.title, x: x + 10, y: y + (h - lineHeight) * 0.5,
                w: w - 20, h: lineHeight, color: theme.textPrimary, font: font
            )
            list.popClip()
        }
    }
}

// MARK: - Clashes

/// One question for a drop whose names are partly taken, across the window
/// under the panes — where the folder it is about is still in view, the same
/// reason LavaEditor asks about unsaved changes in a bar and not a dialog.
private struct ClashBar: View {
    @Bindable var session: ExplorerSession
    let pending: ExplorerSession.PendingCopy

    var body: some View {
        let clashes = pending.plan.clashes
        let total = pending.plan.items.count
        let message = clashes.count == 1 && total == 1
            ? "\u{201C}\(clashes[0].name)\u{201D} is already in \(pending.folderTitle)."
            : "\(clashes.count) of \(ExplorerSession.items(total)) are already in "
                + "\(pending.folderTitle)."
        return HStack(padding: 8, alignment: .center, spacing: 8) {
            Text(message, color: Theme.current.textPrimary, lineLimit: 1)
                .flexShrink(1)
                .agentId("clash-message")
            Spacer()
            Button("Replace") { session.resolveCopy(.replace) }
                .agentId("clash-replace")
            Button("Keep Both") { session.resolveCopy(.keepBoth) }
                .agentId("clash-keep-both")
            Button("Skip") { session.resolveCopy(.skip) }
                .agentId("clash-skip")
            Button("Cancel") { session.resolveCopy(nil) }
                .agentId("clash-cancel")
        }
        .background(Theme.current.selectionFill)
    }
}

// MARK: - Tabs

/// One pane's folder names, the way Explorer and every browser do it. Drag a
/// tab to move it; leftover space after the plus is the window drag handle.
private struct TabStrip: View {
    @Bindable var session: ExplorerSession
    let pane: ExplorerPane
    /// Whether this is the pane commands act on. Its tab titles read brighter.
    let active: Bool

    var body: some View {
        // Bottom-aligned, so every tab stands on the strip's lower edge — the
        // rule the active one opens into the toolbar through.
        HStack(
            height: .pt(PaneChrome.stripHeight), padding: 0, alignment: .end, spacing: 4
        ) {
            // As wide as its tabs and no wider, so the plus sits right after
            // the last one; it shrinks — and scrolls — only once they do not
            // fit. A scroll view fills its parent by default, which would park
            // the plus at the far edge of an almost empty strip.
            ScrollView(.horizontal, showsIndicator: false) {
                HStack(
                    height: .pt(PaneChrome.stripHeight), padding: 0,
                    alignment: .end, spacing: 4
                ) {
                    // Not a bare `Spacer`: a spacer grows, and one on each
                    // side of the tabs is how they ended up centred.
                    Spacer(flexGrow: 0).frame(width: .pt(4), height: .pt(PaneChrome.stripHeight))
                    ForEach(pane.tabs.tabs) { tab in
                        tabChip(tab)
                    }
                }
            }
            .flexGrow(0)
            .flexShrink(1)
            Text(
                "+",
                color: Theme.current.textSecondary,
                align: .center,
                onClick: { session.newTab() }
            )
            .padding(6)
            .frame(width: .pt(28), height: .pt(28))
            .hoverBackground(Theme.current.hover)
            .cornerRadius(6)
            .cursor(.pointer)
            .flexShrink(0)
            .agentId("new-tab")
            Spacer()
                .frame(height: .pt(PaneChrome.stripHeight), minWidth: 48)
                .windowDrag()
        }
        .underlay { StripBackdrop() }
    }

    private func tabChip(_ tab: ExplorerTab) -> some View {
        let on = tab.id == pane.tabs.currentID
        let theme = Theme.current
        let titleColor = on && active ? theme.textPrimary : theme.textSecondary
        return HStack(
            padding: 0,
            alignment: .center,
            spacing: 4,
            onPointer: { _, button in
                if button == PointerButton.middle {
                    session.closeTab(id: tab.id)
                    return
                }
                guard button == PointerButton.left else { return }
                session.selectTab(id: tab.id)
            }
        ) {
            Text(tab.title, color: titleColor, lineLimit: 1)
            Text(
                "×",
                color: theme.textDim,
                onClick: { session.closeTab(id: tab.id) }
            )
            .padding(4)
            .hoverBackground(theme.hover)
            .cornerRadius(4)
            .cursor(.pointer)
            .agentId("close-tab-\(tab.id)")
        }
        .padding(8)
        .frame(height: .pt(PaneChrome.tabHeight))
        .underlay { TabShape(active: on) }
        .hoverBackground(on ? Color.clear : theme.hover)
        .cornerRadius(6)
        .cursor(.pointer)
        // Tabs keep their width and the strip scrolls, rather than a crowd of
        // tabs being squeezed down to a row of "…".
        .flexShrink(0)
        .scrollIntoView(when: on)
        .onFrame { frame in session.noteTabFrame(tab.id, frame) }
        .onDragGesture { value in session.dragTab(tab.id, value) }
        .onDrop { urls in session.dropOnTab(id: tab.id, urls) }
        .agentId("tab-\(tab.id)")
    }
}

/// Behind the tabs: the strip's own fill, and the rule along its bottom edge
/// that the active tab breaks.
private struct StripBackdrop: View {
    var body: some View {
        Canvas(label: "tab-strip", width: .pct(100), height: .pct(100)) { list, frame in
            let theme = Theme.current
            list.rect(x: frame.x, y: frame.y, w: frame.w, h: frame.h, color: theme.background)
            list.rect(
                x: frame.x, y: frame.y + frame.h - 1, w: frame.w, h: 1,
                color: theme.border
            )
        }
    }
}

/// The active tab's plate and outline; nothing for the others.
///
/// One outline around the tab and the toolbar together, the way Chrome and
/// Firefox draw it. The plate is the toolbar's colour and runs down over the
/// strip's rule, so the rule stops at the tab's sides and the outline carries
/// on up, over and back down. `.border` cannot say this: it strokes four
/// sides, and the point is the open fourth.
private struct TabShape: View {
    let active: Bool

    var body: some View {
        Canvas(label: "tab-shape", width: .pct(100), height: .pct(100)) { list, frame in
            guard active else { return }
            let theme = Theme.current
            TabOutline.paint(list, frame: frame, fill: theme.panel, line: theme.border)
        }
    }
}

private enum TabOutline {
    static let radius: Float = 7

    static func paint(_ list: DrawList, frame: CanvasFrame, fill: Color, line: Color) {
        let r = min(radius, frame.w * 0.5, frame.h)
        // Rounded on top only: the plate runs a radius past the bottom and the
        // clip cuts its lower corners off square, flush with the toolbar.
        list.pushClip(x: frame.x, y: frame.y, w: frame.w, h: frame.h)
        list.roundedRect(
            x: frame.x, y: frame.y, w: frame.w, h: frame.h + r, color: fill, radius: r
        )
        list.popClip()
        list.polyline(points(frame: frame, radius: r), color: line)
    }

    /// Up the left side, round the top, down the right side, ending on the
    /// strip's bottom edge where its rule takes over. Half-pixel centres, so a
    /// one-pixel line lands on one row of pixels rather than across two.
    static func points(frame: CanvasFrame, radius r: Float) -> [(x: Float, y: Float)] {
        let left = frame.x + 0.5
        let right = frame.x + frame.w - 0.5
        let top = frame.y + 0.5
        let bottom = frame.y + frame.h
        var out: [(x: Float, y: Float)] = [(left, bottom)]
        arc(into: &out, cx: left + r, cy: top + r, r: r, from: .pi, to: .pi * 1.5)
        arc(into: &out, cx: right - r, cy: top + r, r: r, from: .pi * 1.5, to: .pi * 2)
        out.append((right, bottom))
        return out
    }

    private static func arc(
        into out: inout [(x: Float, y: Float)],
        cx: Float, cy: Float, r: Float, from start: Float, to end: Float
    ) {
        let steps = 6
        for step in 0...steps {
            let t = start + (end - start) * Float(step) / Float(steps)
            out.append((cx + r * cos(t), cy + r * sin(t)))
        }
    }
}

// MARK: - Toolbar

private struct Toolbar: View {
    @Bindable var session: ExplorerSession
    let paneID: Int
    /// This pane's current tab — not necessarily the active pane's.
    let tab: ExplorerTab

    var body: some View {
        let draft = Binding(
            get: { session.pathDraft(in: paneID) },
            set: { session.setPathDraft($0, in: paneID) }
        )
        return HStack(padding: 8, alignment: .center, spacing: 8) {
            navButton("◀", enabled: tab.history.canGoBack, id: "back") {
                session.goBack()
            }
            navButton("▶", enabled: tab.history.canGoForward, id: "forward") {
                session.goForward()
            }
            navButton("▲", enabled: tab.history.canGoUp, id: "up") {
                session.goUp()
            }
            TextField(
                text: draft,
                placeholder: "Path",
                // The field was pressed to be typed in, which made this pane
                // the active one — so the session's own draft is this one.
                onSubmit: { session.go(session.pathDraft) }
            )
            .padding(6)
            .background(Theme.current.background)
            .cornerRadius(4)
            .flexGrow(1)
            .agentId("path-field")
            Text(
                "Hidden",
                color: tab.showHidden
                    ? Theme.current.textPrimary : Theme.current.textSecondary,
                align: .center,
                onClick: { session.toggleHidden() }
            )
            .padding(6)
            .background(tab.showHidden ? Theme.current.selectionFill : Color.clear)
            .hoverBackground(
                tab.showHidden ? Theme.current.selectionFill : Theme.current.hover
            )
            .cornerRadius(4)
            .cursor(.pointer)
            .agentId("toggle-hidden")
        }
        .frame(height: .pt(44))
        .background(Theme.current.panel)
    }

    private func navButton(
        _ glyph: String, enabled: Bool, id: String, action: @escaping () -> Void
    ) -> some View {
        Text(
            glyph,
            color: enabled ? Theme.current.textPrimary : Theme.current.textDim,
            align: .center,
            onClick: enabled ? action : nil
        )
        .padding(6)
        .frame(width: .pt(32), height: .pt(28))
        .hoverBackground(enabled ? Theme.current.hover : Color.clear)
        .cornerRadius(4)
        .cursor(enabled ? .pointer : .arrow)
        .flexShrink(0)
        .agentId(id)
    }
}

// MARK: - Sidebar

/// Places, under a title row that holds the window buttons — the one strip
/// that is always in the top-left corner, however the panes are split.
private struct Sidebar: View {
    @Bindable var session: ExplorerSession

    var body: some View {
        VStack(flexGrow: 1, padding: 0, spacing: 0) {
            HStack(
                height: .pt(PaneChrome.stripHeight), padding: 0,
                alignment: .center, spacing: 0
            ) {
                if WindowBridge.drawsOwnChrome {
                    WindowControls()
                        .windowChrome()
                        .padding(8)
                }
                Spacer()
                    .frame(height: .pt(PaneChrome.stripHeight), minWidth: 24)
                    .windowDrag()
            }
            VStack(flexGrow: 1, padding: 8, spacing: 2) {
                Text("PLACES", color: Theme.current.textDim)
                    .padding(6)
                ForEach(session.places) { place in
                    let on = FolderHistory.normalize(place.path) == session.listing.path
                    Text(
                        place.title,
                        color: on ? Theme.current.textPrimary : Theme.current.textSecondary,
                        onClick: { session.go(place.path) }
                    )
                    .padding(8)
                    .background(on ? Theme.current.selectionFill : Color.clear)
                    .hoverBackground(on ? Theme.current.selectionFill : Theme.current.hover)
                    .cornerRadius(6)
                    .cursor(.pointer)
                    .agentId("place-\(place.title.lowercased())")
                }
                Spacer()
            }
        }
        .background(Theme.current.panel)
    }
}

// MARK: - List

private struct FilePane: View {
    @Bindable var session: ExplorerSession
    let paneID: Int
    let tab: ExplorerTab

    var body: some View {
        let listing = tab.listing
        let selectedIndex = tab.selected.flatMap { selected in
            listing.entries.firstIndex { $0.path == selected }
        }
        return VStack(flexGrow: 1, padding: 0, spacing: 0) {
            header
            if let error = listing.error {
                Text(error, color: Theme.current.textDim)
                    .padding(16)
                    .agentId("listing-error")
                Spacer()
            } else if listing.entries.isEmpty {
                Text("This folder is empty", color: Theme.current.textDim)
                    .padding(16)
                    .agentId("listing-empty")
                Spacer()
            } else {
                ScrollView(.vertical) {
                    LazyVStack(
                        listing.entries,
                        rowHeight: 28,
                        spacing: 0,
                        scrollTarget: selectedIndex
                    ) { entry in
                        FileRow(
                            session: session, paneID: paneID, entry: entry,
                            selected: tab.selected == entry.path
                        )
                    }
                }
                .flexGrow(1)
            }
        }
    }

    private var header: some View {
        HStack(padding: 8, alignment: .center, spacing: 8) {
            sortHeader(.name)
                .flexGrow(1)
            sortHeader(.size)
                .frame(width: .pt(88))
            sortHeader(.modified)
                .frame(width: .pt(148))
        }
        .background(Theme.current.panel)
    }

    private func sortHeader(_ sort: FileSort) -> some View {
        let on = tab.sort == sort
        let mark = on ? (tab.sortDescending ? " ▼" : " ▲") : ""
        return Text(
            sort.title + mark,
            color: on ? Theme.current.textPrimary : Theme.current.textDim,
            onClick: { session.setSort(sort) }
        )
        .cursor(.pointer)
        .agentId("sort-\(sort.rawValue)")
    }
}

private struct FileRow: View {
    @Bindable var session: ExplorerSession
    let paneID: Int
    let entry: FileEntry
    let selected: Bool

    var body: some View {
        let on = selected
        let theme = Theme.current
        let menuX = session.menuX
        let menuY = session.menuY
        let paneID = self.paneID
        return HStack(
            height: .pt(28),
            padding: 4,
            alignment: .center,
            spacing: 8,
            onPointer: { mods, button in
                if button == PointerButton.right {
                    session.openContext(entry)
                    return
                }
                guard button == PointerButton.left else { return }
                if KeyMods.contains(mods, KeyMods.control), entry.isDirectory {
                    session.newTab(path: entry.path)
                    return
                }
                let p = PointerState.window
                session.click(entry, clicks: ClickCounter.register(x: p.x, y: p.y))
            }
        ) {
            Text(
                entry.isDirectory ? "▣" : "▤",
                color: entry.isDirectory ? theme.accent : theme.textDim
            )
            .frame(width: .pt(18))
            Text(
                entry.name,
                color: theme.textPrimary,
                lineLimit: 1
            )
            .flexGrow(1)
            Text(entry.sizeLabel, color: theme.textDim)
                .frame(width: .pt(88))
            Text(Formatters.modified(entry.modified), color: theme.textDim)
                .frame(width: .pt(148))
        }
        .frame(width: .pct(100))
        .background(on ? theme.selectionFill : Color.clear)
        .hoverBackground(on ? theme.selectionFill : theme.hover)
        .hoverSnap()
        .cursor(.pointer)
        .agentId("file-\(entry.name)")
        .onFileDrag(paths: { session.dragPaths(for: entry) }) {
            FileDragChip(entry: entry)
        }
        .overlay(
            isPresented: Binding(
                get: {
                    session.contextEntry?.path == entry.path
                        && session.contextPaneID == paneID
                },
                set: { shown in
                    if !shown, session.contextEntry?.path == entry.path {
                        session.dismissContext()
                    }
                }
            ),
            placement: OverlayPlacement { context in
                let width = context.idealSize.width
                let height = context.idealSize.height
                let x = min(max(0, menuX), max(0, context.viewport.width - width))
                let y = min(max(0, menuY), max(0, context.viewport.height - height))
                return OverlayFrame(x: x, y: y, width: width, height: height)
            },
            style: {
                var style = MenuBarStyle.standard(theme: theme).overlayStyle
                style.minWidth = 220
                return style
            }()
        ) {
            if session.contextEntry?.path == entry.path, session.contextPaneID == paneID {
                FileContextMenu(session: session, entry: entry)
            }
        }
    }
}

/// What follows the pointer while a row is dragged out: the row's glyph and
/// name, on a plate. Ordinary views — the compositor draws them once and moves
/// the result, so nothing here has to know it ends up as a texture.
private struct FileDragChip: View {
    let entry: FileEntry

    var body: some View {
        let theme = Theme.current
        return HStack(padding: 8, alignment: .center, spacing: 8) {
            Text(
                entry.isDirectory ? "▣" : "▤",
                color: entry.isDirectory ? theme.accent : theme.textDim
            )
            Text(entry.name, color: theme.textPrimary, lineLimit: 1)
        }
        .background(theme.panel)
        .cornerRadius(6)
    }
}

/// Right-click menu. Open / Open With / Set Default are real; copy and
/// delete are labelled stubs — they set a notice rather than touching the
/// disk.
private struct FileContextMenu: View {
    @Bindable var session: ExplorerSession
    let entry: FileEntry

    var body: some View {
        let theme = Theme.current
        let handlers = session.handlers(for: entry)
        let defaultId = session.defaultHandlerId(for: entry)
        return MenuDropdownPanel(
            entries: entries(handlers: handlers, defaultId: defaultId),
            onActivate: { id in session.performContext(id.raw, entry: entry) },
            style: .standard(theme: theme)
        )
    }

    private func entries(
        handlers: [DesktopEntry], defaultId: String?
    ) -> [MenuEntry] {
        var items: [MenuEntry] = [
            .item(MenuItemModel(id: MenuID("ctx.open"), title: "Open")),
            .item(MenuItemModel(
                id: MenuID("ctx.open-tab"),
                title: "Open in New Tab",
                isEnabled: entry.isDirectory
            )),
        ]
        items.append(.submenu(MenuNode(
            id: MenuID("ctx.open-with"),
            title: "Open With",
            items: appItems(handlers, prefix: "ctx.open-with.", defaultId: defaultId)
        )))
        items.append(.submenu(MenuNode(
            id: MenuID("ctx.set-default"),
            title: "Set Default App",
            items: appItems(handlers, prefix: "ctx.set-default.", defaultId: defaultId)
        )))
        items.append(.separator)
        items.append(.item(MenuItemModel(id: MenuID("ctx.copy"), title: "Copy")))
        items.append(.item(MenuItemModel(id: MenuID("ctx.cut"), title: "Cut")))
        items.append(.item(MenuItemModel(id: MenuID("ctx.paste"), title: "Paste")))
        items.append(.separator)
        items.append(.item(MenuItemModel(id: MenuID("ctx.rename"), title: "Rename")))
        items.append(.item(MenuItemModel(id: MenuID("ctx.delete"), title: "Delete")))
        items.append(.separator)
        items.append(.item(MenuItemModel(
            id: MenuID("ctx.copy-path"), title: "Copy Path"
        )))
        return items
    }

    private func appItems(
        _ handlers: [DesktopEntry], prefix: String, defaultId: String?
    ) -> [MenuEntry] {
        if handlers.isEmpty {
            return [.item(MenuItemModel(
                id: MenuID("\(prefix)none"),
                title: "No applications",
                isEnabled: false
            ))]
        }
        return handlers.map { app in
            .item(MenuItemModel(
                id: MenuID("\(prefix)\(app.id)"),
                title: app.name,
                isChecked: app.desktopFileId == defaultId
            ))
        }
    }
}

private enum Formatters {
    static func modified(_ date: Date?) -> String {
        guard let date else { return "—" }
        return stamp.string(from: date)
    }

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}

// MARK: - Status

private struct StatusBar: View {
    @Bindable var session: ExplorerSession

    var body: some View {
        HStack(padding: 8, alignment: .center, spacing: 8) {
            Text(session.status, color: Theme.current.textDim, lineLimit: 1)
                .agentId("status")
            Spacer()
            Text(session.title, color: Theme.current.textSecondary)
        }
        .frame(height: .pt(28))
        .background(Theme.current.panel)
    }
}
