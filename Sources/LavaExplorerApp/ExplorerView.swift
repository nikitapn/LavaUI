import Foundation
import LavaArchive
import LavaExplorerCore
import LavaRemote
import LavaShell
import LavaUI

/// Measurements a pane's chrome and the drop logic have to agree on.
enum PaneChrome {
    /// The tab strip, and the sidebar's title row beside it.
    static let stripHeight: Float = 36
    /// Shorter than the strip: the gap above is what makes the active tab
    /// read as a tab rather than a stripe.
    static let tabHeight: Float = 30
    static let outlineWidth: Float = 2

    /// A dialog's card: the panes' colour, the design's 24pt corner, and
    /// the window dimmed behind it.
    static var dialogStyle: OverlayStyle {
        let look = ExplorerLook.current
        return OverlayStyle(background: look.card, border: look.divider, cornerRadius: 24,
                            padding: 22, scrim: look.text.opacity(0.18), modal: true)
    }

    /// The menus in the window — a file's, a drop's — as the desktop's menus
    /// are drawn: a rounded plate, rows that light up in the accent.
    static var menuStyle: MenuBarStyle {
        let look = ExplorerLook.current
        var style = MenuBarStyle.standard(theme: Theme.current)
        style.itemPadding = EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 12)
        style.itemCornerRadius = 12
        style.itemHover = look.accent200
        style.itemSpacing = 0
        style.dropdownPadding = 6
        style.dropdownMinWidth = 240
        style.dropdownBackground = look.card
        style.dropdownBorder = look.divider
        style.dropdownCornerRadius = 18
        style.dropdownBlur = nil
        return style
    }

    /// The gap between the sidebar and the panes, and between two panes:
    /// the design draws no rule there, only space — which still drags.
    static var splitStyle: SplitStyle {
        let look = ExplorerLook.current
        return SplitStyle(thickness: 10, lineThickness: 0, color: .clear, background: .clear,
                          hover: look.press.opacity(0.5), active: look.accent300)
    }
}

/// Places on the left; on the right, one or more panes, each a browser of its
/// own — tabs, an address bar and a details list. Drag a tab to the edge of a
/// pane to split it, or into another pane to move it there. Drag a file onto
/// a folder, a pane, a tab or a place to copy it there; drag it with the
/// right button to be asked whether to copy or move it.
struct ExplorerView: View {
    @Bindable var session: ExplorerSession

    var body: some View {
        if let fonts = explorerFonts {
            content.font(fonts.body)
        } else {
            content
        }
    }

    private var content: some View {
        let dropX = session.dropMenu?.x ?? 0
        let dropY = session.dropMenu?.y ?? 0
        return VStack(flexGrow: 1, padding: 0, spacing: 0) {
            HSplitView(
                fraction: $session.sidebarFraction,
                minLeading: 140,
                minTrailing: 360,
                style: PaneChrome.splitStyle
            ) {
                Sidebar(session: session)
            } trailing: {
                VStack(flexGrow: 1, padding: 0, spacing: 0) {
                    PaneTree.build(session, session.layout.root)
                }
                .padding(EdgeInsets(top: 8, leading: 0, bottom: 0, trailing: 12))
            }
            if let chooser = session.chooser {
                ChooserBar(session: session, chooser: chooser)
            }
            StatusBar(session: session)
        }
        .background(ExplorerLook.current.surface)
        .onDrop { urls in session.acceptDrop(urls) }
        .overlayLayer { TabGhost(session: session) }
        .overlayLayer { RightDragGhost(session: session) }
        // A question — a clash, a password, a server — in the middle of the
        // window over a dimmed one. A click outside it answers nothing: a
        // dialog is put away by its own buttons, or Escape.
        .overlay(
            isPresented: Binding(get: { PromptDialog.isWaiting(session) }, set: { _ in }),
            placement: OverlayPlacement { context in
                let width = context.idealSize.width
                let height = context.idealSize.height
                let x = max(0, (context.viewport.width - width) / 2)
                // A little above the middle, where the eye already is.
                let y = max(0, (context.viewport.height - height) * 0.42)
                return OverlayFrame(x: x, y: y, width: width, height: height)
            },
            style: PaneChrome.dialogStyle
        ) {
            if let fonts = explorerFonts {
                PromptDialog(session: session).font(fonts.body)
            } else {
                PromptDialog(session: session)
            }
        }
        .overlay(
            isPresented: Binding(
                get: { session.dropMenu != nil },
                set: { shown in if !shown { session.resolveDropMenu(nil) } }
            ),
            placement: OverlayPlacement { [dropX, dropY] context in
                let width = context.idealSize.width
                let height = context.idealSize.height
                let x = min(max(0, dropX), max(0, context.viewport.width - width))
                let y = min(max(0, dropY), max(0, context.viewport.height - height))
                return OverlayFrame(x: x, y: y, width: width, height: height)
            },
            style: {
                var style = PaneChrome.menuStyle.overlayStyle
                style.minWidth = 200
                return style
            }()
        ) {
            if let menu = session.dropMenu {
                DropChoiceMenu(session: session, menu: menu).inExplorerFont()
            }
        }
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
                    HSplitView(fraction: fraction, minLeading: 240, minTrailing: 240,
                               style: PaneChrome.splitStyle) {
                        build(session, split.first)
                    } trailing: {
                        build(session, split.second)
                    }
                )
            case .vertical:
                return AnyView(
                    VSplitView(fraction: fraction, minTop: 160, minBottom: 160,
                               style: PaneChrome.splitStyle) {
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
        // The outline that says which pane the keys go to — only when there
        // is more than one to choose between.
        let split = session.layout.panes.count > 1
        let ringed = active && split
        let outlineInset = split ? PaneChrome.outlineWidth : 0
        return VStack(flexGrow: 1, padding: 0, spacing: 0) {
            if let pane {
                ExplorerTabs(session: session, pane: pane, ringed: ringed, outlineInset: outlineInset)
                VStack(flexGrow: 1, padding: 0, spacing: 0) {
                    PaneCard(session: session, pane: pane) {
                        Toolbar(session: session, paneID: paneID, tab: pane.tabs.current)
                        if let draft = session.bulkRenameDraft, draft.tabID == pane.tabs.current.id {
                            BulkRenamePane(session: session, draft: draft)
                        } else {
                            FilePane(session: session, paneID: paneID, tab: pane.tabs.current)
                        }
                        PaneFooter(session: session, tab: pane.tabs.current, active: active)
                    }
                }
                // SplitView clips to the pane. Reserve space for the card's
                // outer stroke on both panes so switching focus keeps them still.
                .padding([.leading, .trailing, .bottom], outlineInset)
            }
        }
        .padding(EdgeInsets(top: 4, leading: 0, bottom: 0, trailing: 0))
        // Before anything in the pane handles the press, so the row, button
        // or field it lands on already acts on this pane.
        .onAnyPress { _ in session.activatePane(paneID) }
        // A press anywhere in the pane takes the keyboard from the address
        // bar — the files, a toolbar button, a tab — so its caret stops and
        // the arrows are the list's again. Pressing the field itself still
        // gives it the keyboard: its own click runs after this. The keys are
        // still `keys` in the app, which runs first; this only says where
        // focus is.
        .focusable(onKey: { _ in false })
        .onFrame { frame in session.notePaneFrame(paneID, frame) }
        .overlayLayer { PaneDropPreview(session: session, paneID: paneID) }
    }
}

/// Where a dragged tab would go if it were let go of now, over the pane it
/// would go to: half the pane for a split, all of it for a move, a bar in the
/// gap for a place in the strip.
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

/// A list a drag of files is aimed at: an outline just inside its edge, so
/// the rows under the pointer stay readable.
private struct DropOutline: View {
    let active: Bool

    var body: some View {
        Canvas(label: "drop-outline", width: .pct(100), height: .pct(100)) { list, frame in
            guard active else { return }
            let theme = Theme.current
            let x = frame.x + 3
            let y = frame.y + 3
            let w = max(0, frame.w - 6)
            let h = max(0, frame.h - 6)
            list.roundedRect(x: x, y: y, w: w, h: h, color: theme.accent.opacity(0.08), radius: 6)
            list.strokedRect(
                x: x, y: y, w: w, h: h, color: theme.accent.opacity(0.7), radius: 6, width: 2
            )
        }
    }
}

/// Rows carried with the right button where no compositor can carry them
/// (windowed): the same plate `FileDragChip` is, drawn beside the pointer.
/// In client mode the compositor draws the chip and this is never up.
private struct RightDragGhost: View {
    @Bindable var session: ExplorerSession

    var body: some View {
        let drag = session.rightDrag
        return Canvas(label: "right-drag-ghost", width: .pct(100), height: .pct(100)) { list, frame in
            guard let drag, let first = drag.paths.first else { return }
            let theme = Theme.current
            let font = FontStore.default
            let lineHeight = font?.lineHeight ?? 16
            let pointer = PointerState.window
            let name = (first as NSString).lastPathComponent
            let others = drag.paths.count - 1
            let badge = others > 0 ? "+\(others)" : ""
            // A little over the measured width: a run is drawn a few pixels
            // wider than it shapes, and an exact clip takes its last letter.
            let nameW = min(220, (font?.measure(name).width ?? Float(name.count) * 7) + 6)
            let badgeTextW = (font?.measure(badge).width ?? 16) + 6
            let badgeW: Float = badge.isEmpty ? 0 : badgeTextW + 8 + 8
            let w = 8 + 16 + 8 + nameW + badgeW + 8
            let h = lineHeight + 16
            let x = min(max(frame.x, pointer.x + 16), frame.x + frame.w - w - 4)
            let y = min(max(frame.y, pointer.y + 12), frame.y + frame.h - h - 4)
            list.roundedRect(x: x, y: y, w: w, h: h, color: theme.panel.opacity(0.95), radius: 6)
            list.strokedRect(
                x: x, y: y, w: w, h: h,
                color: drag.paneID == nil ? theme.border : theme.accent, radius: 6, width: 1
            )
            let ty = y + (h - lineHeight) * 0.5
            list.text(
                drag.isDirectory ? "▣" : "▤", x: x + 8, y: ty, w: 16, h: lineHeight,
                color: drag.isDirectory ? theme.accent : theme.textDim, font: font
            )
            list.pushClip(x: x + 32, y: y, w: nameW, h: h)
            list.text(name, x: x + 32, y: ty, w: nameW, h: lineHeight, color: theme.textPrimary, font: font)
            list.popClip()
            if !badge.isEmpty {
                let bx = x + 32 + nameW + 8
                list.roundedRect(
                    x: bx, y: ty, w: badgeW - 8, h: lineHeight, color: theme.accent, radius: 8
                )
                list.text(
                    badge, x: bx + 4, y: ty, w: badgeTextW, h: lineHeight,
                    color: theme.textPrimary, font: font
                )
            }
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

/// The picker's own row: what is being opened or the name to save under,
/// which files to show, and the two ways out. Only when another app started
/// this window as its file chooser.
private struct ChooserBar: View {
    @Bindable var session: ExplorerSession
    let chooser: ChooserRequest

    var body: some View {
        let look = ExplorerLook.current
        let fonts = explorerFonts
        let saving = chooser.mode == .save
        let choosingFolder = chooser.mode == .folder
        let answer = choosingFolder ? session.folderAnswer.map { [$0] } : session.openAnswer
        let picked: String = {
            if choosingFolder {
                // Named, so it is plain whether Choose means the highlighted
                // folder or the one being looked at.
                guard let folder = answer?.first else { return "Not a folder to choose" }
                return (folder as NSString).lastPathComponent.isEmpty
                    ? folder : (folder as NSString).lastPathComponent
            }
            guard let answer else { return "Choose a file" }
            if answer.count > 1 { return ExplorerSession.items(answer.count) }
            return (answer[0] as NSString).lastPathComponent
        }()
        let canConfirm = saving
            ? !session.saveName.trimmingCharacters(in: .whitespaces).isEmpty
            : answer != nil || (!choosingFolder && session.selectedEntries.contains(where: \.isDirectory))
        return HStack(padding: 0, alignment: .center, spacing: 10) {
            if saving {
                Text("Name", color: look.soft, font: fonts?.crumbSemi)
                TextField(
                    text: $session.saveName,
                    font: fonts?.body,
                    autoFocus: true,
                    selectionOnFocus: .leading(
                        Rename.stemLength(of: session.saveName, isDirectory: false)
                    ),
                    onSubmit: { session.confirmChoice() }
                )
                .padding(EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10))
                .background(look.card)
                .border(look.divider)
                .cornerRadius(12)
                .flexGrow(1)
                .agentId("chooser-name")
            } else {
                Text(picked, color: answer == nil ? look.soft : look.text,
                     font: answer == nil ? fonts?.body : fonts?.bodySemi, lineLimit: 1)
                    .flexGrow(1)
                    .flexShrink(1)
                    .agentId("chooser-picked")
            }
            if chooser.filters.count > 1 {
                ComboBox(
                    selection: Binding(
                        get: { session.chooserFilterIndex },
                        set: { session.setChooserFilter($0) }
                    ),
                    items: chooser.filters.enumerated().map { index, filter in
                        ComboBoxItem(filter.name, tag: index)
                    },
                    width: .pt(200)
                )
                .agentId("chooser-filter")
            } else if let only = chooser.filters.first {
                Text(only.name, color: look.soft, font: fonts?.caption, lineLimit: 1)
            }
            DialogButton("Cancel", id: "chooser-cancel") { session.cancelChoosing() }
            DialogButton(saving ? "Save" : choosingFolder ? "Choose" : "Open", prominent: true,
                         id: "chooser-confirm") {
                if canConfirm { session.confirmChoice() }
            }
        }
        .padding(EdgeInsets(top: 10, leading: 22, bottom: 4, trailing: 14))
    }
}

// MARK: - Tabs

/// One pane's folder names, the way Explorer and every browser do it. Drag a
/// tab to move it; leftover space after the plus is the window drag handle.
private struct ExplorerTabs: View {
    @Bindable var session: ExplorerSession
    let pane: ExplorerPane
    let ringed: Bool
    let outlineInset: Float

    static let height: Float = 40
    static let radius: Float = 16

    var body: some View {
        let look = ExplorerLook.current
        return HStack(height: .pt(Self.height), padding: 0, alignment: .end, spacing: 4) {
            // The current tab runs a card's corner down past the strip, and
            // the card covers it everywhere but under its rounded corner: a
            // current tab over that corner squares it, and moves with the
            // strip when the renderer scrolls it.
            ScrollView(.horizontal, showsIndicator: false,
                       clipOutsetBottom: PaneCard<EmptyView>.radius) {
                HStack(height: .pt(Self.height), padding: 0, alignment: .end, spacing: 4) {
                    ForEach(pane.tabs.tabs) { tab in
                        item(tab, look: look)
                    }
                }
                // The scroll viewport clips the first and last tab's outline.
                .padding(.horizontal, outlineInset)
            }
            .flexGrow(0)
            .flexShrink(1)
            // In a stack of its own: padding on the button itself lands inside
            // its node, which grew the hover disc to 34×36 round a + still
            // drawn for 30×30.
            VStack(padding: 0, spacing: 0) {
                HStack(width: .pt(30), height: .pt(30), padding: 0, alignment: .center,
                       spacing: 0, onClick: { session.newTab() }) {
                    Icon([.path(ExplorerGlyphs.plus)], size: 15, color: look.soft,
                         strokeWidth: 2.75, box: 30)
                }
                .hoverBackground(look.press)
                .cornerRadius(15)
                .cursor(.pointer)
                .tooltip("New Tab")
                .agentId("new-tab")
            }
            .padding(EdgeInsets(top: 0, leading: 4, bottom: 6, trailing: 0))
            .flexShrink(0)
            // What is left of the strip moves the window, as a title bar would.
            Spacer()
                .frame(height: .pt(Self.height), minWidth: 48)
                .windowDrag()
        }
        .underlay {
            // The active pane's ring, drawn here rather than by the card so
            // that it is under the tabs: where the current tab meets the
            // card, the tab's own fill covers the ring's top edge, and moves
            // with the tab when the renderer scrolls the strip. A join drawn
            // by the card stayed where the tab had been laid out.
            Canvas(label: "pane-ring", width: .pct(100), height: .pct(100)) { list, _ in
                guard ringed, let card = session.cardFrames[pane.id] else { return }
                let edge = PaneChrome.outlineWidth, r = PaneCard<EmptyView>.radius
                list.roundedRect(x: card.x - edge, y: card.y - edge, w: card.w + 2 * edge,
                                 h: card.h + 2 * edge, color: look.accent300, radius: r + edge)
            }
        }
    }

    /// A tab: a folder, the name, a close button. The current one is the
    /// card's own colour and runs into it, square at the bottom.
    private func item(_ tab: ExplorerTab, look: ExplorerLook) -> some View {
        let fonts = explorerFonts
        let on = tab.id == pane.tabs.currentID
        let aimedAt = session.dropHover == .tab(tab.id)
        let font = on ? fonts?.bodySemi : fonts?.body
        let width = min(200, font?.measure(tab.title).width ?? 120)
        let ringed = ringed && on
        let card = look.card, ring = look.accent300
        return HStack(padding: 0, alignment: .center, spacing: 2) {
            HStack(padding: 0, alignment: .center, spacing: 8,
                   onClick: { session.selectTab(id: tab.id) }) {
                Icon([.fill(ExplorerGlyphs.folder)], size: 14,
                     color: on ? look.sage600 : look.faint)
                Text(tab.title, color: on ? look.text : look.soft, font: font, lineLimit: 1)
                    .frame(width: .pt(width))
            }
            .padding(EdgeInsets(top: 9, leading: 10, bottom: 11, trailing: 4))
            HStack(width: .pt(22), height: .pt(22), padding: 0, alignment: .center, spacing: 0,
                   onClick: { session.closeTab(id: tab.id) }) {
                Icon([.path(ExplorerGlyphs.cross)], size: 12, color: on ? look.text : look.soft,
                     strokeWidth: 2.75, box: 22)
            }
            .hoverBackground(look.accent200)
            .cornerRadius(11)
            .agentId("close-tab-\(tab.id)")
        }
        .padding(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 6))
        // The current tab's fill is `tab-join`'s, below: it has to stop at
        // the card's edge, which a background cannot. Card on card was no
        // hover anyway.
        .background(aimedAt ? look.accent300 : Color.clear)
        .hoverBackground(on ? Color.clear : look.press.opacity(0.5))
        .cornerRadius(Self.radius)
        .underlay {
            // Square at the bottom where the current tab meets the card, and
            // the active pane's outline round its other three sides.
            Canvas(label: "tab-join", width: .pct(100), height: .pct(100)) { list, frame in
                guard on else { return }
                // Down past the strip by the card's corner: the card hides
                // all of it but what lies under its rounded corner, which a
                // tab over that corner squares. See `ExplorerTabs.body`.
                let below = PaneCard<EmptyView>.radius
                if ringed {
                    let edge = PaneChrome.outlineWidth
                    // The lower corners beyond the clip, so the sides stay
                    // straight all the way down.
                    list.roundedRect(x: frame.x - edge, y: frame.y - edge, w: frame.w + 2 * edge,
                                     h: frame.h + below + Self.radius + 2 * edge,
                                     color: ring, radius: Self.radius + edge)
                }
                // The fill stops at the card's left edge wherever the strip
                // has scrolled, so a tab pushed past it leaves the ring's
                // column outside the card showing: the card's side running
                // on up the tab's cut edge. A clip that scrolled with the tab
                // would cut nothing.
                let cardX = session.cardFrames[pane.id]?.x ?? frame.x
                list.pushClip(x: cardX, y: 0, w: 1_000_000, h: 1_000_000, fixedToWindow: true)
                list.roundedRect(x: frame.x, y: frame.y, w: frame.w,
                                 h: frame.h + below + Self.radius, color: card,
                                 radius: Self.radius)
                list.popClip()
            }
        }
        .cursor(.pointer)
        .onFrame { session.noteTabFrame(tab.id, $0) }
        .onDragGesture { session.dragTab(tab.id, $0) }
        .onDrop(
            targeted: { session.setDropHover(.tab(tab.id), $0) },
            springLoaded: { session.selectTab(id: tab.id) }
        ) { session.dropOnTab(id: tab.id, $0) }
        .agentId("tab-\(tab.id)")
    }
}

/// A pane's card: the toolbar, the files and the footer on the lightest
/// colour, rounded. Where the current tab sits over its top-left corner the
/// corner is square, so tab and card read as one shape — the tab draws that,
/// not the card: see `ExplorerTabs.body`.
private struct PaneCard<Content: View>: View {
    @Bindable var session: ExplorerSession
    let pane: ExplorerPane
    let content: Content

    static var radius: Float { 20 }

    init(session: ExplorerSession, pane: ExplorerPane,
         @ViewBuilder content: () -> Content) {
        self.session = session
        self.pane = pane
        self.content = content()
    }

    var body: some View {
        VStack(flexGrow: 1, padding: 0, spacing: 0) {
            content
        }
        .background(ExplorerLook.current.card)
        .cornerRadius(Self.radius)
        .clipped()
        .onFrame { session.noteCardFrame(pane.id, $0) }
    }
}

// MARK: - Toolbar

private struct Toolbar: View {
    @Bindable var session: ExplorerSession
    let paneID: Int
    /// This pane's current tab — not necessarily the active pane's.
    let tab: ExplorerTab

    var body: some View {
        let look = ExplorerLook.current
        // A press anywhere in a pane makes it the active one first, so the
        // session's current tab is this one by the time any of these runs.
        let canMake = !TrashPath.isTrash(tab.listing.path) && tab.listing.error == nil
        return HStack(padding: 0, alignment: .center, spacing: 4) {
            roundButton(ExplorerGlyphs.back, tip: "Back", enabled: tab.history.canGoBack,
                        id: "back") { session.goBack() }
            roundButton(ExplorerGlyphs.forward, tip: "Forward",
                        enabled: tab.history.canGoForward, id: "forward") { session.goForward() }
            roundButton(ExplorerGlyphs.up, tip: "Enclosing Folder", enabled: tab.history.canGoUp,
                        id: "up") { session.goUp() }
            address(look)
                .flexGrow(1)
                .flexShrink(1)
                .padding(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
            roundButton(ExplorerGlyphs.newFolder, tip: "New Folder", enabled: canMake,
                        id: "new-folder", stroke: 2.5) { session.startNewFolder() }
            viewSwitch(look)
        }
        .padding(EdgeInsets(top: 12, leading: 12, bottom: 8, trailing: 12))
    }

    /// Where this tab is, as crumbs to click — or, while it is being edited
    /// (Ctrl+L, or a click on the bar's empty end), the path as text.
    @ViewBuilder
    private func address(_ look: ExplorerLook) -> some View {
        if session.editingPathPane == paneID {
            let draft = Binding(
                get: { session.pathDraft(in: paneID) },
                set: { session.setPathDraft($0, in: paneID) }
            )
            TextField(
                text: draft,
                placeholder: "Path",
                // Ctrl+L: the whole address, so typing replaces it.
                selectionOnFocus: .all,
                // The keyboard goes back to the files, as a browser's does to
                // the page: the address has been used.
                onSubmit: {
                    session.editingPathPane = nil
                    session.go(session.pathDraft)
                }
            )
            .focused(session.pathFocus(in: paneID))
            .padding(EdgeInsets(top: 3, leading: 12, bottom: 3, trailing: 12))
            .frame(height: .pt(32))
            .background(look.well)
            .border(look.accent)
            .cornerRadius(16)
            .agentId("path-field")
        } else {
            crumbs(look)
        }
    }

    private func crumbs(_ look: ExplorerLook) -> some View {
        let fonts = explorerFonts
        let all = Crumb.of(tab.listing.path)
        // The bar's room: the pane, less the six buttons and the paddings.
        let room = (session.paneWidths[paneID] ?? 600) - 4 * 32 - 62 - 24 - 24 - 16
        let shown = Crumb.fitting(all, in: room, font: fonts?.crumb)
        let paneID = paneID
        return HStack(height: .pt(32), padding: 0, alignment: .center, spacing: 0,
                      onClick: { session.editingPathPane = paneID }) {
            ForEach(Array(shown.enumerated()), id: \.offset) { index, crumb in
                if index > 0 {
                    Icon([.path(ExplorerGlyphs.chevronRight)], size: 12, color: look.faint,
                         strokeWidth: 3)
                }
                crumbButton(crumb, last: index == shown.count - 1, look: look)
            }
            Spacer()
        }
        .padding(EdgeInsets(top: 3, leading: 4, bottom: 3, trailing: 4))
        .background(look.well)
        .cornerRadius(16)
        .clipped()
        .cursor(.text)
        .tooltip(tab.listing.path)
        .agentId("path-crumbs")
    }

    private func crumbButton(_ crumb: Crumb, last: Bool, look: ExplorerLook) -> some View {
        let fonts = explorerFonts
        let ink = last ? look.text : look.soft
        return HStack(padding: 0, alignment: .center, spacing: 6,
                      onClick: { session.go(crumb.path) }) {
            if let glyph = crumb.glyph {
                Icon([.path(glyph)], size: 13, color: ink, strokeWidth: 2.5)
            }
            if !crumb.label.isEmpty {
                Text(crumb.label, color: ink, font: last ? fonts?.crumbSemi : fonts?.crumb,
                     lineLimit: 1)
                    .flexShrink(1)
            }
        }
        .padding(EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10))
        .background(last ? look.card : Color.clear)
        .hoverBackground(look.card)
        .cornerRadius(13)
        .cursor(.pointer)
        .flexShrink(last ? 0 : 1)
        .agentId("crumb-\(crumb.path)")
    }

    /// List or icons, as two halves of one switch.
    private func viewSwitch(_ look: ExplorerLook) -> some View {
        HStack(padding: 3, alignment: .center, spacing: 0) {
            segment(ExplorerGlyphs.list, on: tab.viewMode == .list, tip: "Show as List",
                    id: "view-list", look: look) { session.setViewMode(.list) }
            segment(ExplorerGlyphs.grid, on: tab.viewMode == .icons, tip: "Show as Icons",
                    id: "view-icons", look: look) { session.setViewMode(.icons) }
        }
        .background(look.well)
        .cornerRadius(16)
        .flexShrink(0)
        .agentId("toggle-view")
    }

    private func segment(
        _ glyph: String, on: Bool, tip: String, id: String, look: ExplorerLook,
        action: @escaping () -> Void
    ) -> some View {
        HStack(width: .pt(28), height: .pt(26), padding: 0, alignment: .center, spacing: 0,
               onClick: action) {
            Icon([.path(glyph)], size: 14, color: on ? look.text : look.soft,
                 strokeWidth: 2.6, box: 28)
        }
        .background(on ? look.card : Color.clear)
        .cornerRadius(13)
        .cursor(.pointer)
        .tooltip(tip)
        .agentId(id)
    }

    private func roundButton(
        _ glyph: String, tip: String, enabled: Bool, id: String, stroke: Float = 2.75,
        action: @escaping () -> Void
    ) -> some View {
        let look = ExplorerLook.current
        return HStack(width: .pt(32), height: .pt(32), padding: 0, alignment: .center,
                      spacing: 0, onClick: enabled ? action : nil) {
            Icon([.path(glyph)], size: 16, color: enabled ? look.icon : look.icon.opacity(0.35),
                 strokeWidth: stroke, box: 32)
        }
        .hoverBackground(enabled ? look.press : Color.clear)
        .cornerRadius(16)
        .cursor(enabled ? .pointer : .arrow)
        .flexShrink(0)
        // Even while disabled: a greyed arrow is the one whose meaning a
        // user most needs to read.
        .tooltip(tip)
        .agentId(id)
    }
}

/// One step of the address bar.
struct Crumb: Equatable {
    var label: String
    var path: String
    /// Drawn before the label: the house for home.
    var glyph: String?

    /// Home and the folders under it; or the root and the folders under it;
    /// or a server and the folders on it. The Trash is one crumb.
    static func of(_ path: String, home: String = NSHomeDirectory()) -> [Crumb] {
        if TrashPath.isTrash(path) {
            return [Crumb(label: "Trash", path: path, glyph: ExplorerGlyphs.trash)]
        }
        if let url = RemoteURL(path) {
            var out = [Crumb(label: url.server.title,
                             path: RemoteURL(server: url.server, path: "/").string,
                             glyph: ExplorerGlyphs.server)]
            var acc = ""
            for part in url.path.split(separator: "/") {
                acc += "/" + part
                out.append(Crumb(label: String(part),
                                 path: RemoteURL(server: url.server, path: acc).string))
            }
            return out
        }
        var out: [Crumb]
        var rest: Substring
        var acc: String
        if path == home || path.hasPrefix(home + "/") {
            out = [Crumb(label: "Home", path: home, glyph: ExplorerGlyphs.home)]
            rest = path.dropFirst(home.count)
            acc = home
        } else {
            out = [Crumb(label: "Computer", path: "/", glyph: ExplorerGlyphs.computer)]
            rest = Substring(path)
            acc = ""
        }
        for part in rest.split(separator: "/") {
            acc += "/" + part
            out.append(Crumb(label: String(part), path: acc))
        }
        return out
    }

    /// What fits in `room`: all of it, or the first crumb (icon only), a "…"
    /// that goes up one, and as many of the last as there is room for.
    static func fitting(_ crumbs: [Crumb], in room: Float, font: UIFont?) -> [Crumb] {
        func width(_ c: Crumb) -> Float {
            (font?.measure(c.label).width ?? Float(c.label.count) * 7) + 20
                + (c.glyph == nil ? 0 : 19) + 12
        }
        guard crumbs.count > 2, crumbs.map(width).reduce(0, +) > room else { return crumbs }
        let first = Crumb(label: "", path: crumbs[0].path, glyph: crumbs[0].glyph)
        let parent = crumbs[crumbs.count - 2]
        let ellipsis = Crumb(label: "…", path: parent.path)
        var tail: [Crumb] = [crumbs[crumbs.count - 1]]
        var used = width(first) + width(ellipsis) + width(tail[0])
        for crumb in crumbs.dropFirst().dropLast().reversed() {
            let w = width(crumb)
            guard used + w <= room else { break }
            used += w
            tail.insert(crumb, at: 0)
        }
        // The ellipsis only stands for something when crumbs were left out.
        return tail.count == crumbs.count - 1 ? [crumbs[0]] + tail : [first, ellipsis] + tail
    }
}

/// Under a pane's files: how many there are, and what is selected.
private struct PaneFooter: View {
    @Bindable var session: ExplorerSession
    let tab: ExplorerTab
    let active: Bool

    var body: some View {
        let look = ExplorerLook.current
        let fonts = explorerFonts
        let listing = tab.listing
        let folders = listing.folderCount, files = listing.fileCount
        let counts = "\(folders) folder\(folders == 1 ? "" : "s") · "
            + "\(files) file\(files == 1 ? "" : "s")"
        let selection = tab.selection
        let info: String
        if selection.count > 1 {
            info = "\(selection.count) selected"
        } else if let path = tab.selected,
                  let entry = listing.entries.first(where: { $0.path == path }) {
            info = entry.isDirectory ? "“\(entry.name)” selected"
                : "“\(entry.name)” · \(entry.sizeLabel)"
        } else {
            info = ""
        }
        return HStack(padding: 0, alignment: .center, spacing: 8) {
            Text(counts, color: look.soft, font: fonts?.captionTabular, lineLimit: 1)
                .flexShrink(1)
            Spacer()
            Text(info, color: look.soft, font: fonts?.captionTabular, lineLimit: 1)
                .flexShrink(1)
        }
        .padding(EdgeInsets(top: 7, leading: 20, bottom: 7, trailing: 20))
        .underlay {
            Canvas(label: "footer-rule", width: .pct(100), height: .pct(100)) { list, frame in
                list.rect(x: frame.x, y: frame.y, w: frame.w, h: 1, color: look.divider)
            }
        }
    }
}

// MARK: - Sidebar

/// Places, under the window buttons — the one strip that is always in the
/// top-left corner, however the panes are split. `File Explorer.dc.html`'s
/// sidebar: the profile as a pill, then sections of rounded rows on the
/// window's own surface.
private struct Sidebar: View {
    @Bindable var session: ExplorerSession

    var body: some View {
        let look = ExplorerLook.current
        return VStack(flexGrow: 1, padding: 0, spacing: 0) {
            HStack(
                height: .pt(PaneChrome.stripHeight + 8), padding: 0,
                alignment: .center, spacing: 0
            ) {
                if WindowBridge.drawsOwnChrome {
                    WindowControls(style: WindowControlsStyle(
                        size: 13, spacing: 8, close: look.accent, minimize: look.accent400,
                        maximize: look.sage))
                        .windowChrome()
                        .padding(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 8))
                }
                Spacer()
                    .frame(height: .pt(PaneChrome.stripHeight + 8), minWidth: 24)
                    .windowDrag()
            }
            ScrollView(.vertical) {
                VStack(padding: 0, spacing: 2) {
                    if session.chooser == nil {
                        profilePill(look)
                        if session.profilePickerExpanded {
                            ForEach(session.profiles.profiles) { profile in
                                row(title: profile.name, glyph: ExplorerGlyphs.home,
                                    on: profile.id == session.profiles.selectedID,
                                    id: "profile-\(profile.id)") {
                                    session.selectProfile(profile.id)
                                }
                            }
                            row(title: "New Profile…", glyph: ExplorerGlyphs.plus, on: false,
                                id: "new-profile") { session.profileDraft = "" }
                        }
                        Spacer(flexGrow: 0).frame(height: .pt(10))
                    }
                    sectionHeader("Places", expanded: session.placesExpanded) {
                        session.placesExpanded.toggle()
                    }
                    if session.placesExpanded {
                        ForEach(session.places) { place in
                            placeRow(place)
                        }
                    }
                    sectionGap
                    sectionHeader("Favorites", expanded: session.favoritesExpanded) {
                        session.favoritesExpanded.toggle()
                    }
                    if session.favoritesExpanded {
                        ForEach(session.favorites, id: \.self) { path in
                            favoriteRow(path)
                        }
                        if session.favorites.isEmpty {
                            note("Right-click a folder to add")
                        }
                    }
                    sectionGap
                    sectionHeader("Devices", expanded: session.devicesExpanded) {
                        session.devicesExpanded.toggle()
                    }
                    if session.devicesExpanded {
                        ForEach(session.devices) { volume in
                            deviceRow(volume)
                        }
                        if let error = session.devicesError {
                            note(error).tooltip(error)
                        } else if session.devices.isEmpty {
                            note(session.devicesLoaded ? "No devices" : "Looking for devices…")
                        }
                    }
                    sectionGap
                    sectionHeader("Servers", expanded: session.serversExpanded) {
                        session.serversExpanded.toggle()
                    }
                    if session.serversExpanded {
                        ForEach(session.servers, id: \.string) { url in
                            serverRow(url)
                        }
                    }
                }
                .padding(EdgeInsets(top: 0, leading: 14, bottom: 12, trailing: 10))
            }
        }
    }

    private var sectionGap: some View {
        Spacer(flexGrow: 0).frame(height: .pt(8))
    }

    /// Who this window is browsing as — a pill with the profile's initial,
    /// opening the list of profiles under it.
    private func profilePill(_ look: ExplorerLook) -> some View {
        let fonts = explorerFonts
        let name = session.profiles.selected.name
        // Whose desktop this is, as the design draws it: the user's initial
        // beside the profile's name.
        let initial = String(NSUserName().prefix(1)).uppercased()
        let open = session.profilePickerExpanded
        return HStack(padding: 0, alignment: .center, spacing: 10,
                      onClick: { session.profilePickerExpanded.toggle() }) {
            HStack(width: .pt(28), height: .pt(28), padding: 0, alignment: .center, spacing: 0) {
                Spacer()
                Text(initial, color: look.onAccent,
                     font: fonts?.display14)
                Spacer()
            }
            .background(look.accent)
            .cornerRadius(14)
            VStack(flexGrow: 1, padding: 0, spacing: 0) {
                Text("PROFILE", color: look.soft, font: fonts?.kicker, lineLimit: 1)
                Text(name, color: look.text, font: fonts?.bodySemi, lineLimit: 1)
            }
            .flexShrink(1)
            Icon(open ? ExplorerGlyphs.chevronDown : ExplorerGlyphs.chevronRight, size: 14,
                 color: look.soft, strokeWidth: 2.75)
        }
        .padding(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 10))
        .background(look.card)
        .hoverBackground(look.accent100)
        .cornerRadius(22)
        .cursor(.pointer)
        .agentId("section-profile")
    }

    private func sectionHeader(
        _ title: String, expanded: Bool, toggle: @escaping () -> Void
    ) -> some View {
        let look = ExplorerLook.current
        return HStack(padding: 0, alignment: .center, spacing: 8, onClick: toggle) {
            Text(title.uppercased(), color: look.soft, font: explorerFonts?.kicker, lineLimit: 1)
                .flexShrink(1)
            Spacer()
            Icon(expanded ? ExplorerGlyphs.chevronDown : ExplorerGlyphs.chevronRight, size: 12,
                 color: look.soft, strokeWidth: 3)
        }
        .padding(EdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10))
        .cornerRadius(14)
        .cursor(.pointer)
        .agentId("section-\(title.lowercased())")
    }

    private func note(_ text: String) -> some View {
        Text(text, color: ExplorerLook.current.soft, font: explorerFonts?.caption, lineLimit: 2)
            .padding(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 10))
    }

    /// One row: a glyph, the title — and under it a line of detail when there
    /// is one — then whatever `trailing` puts at the end (eject, forget).
    private func row<Trailing: View>(
        title: String, sub: String? = nil, glyph: String, on: Bool, aimedAt: Bool = false,
        id: String, action: @escaping () -> Void,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        let look = ExplorerLook.current
        let fonts = explorerFonts
        let fill = aimedAt ? look.accent300 : (on ? look.accent200 : Color.clear)
        return HStack(padding: 0, alignment: .center, spacing: 11, onClick: action) {
            Icon(glyph, size: 17, color: on ? look.accent700 : look.soft, strokeWidth: 2.25)
            VStack(padding: 0, spacing: 0) {
                Text(title, color: on ? look.accent800 : look.text,
                     font: on ? fonts?.bodySemi : fonts?.body, lineLimit: 1)
                if let sub {
                    Text(sub, color: look.soft, font: fonts?.caption, lineLimit: 1)
                }
            }
            .flexShrink(1)
            Spacer()
            trailing()
        }
        .padding(EdgeInsets(top: 7, leading: 12, bottom: 7, trailing: 6))
        .frame(minHeight: 34)
        .background(fill)
        .hoverBackground(on ? look.accent200 : look.press)
        .cornerRadius(17)
        .cursor(.pointer)
        .agentId(id)
    }

    private func row(
        title: String, sub: String? = nil, glyph: String, on: Bool, aimedAt: Bool = false,
        id: String, action: @escaping () -> Void
    ) -> some View {
        row(title: title, sub: sub, glyph: glyph, on: on, aimedAt: aimedAt, id: id,
            action: action) { EmptyView() }
    }

    /// The small round button at a row's end.
    private func endButton(
        _ glyph: String, size: Float, tip: String, id: String, action: @escaping () -> Void
    ) -> some View {
        let look = ExplorerLook.current
        return HStack(width: .pt(26), height: .pt(26), padding: 0, alignment: .center,
                      spacing: 0, onClick: action) {
            Icon([.path(glyph)], size: size, color: look.soft, strokeWidth: 2.75, box: 26)
        }
        .hoverBackground(look.accent200)
        .cornerRadius(13)
        .tooltip(tip)
        .agentId(id)
    }

    private func deviceRow(_ volume: DiskVolume) -> some View {
        // The device holding the folder, lit only when no place or favourite
        // names the folder itself: Home is not also "Linux".
        let path = session.listing.path
        let named = session.places.contains { FolderHistory.normalize($0.path) == path }
            || session.favorites.contains(path)
        let selected = !named
            && DiskVolume.selected(in: session.devices, path: path) == volume.id
        let busy = session.deviceBusy == volume.id
        let detail = busy ? "Working…" : (volume.mountPoint ?? "Click to mount")
        return row(title: volume.title, sub: detail, glyph: ExplorerGlyphs.drive, on: selected,
                   id: "device-\(volume.device)", action: { session.openDevice(volume) }) {
            if volume.canUnmount && !busy {
                endButton(ExplorerGlyphs.eject, size: 13, tip: "Unmount \(volume.title)",
                          id: "unmount-\(volume.device)") { session.unmountDevice(volume) }
            }
        }
        .tooltip("\(volume.device) · \(volume.model) · \(volume.filesystem)\n\(detail)")
        .onDrop { urls in
            if let path = volume.mountPoint {
                session.dropOnPlace(Place(title: volume.title, path: path), urls)
            } else {
                session.notice = "Mount \(volume.title) before dropping files onto it"
                ViewInvalidation.markDirty()
            }
        }
    }

    private func favoriteRow(_ path: String) -> some View {
        row(title: ExplorerSession.favoriteTitle(path),
            glyph: RemoteURL.isRemote(path) ? ExplorerGlyphs.server : ExplorerGlyphs.star,
            on: session.listing.path == path, id: "favorite-\(path)",
            action: { session.go(path) }) {
            endButton(ExplorerGlyphs.cross, size: 12, tip: "Remove from Favorites",
                      id: "unfavorite-\(path)") { session.removeFavorite(path) }
        }
        .tooltip(path)
    }

    /// A server lately used: a click goes back, a drop uploads to its login
    /// folder, and the cross forgets it — its password too.
    private func serverRow(_ url: RemoteURL) -> some View {
        row(title: url.server.title, glyph: ExplorerGlyphs.server,
            on: RemoteURL(session.listing.path)?.server == url.server,
            aimedAt: session.dropHover == .place(url.string),
            id: "server-\(url.server.host)", action: { session.go(url.string) }) {
            endButton(ExplorerGlyphs.cross, size: 12, tip: "Forget Server",
                      id: "forget-\(url.server.host)") { session.forgetServer(url) }
        }
        .tooltip(url.string)
        .onDrop(targeted: { session.setDropHover(.place(url.string), $0) }) { urls in
            session.upload(urls.map(\.path), into: url)
        }
    }

    private func placeRow(_ place: Place) -> some View {
        row(title: place.title, glyph: ExplorerGlyphs.place(place),
            on: FolderHistory.normalize(place.path) == session.listing.path,
            aimedAt: session.dropHover == .place(place.path),
            id: "place-\(place.title.lowercased())", action: { session.go(place.path) })
        .onDrop(targeted: { session.setDropHover(.place(place.path), $0) }) { urls in
            session.dropOnPlace(place, urls)
        }
    }
}

// MARK: - List

private struct FilePane: View {
    @Bindable var session: ExplorerSession
    let paneID: Int
    let tab: ExplorerTab

    private var active: Bool { session.layout.activePaneID == paneID }

    /// A folder with nothing to show: a sage disc, a line in the display
    /// face and a sentence under it.
    private func emptyState(title: String, detail: String) -> some View {
        let look = ExplorerLook.current
        let fonts = explorerFonts
        return VStack(flexGrow: 1, padding: 0, alignment: .center, spacing: 10) {
            Spacer(flexGrow: 0).frame(height: .pt(56))
            HStack(width: .pt(72), height: .pt(72), padding: 0, alignment: .center, spacing: 0) {
                Icon([.path(ExplorerGlyphs.folder)], size: 32, color: look.sage600,
                     strokeWidth: 2, box: 72)
            }
            .background(look.sage100)
            .cornerRadius(36)
            Text(title, color: look.text, font: fonts?.display18, lineLimit: 1)
            Text(detail, color: look.soft, font: fonts?.body, align: .top)
                .padding(EdgeInsets(top: 0, leading: 24, bottom: 0, trailing: 24))
            Spacer()
        }
    }

    var body: some View {
        let listing = tab.listing
        let selectedIndex = tab.selected.flatMap { selected in
            listing.entries.firstIndex { $0.path == selected }
        }
        let paneID = self.paneID
        return VStack(flexGrow: 1, padding: 0, spacing: 0) {
            if TrashPath.isTrash(listing.path) {
                trashBar(empty: listing.entries.isEmpty)
            }
            // Columns to sort by and resize belong to rows; the icon view
            // sorts from the View menu.
            if tab.viewMode == .list, !listing.entries.isEmpty, listing.error == nil { header }
            if let draft = session.newFolderDraft, draft.tabID == tab.id,
               draft.directory == listing.path
            {
                NewFolderRow(session: session)
            }
            if let error = listing.error {
                emptyState(title: "Can’t open this folder", detail: error)
                    .agentId("listing-error")
            } else if listing.entries.isEmpty {
                emptyState(
                    title: TrashPath.isTrash(listing.path) ? "The Trash is empty" : "Nothing here yet",
                    detail: TrashPath.isTrash(listing.path)
                        ? "Things you delete wait here until it is emptied."
                        : "This folder is empty. Drop files here to copy them in."
                )
                .agentId("listing-empty")
            } else if tab.viewMode == .icons {
                ScrollView(.vertical, position: session.scrollPosition(for: tab.id)) {
                    LazyVGrid(
                        listing.entries,
                        cellWidth: TileMetrics.width,
                        cellHeight: TileMetrics.height,
                        spacing: TileMetrics.spacing,
                        scrollTarget: selectedIndex
                    ) { entry in
                        FileRow(
                            session: session, paneID: paneID, tabID: tab.id, entry: entry,
                            selected: tab.selection.contains(entry.path), tile: true,
                            activePane: active, columns: columnLayout
                        )
                    }
                    .padding(EdgeInsets(top: 4, leading: 10, bottom: 10, trailing: 10))
                }
                .flexGrow(1)
                .onFrame { frame in session.noteGridWidth(paneID, frame.w - 20) }
            } else {
                ScrollView(.vertical, position: session.scrollPosition(for: tab.id)) {
                    LazyVStack(
                        listing.entries,
                        rowHeight: FileListMetrics.rowHeight,
                        spacing: 0,
                        scrollTarget: selectedIndex
                    ) { entry in
                        FileRow(
                            session: session, paneID: paneID, tabID: tab.id, entry: entry,
                            selected: tab.selection.contains(entry.path),
                            activePane: active, columns: columnLayout
                        )
                    }
                    .padding(EdgeInsets(top: 0, leading: 0, bottom: 10, trailing: 0))
                }
                .flexGrow(1)
            }
        }
        // Anywhere in the list that is not a folder: into the folder the pane
        // is showing. A folder row is its own target, and wins.
        .onDrop(targeted: { session.setDropHover(.pane(paneID), $0) }) { urls in
            session.dropInPane(paneID, urls)
        }
        .overlayLayer {
            DropOutline(
                active: session.dropHover == .pane(paneID) || session.remoteDrag?.paneID == paneID
                    || session.rightDrag?.paneID == paneID
            )
        }
    }

    /// The row's geometry, so a column's heading and its separators sit
    /// where the rows put that column: the same side padding, and each
    /// separator the width of the gap between two cells.
    private var columnLayout: ColumnLayout {
        ColumnLayout(paneWidth: session.paneWidths[paneID] ?? 800, columns: session.columns)
    }

    private var header: some View {
        let layout = columnLayout
        let paneID = self.paneID
        return HStack(
            height: .pt(FileListMetrics.headerHeight), alignment: .center, spacing: 0
        ) {
            sortHeader(.name, trailing: false)
                .flexGrow(1)
                .flexShrink(1)
            if let size = layout.size {
                columnEdge(.nameSize)
                sortHeader(.size, trailing: true)
                    .frame(width: .pt(size))
                columnEdge(.sizeModified)
            } else {
                Spacer(flexGrow: 0).frame(width: .pt(FileListMetrics.gap))
            }
            sortHeader(.modified, trailing: true)
                .frame(width: .pt(layout.modified))
        }
        .padding(EdgeInsets(top: 0, leading: FileListMetrics.nameInset,
                            bottom: 0, trailing: FileListMetrics.trailingInset))
        .onFrame { frame in
            session.noteColumnRoom(
                paneID,
                frame.w - FileListMetrics.nameInset - FileListMetrics.trailingInset
                    - 2 * FileListMetrics.gap
            )
        }
    }

    /// A line between two headings that drags the boundary between them. The
    /// box is the whole gap, full height; the line is what shows.
    private func columnEdge(_ edge: ListColumns.Edge) -> some View {
        let theme = Theme.current
        let dragging = session.columnDrag == edge
        let line: Float = dragging ? 2 : 1
        let paneID = self.paneID
        return HStack(
            width: .pt(FileListMetrics.gap),
            height: .pct(100),
            alignment: .center,
            spacing: 0
        ) {
            // Only while dragged: the design's columns have no rules between
            // them, and the edge is found by the pointer turning into one.
            Spacer(flexGrow: 0)
                .frame(width: .pt(line), height: .pt(18))
                .background(dragging ? theme.accent : Color.clear)
        }
        .padding(.leading, (FileListMetrics.gap - line) / 2)
        .cursor(.resizeLeftRight)
        .onDragGesture(minimumDistance: 1) { value in
            session.dragColumnEdge(edge, in: paneID, value)
        }
        .agentId("column-edge-\(edge == .nameSize ? "size" : "modified")")
    }

    /// What the Trash is and the one thing to do with all of it. Restore is
    /// per item, on the right-click.
    private func trashBar(empty: Bool) -> some View {
        let look = ExplorerLook.current
        return HStack(padding: 0, alignment: .center, spacing: 8) {
            Text(
                "Right-click an item to put it back where it came from",
                color: look.soft, font: explorerFonts?.caption, lineLimit: 1
            )
            .flexShrink(1)
            Spacer()
            if !empty {
                Text("Empty Trash", color: look.accent800, font: explorerFonts?.crumbSemi,
                     hoverFill: look.accent200, onClick: { session.askToEmptyTrash() })
                    .padding(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                    .background(look.accent100)
                    .cornerRadius(13)
                    .cursor(.pointer)
                    .agentId("empty-trash")
            }
        }
        .padding(EdgeInsets(top: 0, leading: 20, bottom: 6, trailing: 16))
    }

    private func sortHeader(_ sort: FileSort, trailing: Bool) -> some View {
        let look = ExplorerLook.current
        let on = tab.sort == sort
        let mark = on ? (tab.sortDescending ? " ↓" : " ↑") : ""
        // In the Trash the date is when it was thrown away.
        let title = sort == .modified && TrashPath.isTrash(tab.listing.path)
            ? "Deleted" : sort.title
        return Text(
            title.uppercased() + mark,
            color: on ? look.text : look.soft,
            font: explorerFonts?.kicker,
            lineLimit: 1,
            align: trailing ? .trailing : .leading,
            onClick: { session.setSort(sort) }
        )
        .cursor(.pointer)
        .agentId("sort-\(sort.rawValue)")
    }
}

/// The name of a folder about to be made, typed in place at the top of the
/// list. Enter makes it; Escape, or going somewhere else, forgets it.
private struct NewFolderRow: View {
    @Bindable var session: ExplorerSession

    var body: some View {
        let look = ExplorerLook.current
        return HStack(
            height: .pt(FileListMetrics.rowHeight + 6),
            padding: 0,
            alignment: .center,
            spacing: 11
        ) {
            Icon([.fill(ExplorerGlyphs.folder)], size: FileListMetrics.iconSize,
                 color: look.sage600)
            TextField(
                text: session.newFolderName,
                autoFocus: true,
                selectionOnFocus: .all,
                onSubmit: { session.commitNewFolder() }
            )
            .flexGrow(1)
            .agentId("new-folder-name")
            Text("Enter to create · Esc to cancel", color: look.soft,
                 font: explorerFonts?.caption, lineLimit: 1)
                .flexShrink(1)
        }
        .padding(EdgeInsets(top: 0, leading: FileListMetrics.nameInset - FileListMetrics.gutter,
                            bottom: 0, trailing: FileListMetrics.trailingInset))
        .background(look.accent100)
        .cornerRadius(12)
        .padding(EdgeInsets(top: 0, leading: FileListMetrics.gutter, bottom: 4,
                            trailing: FileListMetrics.gutter))
    }
}

/// Which columns a pane has room for, the design's container queries: no
/// Size under 440 points, and the date without its time under 360.
struct ColumnLayout: Equatable {
    var size: Float?
    var modified: Float
    var dateOnly: Bool

    init(paneWidth: Float, columns: ListColumns) {
        if paneWidth <= 360 {
            size = nil
            modified = 88
            dateOnly = true
        } else if paneWidth <= 440 {
            size = nil
            modified = 132
            dateOnly = false
        } else {
            size = columns.size
            modified = columns.modified
            dateOnly = false
        }
    }

    func date(_ date: Date?) -> String {
        let full = Formatters.modified(date)
        return dateOnly ? String(full.prefix(10)) : full
    }
}

/// Shared by the header and the rows, which have to agree for a column's
/// separator to sit in the gap the rows leave before it.
enum FileListMetrics {
    static let headerHeight: Float = 30
    /// Every row is this tall, which is what lets the list be lazy and a
    /// row's place in it be worked out from its index.
    static let rowHeight: Float = 38
    /// Between the card's edge and a row's rounded fill.
    static let gutter: Float = 10
    /// From the card's edge to a row's glyph, and to the Name heading.
    static let nameInset: Float = 28
    /// From the card's edge to the end of the last column.
    static let trailingInset: Float = 20
    /// The glyph's column, and the box a thumbnail is fitted into.
    static let iconSize: Float = 19
    static let gap: Float = 8
}

/// The icon view's cell: how big a tile is, and what is inside it.
enum TileMetrics {
    static let width: Float = 112
    static let padding: Float = 8
    /// Room for the picture, two lines of name and the gaps between — from
    /// the font, which the display scale sizes. A fixed number fitted the
    /// font it was tried with, and the second line ran off the bottom of the
    /// tile at a larger one.
    static var height: Float {
        let line = FontStore.default?.lineHeight ?? 20
        // `+ 4`: room under the second line, so a name does not sit on the
        // tile's edge.
        return padding + icon + padding + 2 * line + 4 + padding
    }
    /// Space between tiles, both ways. `ExplorerSession.noteGridWidth` works
    /// out the column count from it, the same way `LazyVGrid` does.
    static let spacing: Float = 6
    /// The height a thumbnail is fitted into; the design's glyph is drawn
    /// at `glyph` inside it.
    static let icon: Float = 64
    static let glyph: Float = 46
    /// The width a thumbnail is fitted into: the tile's, less its padding. A
    /// landscape photo — most of them — would otherwise be fitted to a square
    /// and shown at two thirds of the width there is.
    static let pictureWidth: Float = width - 2 * padding

    /// The cache size to ask for: the "large" thumbnails once the box is
    /// more pixels across than a "normal" one has, which is any scale above
    /// 1.28 — content scale and the screen's output scale together, since the
    /// box is drawn over that many device pixels.
    static var thumbnailSize: ThumbnailCache.Size {
        pictureWidth * FontStore.scale.multiplier * DisplayScale.main
            > Float(ThumbnailCache.Size.normal.pixels)
            ? .large : .normal
    }
}

/// What a tile shows when there is no picture to show: the theme's icon for the
/// folder or the kind of file, or — on a machine with no icon theme — a folder
/// as a block of the accent colour and anything else as a page with its
/// extension on it.
/// Shapes rather than the list's glyphs scaled up — those come from a fallback
/// symbol face that a font loaded at another size would not carry.
private struct BigIcon: View {
    let entry: FileEntry
    let size: Float

    var body: some View {
        FileGlyph(entry: entry, size: TileMetrics.glyph, stroke: 1.5)
            .frame(width: .pt(size), height: .pt(size), alignment: .center)
    }
}

/// The design's picture for a file or folder: a filled folder — in the accent
/// for one the desktop knows by name, sage otherwise — or a page with a mark
/// for its kind.
private struct FileGlyph: View {
    let entry: FileEntry
    let size: Float
    var stroke: Float = 2

    var body: some View {
        let look = ExplorerLook.current
        if entry.isDirectory {
            Icon([.fill(ExplorerGlyphs.folder)], size: size,
                 color: ExplorerGlyphs.isSpecialFolder(entry) ? look.accent600 : look.sage600)
        } else {
            let kind = ExplorerGlyphs.kind(entry)
            Icon([.path(ExplorerGlyphs.page), .path(kind.mark)], size: size,
                 color: kind == .font ? look.accent600 : look.soft, strokeWidth: stroke,
                 centersInk: false)
        }
    }
}

private struct FileRow: View {
    @Bindable var session: ExplorerSession
    let paneID: Int
    let tabID: Int
    let entry: FileEntry
    let selected: Bool
    /// A tile in the icon view rather than a row in the list. The two differ
    /// only in what is inside: selection, clicks, the context menu, dragging
    /// out and dropping in are the same code for both.
    var tile = false
    /// Whether this row's pane is the one the keys go to: its selection is
    /// the accent, another pane's is grey.
    var activePane = true
    /// Which columns the pane has room for.
    var columns = ColumnLayout(paneWidth: 800, columns: ListColumns())

    var body: some View {
        // A folder takes a drop into itself. A file does not, and a drop on it
        // falls through to the list behind — the folder being shown.
        if entry.isDirectory {
            item.onDrop(
                targeted: { session.setDropHover(.folder(paneID: paneID, path: entry.path), $0) }
            ) { urls in
                session.dropInFolder(entry, urls)
            }
        } else {
            item
        }
    }

    @ViewBuilder private var item: some View {
        if tile {
            decorated(tileContent)
        } else {
            decorated(rowContent)
        }
    }

    private var fill: Color {
        let look = ExplorerLook.current
        let aimedAt = session.dropHover == .folder(paneID: paneID, path: entry.path)
        return aimedAt
            ? look.accent300
            : (selected ? (activePane ? look.accent200 : look.press) : Color.clear)
    }

    private var renaming: Bool {
        guard let draft = session.renameDraft else { return false }
        return draft.path == entry.path && draft.tabID == tabID
    }

    private func pointer(_ mods: Int32, _ button: Int32) {
        if button == PointerButton.right {
            session.rightPress(entry)
            return
        }
        // Middle-click opens a folder in a new tab, as in a browser;
        // Ctrl+click is selection, as in every file manager.
        if button == PointerButton.middle {
            if entry.isDirectory { session.newTab(path: entry.path) }
            return
        }
        guard button == PointerButton.left else { return }
        let p = PointerState.window
        session.click(entry, clicks: ClickCounter.register(x: p.x, y: p.y), mods: mods)
    }

    private var renameField: some View {
        TextField(
            text: session.renameName,
            autoFocus: true,
            selectionOnFocus: .leading(
                Rename.stemLength(of: entry.name, isDirectory: entry.isDirectory)
            ),
            onSubmit: { session.commitRename() }
        )
        .agentId("rename-field")
    }

    private var rowContent: some View {
        let look = ExplorerLook.current
        let fonts = explorerFonts
        let tag = entry.isDirectory ? nil : ExplorerGlyphs.kind(entry).tag
        return HStack(
            height: .pt(FileListMetrics.rowHeight), padding: 0, alignment: .center, spacing: 0
        ) {
            HStack(
                height: .pt(FileListMetrics.rowHeight),
                padding: 0,
                alignment: .center,
                spacing: FileListMetrics.gap,
                onPointer: pointer
            ) {
                HStack(padding: 0, alignment: .center, spacing: 11) {
                    if let thumbnail = session.thumbnail(for: entry) {
                        Image(
                            path: thumbnail.path,
                            width: .pt(FileListMetrics.iconSize),
                            height: .pt(FileListMetrics.iconSize),
                            contentMode: .fit
                        )
                    } else {
                        FileGlyph(entry: entry, size: FileListMetrics.iconSize)
                    }
                    if renaming {
                        renameField.flexGrow(1)
                    } else {
                        Text(entry.name, color: entry.isHidden ? look.soft : look.text,
                             font: selected ? fonts?.bodySemi : fonts?.body, lineLimit: 1)
                            .flexShrink(1)
                        if let tag {
                            Text(tag, color: look.accent800, font: fonts?.tag)
                                .padding(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
                                .background(look.accent100)
                                .cornerRadius(9)
                                .flexShrink(0)
                        }
                    }
                }
                .flexGrow(1)
                .flexShrink(1)
                .clipped()
                if let size = columns.size {
                    Text(entry.sizeLabel, color: look.soft, font: fonts?.bodyTabular,
                         lineLimit: 1, align: .trailing)
                        .frame(width: .pt(size))
                }
                Text(columns.date(entry.modified), color: look.soft,
                     font: fonts?.bodyTabular, lineLimit: 1, align: .trailing)
                    .frame(width: .pt(columns.modified))
            }
            .padding(EdgeInsets(top: 0, leading: FileListMetrics.nameInset - FileListMetrics.gutter,
                                bottom: 0,
                                trailing: FileListMetrics.trailingInset - FileListMetrics.gutter))
            // No hover tint. A list scrolled under a still pointer slides row
            // after row beneath it, and a tint that follows reads as the list
            // flickering — which is why file managers do not light rows up.
            .background(fill)
            .cornerRadius(12)
            .flexGrow(1)
        }
        .padding(EdgeInsets(top: 0, leading: FileListMetrics.gutter, bottom: 0,
                            trailing: FileListMetrics.gutter))
        .frame(width: .pct(100))
    }

    /// The picture at its own proportions, standing on the name: a box the
    /// shape of the thumbnail, at the bottom of the picture area. Fitted
    /// *inside* a fixed box instead, a landscape photo floated in the middle
    /// of empty space above and below it, and the name looked pushed down.
    /// Never larger than the thumbnail's own pixels — a 48-pixel icon is not
    /// improved by being blown up to 80.
    private func picture(_ thumbnail: Thumbnail) -> some View {
        var width = TileMetrics.pictureWidth
        var height = TileMetrics.icon
        if thumbnail.width > 0, thumbnail.height > 0 {
            let scale = min(
                width / thumbnail.width, height / thumbnail.height,
                1 / FontStore.scale.multiplier
            )
            width = (thumbnail.width * scale).rounded()
            height = (thumbnail.height * scale).rounded()
        }
        return VStack(alignment: .center, spacing: 0) {
            Spacer()
            Image(
                path: thumbnail.path, width: .pt(width), height: .pt(height),
                contentMode: .fit
            )
        }
        .frame(width: .pt(TileMetrics.pictureWidth), height: .pt(TileMetrics.icon))
    }

    private var tileContent: some View {
        let look = ExplorerLook.current
        let inner = TileMetrics.pictureWidth
        return VStack(
            width: .pt(TileMetrics.width),
            height: .pt(TileMetrics.height),
            padding: TileMetrics.padding,
            alignment: .center,
            spacing: TileMetrics.padding,
            onPointer: pointer
        ) {
            if let thumbnail = session.thumbnail(for: entry, size: TileMetrics.thumbnailSize) {
                picture(thumbnail)
            } else {
                BigIcon(entry: entry, size: TileMetrics.icon)
            }
            if renaming {
                renameField.frame(width: .pt(inner))
            } else {
                // Two lines, centred under the picture: most names fit, and a
                // long one shows its start and enough of the rest to tell it
                // from its neighbours.
                Text(entry.name, color: entry.isHidden ? look.soft : look.text,
                     font: selected ? explorerFonts?.crumbSemi : explorerFonts?.crumb,
                     lineLimit: 2, align: .top)
                    .frame(width: .pt(inner))
            }
        }
        .background(fill)
        .cornerRadius(16)
    }

    /// A local row goes out as an OS drag, which any app can take. A server's
    /// row has nothing an app could open, so it is dragged inside the window,
    /// to be let go of over a local pane — a download.
    @ViewBuilder
    private func dragged<Content: View>(_ content: Content) -> some View {
        if RemoteURL.isRemote(entry.path) {
            content.onDragGesture { value in session.dragRemote(entry, value) }
        } else if DragBridge.startFileDrag != nil {
            // Either button: the compositor carries the drag on whichever
            // started it, to this window or any other, and a right-button
            // drop asks whether to copy or move (`DropRouter.button`).
            content.onFileDrag(
                buttons: [PointerButton.left, PointerButton.right],
                paths: { session.dragPaths(for: entry) }
            ) {
                // Built after `paths`, so it knows how many went with this row.
                FileDragChip(entry: entry, others: max(0, session.ownDrag.count - 1))
            }
        } else {
            // Windowed: no compositor to carry a drag, so the right button
            // carries the rows inside the window, to another pane.
            content.onDragGesture(button: PointerButton.right) { value in
                session.dragRight(entry, value)
            }
        }
    }

    /// What rows and tiles have in common, around whichever they are.
    private func decorated<Content: View>(_ content: Content) -> some View {
        let menuX = session.menuX
        let menuY = session.menuY
        let paneID = self.paneID
        return dragged(content.agentId("file-\(entry.name)"))
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
                    var style = PaneChrome.menuStyle.overlayStyle
                    style.minWidth = 220
                    return style
                }()
            ) {
                if session.contextEntry?.path == entry.path, session.contextPaneID == paneID {
                    FileContextMenu(session: session, entry: entry).inExplorerFont()
                }
            }
    }
}

/// What follows the pointer while a row is dragged out: the row's glyph and
/// name, on a plate. Ordinary views — the compositor draws them once and moves
/// the result, so nothing here has to know it ends up as a texture.
private struct FileDragChip: View {
    let entry: FileEntry
    /// How many more rows the drag carries besides this one.
    var others: Int = 0

    var body: some View {
        let theme = Theme.current
        return HStack(padding: 8, alignment: .center, spacing: 8) {
            Text(
                entry.isDirectory ? "▣" : "▤",
                color: entry.isDirectory ? theme.accent : theme.textDim
            )
            Text(entry.name, color: theme.textPrimary, lineLimit: 1)
            if others > 0 {
                Text("+\(others)", color: theme.textPrimary)
                    .padding(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
                    .background(theme.accent)
                    .cornerRadius(8)
            }
        }
        .background(theme.panel)
        .cornerRadius(6)
    }
}

/// What a right-drag let go of over a pane does: copy or move into the
/// folder it shows. Move is offered only where it means something — not into
/// the folder the rows are already in, not onto a server.
private struct DropChoiceMenu: View {
    @Bindable var session: ExplorerSession
    let menu: ExplorerSession.DropMenu

    var body: some View {
        let count = menu.paths.count
        let what = count > 1 ? " \(count) Items" : ""
        var entries: [MenuEntry] = []
        if menu.toTrash {
            entries.append(.item(MenuItemModel(
                id: MenuID("drop.move"), title: "Move\(what) to Trash"
            )))
        } else {
            entries.append(.item(MenuItemModel(
                id: MenuID("drop.copy"),
                title: menu.toServer ? "Upload\(what) Here" : "Copy\(what) Here"
            )))
            entries.append(.item(MenuItemModel(
                id: MenuID("drop.move"), title: "Move\(what) Here",
                isEnabled: !menu.toServer && !menu.inPlace
            )))
        }
        entries.append(.separator)
        entries.append(.item(MenuItemModel(id: MenuID("drop.cancel"), title: "Cancel")))
        return MenuDropdownPanel(
            entries: MenuGlyphMap.apply(entries, upload: menu.toServer),
            onActivate: { id in
                switch id.raw {
                case "drop.copy": session.resolveDropMenu(.copy)
                case "drop.move": session.resolveDropMenu(.move)
                default: session.resolveDropMenu(nil)
                }
            },
            style: PaneChrome.menuStyle
        )
        .agentId("drop-menu")
    }
}

/// Right-click menu, opened on release. Open / Open With / Set Default,
/// Copy, Cut and Paste, Rename, Move to Trash and Delete Permanently. In the
/// Trash it is Restore and Delete Permanently instead.
private struct FileContextMenu: View {
    @Bindable var session: ExplorerSession
    let entry: FileEntry

    var body: some View {
        let handlers = session.handlers(for: entry)
        let defaultId = session.defaultHandlerId(for: entry)
        return MenuDropdownPanel(
            entries: MenuGlyphMap.apply(entries(handlers: handlers, defaultId: defaultId)),
            onActivate: { id in session.performContext(id.raw, entry: entry) },
            style: PaneChrome.menuStyle
        )
    }

    private func entries(
        handlers: [DesktopEntry], defaultId: String?
    ) -> [MenuEntry] {
        if session.inTrash { return trashEntries }
        if session.isOnServer { return serverEntries(handlers: handlers, defaultId: defaultId) }
        let many = session.targets(for: entry).count
        let what = many > 1 ? " \(many) Items" : ""
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
        if session.targets(for: entry).contains(where: ArchiveUnpacker.looksLikeArchive) {
            items.append(.item(MenuItemModel(
                id: MenuID("ctx.extract-here"), title: "Extract Here"
            )))
        }
        items.append(.item(MenuItemModel(
            id: MenuID("ctx.compress"), title: "Compress\(what)\u{2026}"
        )))
        items.append(.separator)
        items.append(.item(MenuItemModel(id: MenuID("ctx.copy"), title: "Copy")))
        items.append(.item(MenuItemModel(id: MenuID("ctx.cut"), title: "Cut")))
        items.append(.item(MenuItemModel(
            id: MenuID("ctx.paste"),
            title: entry.isDirectory ? "Paste Into Folder" : "Paste",
            isEnabled: session.canPaste
        )))
        items.append(.separator)
        items.append(.item(MenuItemModel(
            id: MenuID("ctx.rename"), title: many > 1 ? "Rename\(what)\u{2026}" : "Rename"
        )))
        items.append(.item(MenuItemModel(id: MenuID("ctx.trash"), title: "Move\(what) to Trash")))
        items.append(.item(MenuItemModel(
            id: MenuID("ctx.delete"), title: "Delete\(what) Permanently"
        )))
        items.append(.separator)
        items.append(.item(MenuItemModel(
            id: MenuID("ctx.copy-path"), title: "Copy Path"
        )))
        if entry.isDirectory {
            items.append(.item(MenuItemModel(id: MenuID("ctx.favorite"), title: "Add to Favorites")))
            items.append(.item(MenuItemModel(id: MenuID("ctx.terminal"), title: "Open Terminal Here")))
        }
        return items
    }

    /// A server's file: open it (fetched first), take a copy, rename or
    /// delete it there, or name it. No Trash on a server, so Delete is for
    /// good, and the bar it asks in says so.
    private func serverEntries(handlers: [DesktopEntry], defaultId: String?) -> [MenuEntry] {
        let many = session.targets(for: entry).count
        let what = many > 1 ? " \(many) Items" : ""
        var items: [MenuEntry] = [
            .item(MenuItemModel(id: MenuID("ctx.open"), title: "Open")),
            .item(MenuItemModel(
                id: MenuID("ctx.open-tab"), title: "Open in New Tab", isEnabled: entry.isDirectory
            )),
            .submenu(MenuNode(
                id: MenuID("ctx.open-with"), title: "Open With",
                items: appItems(handlers, prefix: "ctx.open-with.", defaultId: defaultId)
            )),
            .separator,
            .item(MenuItemModel(id: MenuID("ctx.download"), title: "Download\(what) to Downloads")),
            .separator,
            .item(MenuItemModel(id: MenuID("ctx.rename"), title: "Rename", isEnabled: many == 1)),
            .item(MenuItemModel(id: MenuID("ctx.delete"), title: "Delete\(what) Permanently")),
            .separator,
            .item(MenuItemModel(id: MenuID("ctx.copy-path"), title: "Copy Address")),
        ]
        if entry.isDirectory {
            items.append(.item(MenuItemModel(id: MenuID("ctx.favorite"), title: "Add to Favorites")))
        }
        return items
    }

    /// Something in the Trash is there to be put back or got rid of.
    private var trashEntries: [MenuEntry] {
        let many = session.targets(for: entry).count
        let what = many > 1 ? " \(many) Items" : ""
        return [
            .item(MenuItemModel(id: MenuID("ctx.restore"), title: "Restore\(what)")),
            .item(MenuItemModel(id: MenuID("ctx.open"), title: "Open")),
            .separator,
            .item(MenuItemModel(
                id: MenuID("ctx.delete"), title: "Delete\(what) Permanently"
            )),
            .separator,
            .item(MenuItemModel(id: MenuID("ctx.copy-path"), title: "Copy Path")),
        ]
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
        let look = ExplorerLook.current
        let fonts = explorerFonts
        let busy = session.archiveWorkRunning || session.transferRunning
        let hidden = session.tabSet.current.showHidden
        let dual = session.layout.panes.count > 1
        return HStack(padding: 0, alignment: .center, spacing: 12) {
            HStack(padding: 0, alignment: .center, spacing: 6) {
                Icon([.path(ExplorerGlyphs.folder)], size: 14, color: look.soft,
                     strokeWidth: 2.75)
                if let notice = session.notice {
                    Text(notice, color: look.text, font: fonts?.status, lineLimit: 1)
                        .flexShrink(1)
                } else {
                    Text(Self.folder(session.listing.path), color: look.soft,
                         font: fonts?.status, lineLimit: 1)
                        .flexShrink(1)
                    if let entry = session.selectedEntry {
                        Text(entry.name, color: look.text, font: fonts?.statusSemi, lineLimit: 1)
                            .flexShrink(1)
                    }
                }
                if busy {
                    Text("Cancel", color: look.accent800, font: fonts?.statusSemi,
                         hoverFill: look.accent200, onClick: {
                             if session.transferRunning {
                                 session.cancelTransfer()
                             } else {
                                 session.cancelArchiveWork()
                             }
                         })
                        .padding(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                        .cornerRadius(10)
                        .agentId("archive-cancel")
                }
            }
            .flexGrow(1)
            .flexShrink(1)
            .clipped()
            .agentId("status")
            Text(session.deviceLabel, color: look.sage800, font: fonts?.tag, lineLimit: 1)
                .padding(EdgeInsets(top: 3, leading: 10, bottom: 3, trailing: 10))
                .background(look.sage100)
                .cornerRadius(12)
                .flexShrink(0)
            pill(hidden ? "Hidden shown" : "Hidden off", glyph: ExplorerGlyphs.eye, on: hidden,
                 id: "toggle-hidden") { session.toggleHidden() }
            pill(dual ? "Dual pane" : "Single pane", glyph: ExplorerGlyphs.columns, on: dual,
                 id: "toggle-dual") { session.toggleDualPane() }
        }
        .padding(EdgeInsets(top: 8, leading: 22, bottom: 8, trailing: 14))
    }

    /// "~/Downloads/" for a folder under home, the path itself elsewhere —
    /// with the slash when a selected name follows it.
    static func folder(_ path: String, home: String = NSHomeDirectory()) -> String {
        var shown = path == home ? "~" : path.hasPrefix(home + "/")
            ? "~" + path.dropFirst(home.count) : path
        if !shown.hasSuffix("/") { shown += "/" }
        return shown
    }

    /// A switch in the status bar: lit sage while on.
    private func pill(
        _ title: String, glyph: String, on: Bool, id: String, action: @escaping () -> Void
    ) -> some View {
        let look = ExplorerLook.current
        let ink = on ? look.sage800 : look.soft
        return HStack(padding: 0, alignment: .center, spacing: 6, onClick: action) {
            Icon([.path(glyph)], size: 13, color: ink, strokeWidth: 2.75)
            Text(title, color: ink, font: explorerFonts?.statusSemi, lineLimit: 1)
        }
        .padding(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
        .background(on ? look.sage200 : Color.clear)
        .border(look.divider)
        .hoverBackground(on ? look.sage200 : look.press.opacity(0.6))
        .cornerRadius(14)
        .cursor(.pointer)
        .flexShrink(0)
        .agentId(id)
    }
}

extension View {
    /// Figtree inside an overlay, which does not inherit the window's font.
    @ViewBuilder
    func inExplorerFont() -> some View {
        if let fonts = explorerFonts {
            self.font(fonts.body)
        } else {
            self
        }
    }
}

/// The glyph beside each row of the explorer's menus, by the row's id.
enum MenuGlyphMap {
    static let byID: [String: String] = [
        "ctx.open": "M15 3h6v6M10 14 21 3M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6",
        "ctx.open-tab": "M3 5h18v14H3zM3 9h18M12 12v5M9.5 14.5h5",
        "ctx.open-with": ExplorerGlyphs.grid,
        "ctx.set-default": "M20 6 9 17l-5-5",
        "ctx.extract-here": "M21 8v13H3V8M1 3h22v5H1zM12 11v6M9 14l3 3 3-3",
        "ctx.compress": "M21 8v13H3V8M1 3h22v5H1zM10 12h4",
        "ctx.copy": "M8 8h12v12H8zM16 8V4H4v12h4",
        "ctx.cut": "M6 9a3 3 0 1 0 0-6 3 3 0 0 0 0 6ZM6 21a3 3 0 1 0 0-6 3 3 0 0 0 0 6ZM20 4 8.12 15.88M14.47 14.48 20 20M8.12 8.12 12 12",
        "ctx.paste": "M9 2h6v4H9zM16 4h2a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2h2",
        "ctx.rename": "M12 20h9M16.5 3.5a2.12 2.12 0 0 1 3 3L7 19l-4 1 1-4Z",
        "ctx.trash": ExplorerGlyphs.trash,
        "ctx.delete": "M3 6h18M8 6V4h8v2M6 6l1 14h10l1-14M10 11v6M14 11v6",
        "ctx.copy-path": "M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71",
        "ctx.favorite": ExplorerGlyphs.star,
        "ctx.terminal": "M4 17l6-6-6-6M12 19h8",
        "ctx.restore": "M3 12a9 9 0 1 0 3-6.7L3 8M3 3v5h5",
        "ctx.download": ExplorerGlyphs.down,
        "drop.copy": "M8 8h12v12H8zM16 8V4H4v12h4",
        "drop.move": "M5 12h14M12 5l7 7-7 7",
        "drop.cancel": ExplorerGlyphs.cross,
    ]

    /// `entries` with each row's glyph, submenus included. A drop on a server
    /// uploads, which gets the upload arrow rather than the copy pages.
    static func apply(_ entries: [MenuEntry], upload: Bool = false) -> [MenuEntry] {
        entries.map { entry in
            switch entry {
            case .item(var item):
                if upload, item.id.raw == "drop.copy" {
                    item.icon = "M12 21V9M7 14l5-5 5 5M5 3h14"
                } else if item.icon == nil {
                    item.icon = byID[item.id.raw]
                }
                return .item(item)
            case .submenu(var node):
                if node.glyph == nil { node.glyph = byID[node.id.raw] }
                return .submenu(node)
            default:
                return entry
            }
        }
    }
}
