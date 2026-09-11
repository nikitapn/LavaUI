import Foundation
import LavaExplorerCore
import LavaShell
import LavaUI

/// Classic one-pane file manager: places on the left, a details list on the
/// right, an address bar along the top. Not dual-pane, not a spatial window
/// per folder — Thunar and Explorer, not Midnight Commander.
struct ExplorerView: View {
    @Bindable var session: ExplorerSession

    var body: some View {
        VStack(flexGrow: 1, padding: 0, spacing: 0) {
            TabStrip(session: session)
            Toolbar(session: session)
            HSplitView(
                fraction: $session.sidebarFraction,
                minLeading: 140,
                minTrailing: 360
            ) {
                Sidebar(session: session)
            } trailing: {
                FilePane(session: session)
            }
            StatusBar(session: session)
        }
        .background(Theme.current.background)
        .onDrop { urls in session.acceptDrop(urls) }
    }
}

// MARK: - Tabs

/// Folder names along the top, the way Explorer and every browser do it.
///
/// The window buttons live here rather than on the path row: a second
/// cluster of close/min/max next to Back is two things that look like
/// chrome. Leftover space after the plus is the drag handle.
private struct TabStrip: View {
    @Bindable var session: ExplorerSession

    static let height: Float = 36

    var body: some View {
        HStack(height: .pt(Self.height), padding: 0, alignment: .center, spacing: 4) {
            if WindowBridge.drawsOwnChrome {
                WindowControls()
                    .windowChrome()
                    .padding(8)
            }
            ForEach(session.tabSet.tabs) { tab in
                tabChip(tab)
            }
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
                .frame(height: .pt(Self.height), minWidth: 48)
                .windowDrag()
        }
        .background(Theme.current.panel)
    }

    private func tabChip(_ tab: ExplorerTab) -> some View {
        let on = tab.id == session.tabSet.currentID
        let theme = Theme.current
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
            Text(
                tab.title,
                color: on ? theme.textPrimary : theme.textSecondary,
                lineLimit: 1
            )
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
        .background(on ? theme.background : Color.clear)
        .hoverBackground(on ? theme.background : theme.hover)
        .cornerRadius(6)
        .cursor(.pointer)
        .flexShrink(1)
        .agentId("tab-\(tab.id)")
    }
}

// MARK: - Toolbar

private struct Toolbar: View {
    @Bindable var session: ExplorerSession

    var body: some View {
        HStack(padding: 8, alignment: .center, spacing: 8) {
            navButton("◀", enabled: session.history.canGoBack, id: "back") {
                session.goBack()
            }
            navButton("▶", enabled: session.history.canGoForward, id: "forward") {
                session.goForward()
            }
            navButton("▲", enabled: session.history.canGoUp, id: "up") {
                session.goUp()
            }
            TextField(
                text: $session.pathDraft,
                placeholder: "Path",
                onSubmit: { session.go(session.pathDraft) }
            )
            .padding(6)
            .background(Theme.current.background)
            .cornerRadius(4)
            .flexGrow(1)
            .agentId("path-field")
            Text(
                session.showHidden ? "Hidden" : "Hidden",
                color: session.showHidden
                    ? Theme.current.textPrimary : Theme.current.textSecondary,
                align: .center,
                onClick: { session.toggleHidden() }
            )
            .padding(6)
            .background(session.showHidden ? Theme.current.selectionFill : Color.clear)
            .hoverBackground(
                session.showHidden ? Theme.current.selectionFill : Theme.current.hover
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

private struct Sidebar: View {
    @Bindable var session: ExplorerSession

    var body: some View {
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
        .background(Theme.current.panel)
    }
}

// MARK: - List

private struct FilePane: View {
    @Bindable var session: ExplorerSession

    var body: some View {
        VStack(flexGrow: 1, padding: 0, spacing: 0) {
            header
            if let error = session.listing.error {
                Text(error, color: Theme.current.textDim)
                    .padding(16)
                    .agentId("listing-error")
                Spacer()
            } else if session.listing.entries.isEmpty {
                Text("This folder is empty", color: Theme.current.textDim)
                    .padding(16)
                    .agentId("listing-empty")
                Spacer()
            } else {
                ScrollView(.vertical) {
                    LazyVStack(
                        session.listing.entries,
                        rowHeight: 28,
                        spacing: 0,
                        scrollTarget: session.selectedIndex
                    ) { entry in
                        FileRow(session: session, entry: entry)
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
        let on = session.sort == sort
        let mark = on ? (session.sortDescending ? " ▼" : " ▲") : ""
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
    let entry: FileEntry

    var body: some View {
        let on = session.selected == entry.path
        let theme = Theme.current
        let menuX = session.menuX
        let menuY = session.menuY
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
                get: { session.contextEntry?.path == entry.path },
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
            if session.contextEntry?.path == entry.path {
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
