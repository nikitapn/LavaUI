import Foundation
import LavaClient
import LavaIDL
import LavaMenu
import LavaUI
import Observation

// The desktop's context menu.
//
//   right-click the desktop, or a window's title bar
//     →  compositor builds the menu        (main.cpp, `openContextMenu`)
//     →  MenuRequest over the NPRPC bidi stream
//     →  this process lays it out and measures what it laid out
//     →  ShowMenu: "it is W×H"  →  the compositor places it at the pointer
//     →  the user clicks a row  →  MenuReply  →  the compositor acts
//
// **Nothing here knows what an item does.** The ids are the compositor's and
// travel back untouched, which is what lets this process be a renderer with no
// privileges: it cannot raise a window, close one, or pin one above the
// others, and it never learns which row would have.
//
// Resident, and started like the panel and the dock (`[shell] menu` in
// `lava.conf`). It is idle between menus — the compositor keeps its surface
// hidden, so there is nothing on screen and nothing to draw — and the cost of
// staying is one process holding a font and an arena, against the ~200 ms a
// cold LavaUI client takes to reach its first frame. A menu that appeared a
// fifth of a second after the click would be a menu nobody uses twice.

enum ContextMenu {
    static let appId = "LavaContextMenu"

    /// The arena, not a menu. Generous on purpose: it is host memory, it is
    /// allocated once, and it is also the canvas every menu is *measured* in —
    /// a menu that did not fit would be measured clipped and then shown at the
    /// size of its own clipping.
    static let arenaWidth: Float = 480
    static let arenaHeight: Float = 900

    /// How tall a plate is laid out before anyone decides it scrolls.
    ///
    /// The arena above is the surface the compositor creates. Measurement
    /// needs a viewport taller than any menu, or a list that does not fit is
    /// reported as the viewport and then shown clipped, with no scroll,
    /// because nothing ever learned it had wanted to be taller. 4096 is past
    /// a 4K work area; a menu taller than that scrolls anyway.
    static let measureHeight: Float = 4096

    /// A menu never narrower than this, however short its items: a column of
    /// one-word verbs is unreadable at its natural width, because the eye
    /// reads the shape of a menu before the words. Applied by the plate, so
    /// the measurement sees it like everything else.
    static let minWidth: Float = 180

    /// What the measurement looks for. The plate hugs its rows, so its frame
    /// after a layout pass is exactly the surface the compositor should place.
    static let plateId = "context-menu.plate"

    /// The desktop behind every plate, frosted — the root and each fly-out.
    ///
    /// The same radius the panel's own popups ask for, so a menu and the
    /// volume card are the same glass. Asked once per surface: the plate *is*
    /// the surface, so the compositor's whole-surface frost is exactly its
    /// outline, cut to the window corner the plate is drawn with.
    static let backdropBlur: Float = 12
}

/// One fly-out this menu has open. `depth` 0 hangs off the root plate.
private struct OpenBranch {
    var id: UInt32
    var window: WindowID
    var depth: Int
}

/// The rows of one fly-out, and whether that plate is scrolling.
///
/// Its own object rather than fields on `MenuModel`: the root plate reads
/// the model, and a cap written there would rebuild the root every time a
/// branch decided it was too tall. The view that reads this is the branch.
@Observable
final class BranchPlate {
    var rows: [MenuRow]
    var cap: Float = 0
    init(rows: [MenuRow]) { self.rows = rows }
}

@Observable
final class MenuModel {
    private(set) var title = ""
    private(set) var rows: [MenuRow] = []
    /// 0 until a plate is taller than `maxHeight`, then that height. The
    /// root plate reads it; branches keep their own on `BranchPlate`.
    private(set) var cap: Float = 0

    /// The request being answered. 0 when nothing is open — and the guard on
    /// every reply, so a click arriving after a dismissal answers nothing.
    @ObservationIgnored private(set) var serial: UInt32 = 0
    /// Work-area height from the compositor. 0 means it said nothing, and
    /// the plate is shown at its natural size — the compositor still refuses
    /// to place one taller than the screen.
    @ObservationIgnored private var maxHeight: Float = 0
    @ObservationIgnored var editor: Editor?
    @ObservationIgnored private var reply: (@Sendable (UInt32, UInt32) -> Void)?
    @ObservationIgnored private var branches: [OpenBranch] = []

    /// A menu the compositor asked for. Serial 0 with no items is its close —
    /// see `MenuRequest` in the IDL.
    func open(
        _ request: MenuRequest,
        reply: @escaping @Sendable (UInt32, UInt32) -> Void
    ) {
        FileHandle.standardError.write(Data((
            "menu: request \(request.serial) at \(request.x),\(request.y) "
            + "for window \(request.target), \(request.items.count) items\n"
        ).utf8))
        guard request.serial != 0, !request.items.isEmpty else {
            close()
            return
        }
        closeBranches(from: 0)
        self.reply = reply
        serial = request.serial
        maxHeight = Float(request.maxHeight)
        cap = 0
        title = MenuModel.shortened(request.title)
        rows = MenuRow.rows(from: request.items)
        // Taller than any menu, not the last menu's size. The plate is laid
        // out inside whatever the surface currently is — a menu measured in
        // the previous one's rectangle is shown at the size of its own
        // clipping, and one measured in a viewport shorter than itself never
        // learns it should scroll.
        editor?.setClientSize(
            width: ContextMenu.arenaWidth, height: ContextMenu.measureHeight
        )
        // Structure, not paint: the row set is what the tree is built from, so
        // a redraw alone would lay out the previous menu's items.
        ViewInvalidation.markNeedsBody()
        measureThenShow()
    }

    /// Hover or click on a submenu row. `depth` 0 is the root's own fly-out.
    ///
    /// A branch already open at this depth for the same row stays: hover
    /// fires again as the pointer moves inside the row, and rebuilding the
    /// plate each time would close it under the pointer that was opening it.
    func openBranch(_ id: UInt32, depth: Int, parentSurface: UInt32) {
        if branches.count > depth, branches[depth].id == id { return }
        guard serial != 0, parentSurface != 0,
              let nested = MenuRow.children(of: id, in: rows), !nested.isEmpty,
              let row = LavaApp.layoutHost(for: LavaApp.currentWindow)?
                .agentFrame(sid: "menu.item.\(id)")
        else { return }
        closeBranches(from: depth)
        let plate = BranchPlate(rows: nested)
        let asking = serial
        guard let window = LavaApp.openMenuPlate(
            width: ContextMenu.arenaWidth,
            height: ContextMenu.measureHeight,
            backdropBlur: ContextMenu.backdropBlur,
            makeRoot: {
                BranchMenuView(
                    plate: plate,
                    onActivate: { model.activate($0) },
                    onBranch: { child in
                        let parent = LavaClient.compositorSurface(
                            for: LavaApp.currentWindow
                        )
                        model.openBranch(
                            child, depth: depth + 1, parentSurface: parent
                        )
                    },
                    onItemHover: { model.closeBranches(from: depth + 1) }
                )
            }
        ) else { return }
        branches.append(OpenBranch(id: id, window: window, depth: depth))
        // The window is brought up at the end of this frame, so the first
        // deferred turn is too early to read a layout. The one after that
        // has laid the plate out at the measure height.
        FrameTasks.after { [self] in
            FrameTasks.after { [self] in
                guard serial == asking, branchLive(window) else { return }
                fit(
                    window: window, asking: asking,
                    read: {
                        LavaApp.layoutHost(for: window)?
                            .agentFrame(sid: ContextMenu.plateId)
                    },
                    setCap: { plate.cap = $0 }
                ) { width, height in
                    guard self.serial == asking, self.branchLive(window) else {
                        return
                    }
                    LavaClient.showSubmenu(
                        window: window, parent: parentSurface, serial: asking,
                        row: row, width: width, height: height
                    )
                }
            }
        }
    }

    /// Lays the menu out, measures what was laid out, and asks to be shown at
    /// that size.
    ///
    /// Three frames, all of them invisible — the compositor does not reveal
    /// the surface until `ShowMenu` — and the reason it is not one is that
    /// **only a layout pass knows how big a menu is**. Adding up font metrics
    /// and paddings is a second implementation of Yoga that agrees with the
    /// first until a face changes, and the first version of this file got a
    /// three-item menu 30 px too short: the rows drew inside a plate with a
    /// scrollbar down the side of it.
    ///
    /// So: lay out in the arena, read the plate's committed frame, resize to
    /// it, lay out again, show. Each pass is a handful of nodes and costs well
    /// under a millisecond; what the user waits for is the round trip, not
    /// this.
    private func measureThenShow() {
        guard editor != nil else { return }
        let asking = serial
        FrameTasks.after { [self] in
            // Superseded while that frame was drawn: a second right-click has
            // already replaced this menu, and the compositor would drop a
            // `ShowMenu` naming the old serial anyway.
            guard serial == asking else { return }
            fit(
                window: .main, asking: asking,
                read: {
                    LavaApp.mainLayoutHost?.agentFrame(sid: ContextMenu.plateId)
                },
                setCap: { self.cap = $0 }
            ) { width, height in
                guard self.serial == asking else { return }
                LavaClient.showMenu(serial: asking, width: width, height: height)
            }
        }
    }

    /// Natural size, then a scrolling plate if that is taller than the work
    /// area, then `show` with the size the compositor should place.
    ///
    /// One more frame after the size is set before `show`: the plate is
    /// pinned to the top-left of a surface that was the measure height, and
    /// the frame the compositor reveals has to be the one laid out at the
    /// plate's own size. Showing the frame before that flashes the measure
    /// canvas, which is most of a screen of empty menu.
    private func fit(
        window: WindowID, asking: UInt32,
        read: @escaping () -> LayoutFrame?,
        setCap: @escaping (Float) -> Void,
        show: @escaping (Float, Float) -> Void
    ) {
        guard let editor, let plate = read() else { return }
        let naturalW = max(plate.w, ContextMenu.minWidth)
        let limit = maxHeight
        if limit > 0, plate.h > limit {
            setCap(limit)
            editor.setClientSize(width: naturalW, height: limit, window: window)
            ViewInvalidation.markNeedsBody()
            FrameTasks.after { [self] in
                guard serial == asking, let fitted = read() else { return }
                let width = max(fitted.w, ContextMenu.minWidth).rounded(.up)
                let height = min(fitted.h, limit).rounded(.up)
                editor.setClientSize(width: width, height: height, window: window)
                ViewInvalidation.markNeedsBody()
                FrameTasks.after { [self] in
                    guard serial == asking else { return }
                    show(width, height)
                }
            }
        } else {
            let width = naturalW.rounded(.up)
            let height = plate.h.rounded(.up)
            editor.setClientSize(width: width, height: height, window: window)
            ViewInvalidation.markNeedsBody()
            FrameTasks.after { [self] in
                guard serial == asking else { return }
                show(width, height)
            }
        }
    }

    private func branchLive(_ window: WindowID) -> Bool {
        branches.contains { $0.window == window } && LavaApp.isWindowOpen(window)
    }

    func closeBranches(from depth: Int) {
        let closing = branches.filter { $0.depth >= depth }
        guard !closing.isEmpty else { return }
        branches.removeAll { $0.depth >= depth }
        for branch in closing {
            LavaApp.closeWindow(branch.window)
        }
    }

    /// The user picked a row.
    func activate(_ id: UInt32) { answer(id) }

    /// Escape, or a click the compositor did not swallow.
    func dismiss() { answer(0) }

    /// The compositor took the menu away itself — a click outside, or the
    /// window it described closing. Nothing to reply to: the session a reply
    /// would answer for is already over.
    func close() {
        closeBranches(from: 0)
        guard serial != 0 else { return }
        serial = 0
        title = ""
        rows = []
        cap = 0
        ViewInvalidation.markNeedsBody()
    }

    /// A window title with no bound is the one string on this menu that can
    /// be a sentence — a browser tab's is — and the plate is as wide as its
    /// widest row. Cut here rather than by constraining the layout: a menu
    /// whose *rows* were squeezed by a long heading would be a menu whose
    /// items wrap.
    static func shortened(_ title: String, limit: Int = 44) -> String {
        guard title.count > limit else { return title }
        return String(title.prefix(limit - 1)) + "…"
    }

    private func answer(_ chosen: UInt32) {
        guard serial != 0 else { return }
        let answered = serial
        let send = reply
        close()
        send?(answered, chosen)
    }
}

nonisolated(unsafe) let model = MenuModel()

// ─── The menu ───────────────────────────────────────────────────────────────
//
// Drawn here rather than with `MenuDropdownPanel`, which is what the panel's
// global menu uses, and the split is worth explaining because sharing was the
// first version.
//
// That view is built for a dropdown hanging off a panel: it wraps its rows in
// a `ScrollView`, because an applet menu listing thirty wireless networks has
// to reach the bottom of a 32 pt strip's surface. A scroll container takes all
// the height it is offered, which is exactly what a plate being measured must
// not do — and its shortcut column is a `KeyShortcut`, a key code and mod
// bits, where the compositor sends a string it has already formatted from
// bindings this process cannot see.
//
// What is shared is `MenuBarStyle.panel()`: the same fills, paddings, corner
// radius and hover chip. A context menu and an application menu look like the
// same object because they are drawn from the same numbers, not because they
// go through the same view.

struct ContextMenuView: View {
    var body: some View {
        // Nothing open: no view, not an empty *plate*. The surface is hidden
        // either way, but a client that painted a panel-coloured rectangle
        // every frame would be one whose bugs are invisible until the
        // compositor's are.
        if model.rows.isEmpty {
            EmptyView()
        } else {
            MenuPlate(
                title: model.title, rows: model.rows, cap: model.cap,
                onActivate: { model.activate($0) },
                onBranch: { id in
                    model.openBranch(
                        id, depth: 0,
                        parentSurface: LavaClient.compositorSurface(for: .main)
                    )
                },
                onItemHover: { model.closeBranches(from: 0) }
            )
        }
    }
}

/// One fly-out. The root plate reads `MenuModel`; this reads the branch's
/// own plate, so capping it does not rebuild the menu it came from.
struct BranchMenuView: View {
    var plate: BranchPlate
    var onActivate: (UInt32) -> Void
    var onBranch: (UInt32) -> Void
    var onItemHover: () -> Void

    var body: some View {
        MenuPlate(
            title: "", rows: plate.rows, cap: plate.cap,
            onActivate: onActivate, onBranch: onBranch, onItemHover: onItemHover
        )
    }
}

/// One plate: a heading, the rows, and a scroll when `cap` is set.
///
/// Pinned to the top-left of whatever surface this is, at its natural size,
/// so `agentFrame` measures the menu and not the window. Once the surface
/// has been resized to it, the two are the same rectangle.
struct MenuPlate: View {
    var title: String
    var rows: [MenuRow]
    var cap: Float
    var onActivate: (UInt32) -> Void
    var onBranch: (UInt32) -> Void
    var onItemHover: () -> Void

    var body: some View {
        VStack(padding: 0, spacing: 0) {
            HStack(padding: 0, spacing: 0) {
                plate
                Spacer()
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var plate: some View {
        let style = MenuBarStyle.panel()
        let checks = MenuRow.hasChecks(rows)
        VStack(padding: style.dropdownPadding, spacing: 0) {
            if cap > 0 {
                ScrollView {
                    column(checks: checks, style: style)
                }
                .frame(height: .pt(scrollHeight(style)))
            } else {
                column(checks: checks, style: style)
            }
        }
        .frame(minWidth: ContextMenu.minWidth)
        .background(style.dropdownBackground)
        .cornerRadius(style.dropdownCornerRadius)
        .agentId(ContextMenu.plateId)
    }

    /// The scroll viewport, which is the plate minus the padding around it.
    /// The cap is the whole plate — the number the compositor was told — so
    /// the rows scroll inside it rather than the plate growing to the cap
    /// and then adding its padding on the outside.
    private func scrollHeight(_ style: MenuBarStyle) -> Float {
        max(1, cap - style.dropdownPadding * 2)
    }

    @ViewBuilder
    private func column(checks: Bool, style: MenuBarStyle) -> some View {
        VStack(padding: 0, spacing: style.itemSpacing) {
            if !title.isEmpty {
                heading(style)
                separator(style)
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { entry in
                row(entry.element, checks: checks, style: style)
            }
        }
    }

    /// The window the menu is about. Not clickable, and dim: it is a label
    /// saying what these items will act on, not one of them.
    @ViewBuilder
    private func heading(_ style: MenuBarStyle) -> some View {
        Text(title, color: Environment.current.theme.textSecondary)
            .padding(style.itemPadding)
    }

    @ViewBuilder
    private func separator(_ style: MenuBarStyle) -> some View {
        Divider()
            .padding(EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6))
    }

    @ViewBuilder
    private func row(
        _ row: MenuRow, checks: Bool, style: MenuBarStyle
    ) -> some View {
        let theme = Environment.current.theme
        switch row {
        case .separator:
            separator(style)
        case let .item(item):
            itemRow(item, checks: checks, style: style, theme: theme)
        case let .submenu(id, title, enabled, _):
            branchRow(
                id: id, title: title, enabled: enabled,
                checks: checks, style: style, theme: theme
            )
        }
    }

    /// A command or a checkbox. Hovering one leaves whatever branch the
    /// pointer was in: a fly-out that stayed open beside a row the pointer
    /// has walked past is a menu for a choice the user is no longer making.
    @ViewBuilder
    private func itemRow(
        _ item: MenuRow.Row, checks: Bool, style: MenuBarStyle, theme: Theme
    ) -> some View {
        let colour = item.enabled ? theme.textPrimary : theme.textDim
        let activate = onActivate
        let leave = onItemHover
        // The tick column is a fixed width for every row of a menu that
        // has one, so ticking a box moves nothing: the alternative is a
        // prefix string, which changes width with the glyph and shuffles
        // every title sideways as the state changes.
        let content = HStack(
            padding: 0, alignment: .center, spacing: 0,
            onClick: item.enabled ? { activate(item.id) } : nil,
            onHover: { inside in if inside { leave() } }
        ) {
            if checks {
                // Wider than the glyph, so the tick does not touch the
                // first letter of the title it belongs to.
                Text(item.checked ? "✓" : " ", color: colour)
                    .frame(width: .pt(22))
            }
            Text(item.title, color: colour)
            if !item.shortcut.isEmpty {
                Spacer()
                Text(item.shortcut, color: theme.textDim)
                    .padding(EdgeInsets(
                        top: 0, leading: 24, bottom: 0, trailing: 0
                    ))
            }
        }
        .padding(style.itemPadding)
        .cornerRadius(style.itemCornerRadius)
        .agentId("menu.item.\(item.id)")

        if item.enabled {
            content.hoverBackground(style.itemHover).hoverSnap()
        } else {
            content
        }
    }

    /// A row that opens a plate of its own beside this one. The arrow is
    /// the only thing that says so — the title is the branch's name, not
    /// the name with a chevron glued on, which is what a flat protocol
    /// used to have to do.
    @ViewBuilder
    private func branchRow(
        id: UInt32, title: String, enabled: Bool,
        checks: Bool, style: MenuBarStyle, theme: Theme
    ) -> some View {
        let colour = enabled ? theme.textPrimary : theme.textDim
        let open = onBranch
        let content = HStack(
            padding: 0, alignment: .center, spacing: 0,
            onClick: enabled ? { open(id) } : nil,
            onHover: { inside in if inside, enabled { open(id) } }
        ) {
            if checks {
                Text(" ", color: colour).frame(width: .pt(22))
            }
            Text(title, color: colour)
            Spacer()
            Text("›", color: theme.textDim)
                .padding(EdgeInsets(top: 0, leading: 24, bottom: 0, trailing: 0))
        }
        .padding(style.itemPadding)
        .cornerRadius(style.itemCornerRadius)
        .agentId("menu.item.\(id)")

        if enabled {
            content.hoverBackground(style.itemHover).hoverSnap()
        } else {
            content
        }
    }
}

func handleKey(_ event: LavaUI.InputEvent) -> Bool {
    guard event.kind == .key, KeyAction.isDown(event.keyAction) else {
        return false
    }
    // Escape is the only key this owns. Everything else falls through to a
    // tree with no text field in it, which is the honest amount of keyboard
    // handling for a menu of four rows driven by a pointer.
    guard event.keyCode == KeyCode.escape else { return false }
    model.dismiss()
    return true
}

// ─── Bring-up ───────────────────────────────────────────────────────────────

guard let editor = LavaClient.openMenuSurface(
    title: "Menu",
    width: ContextMenu.arenaWidth,
    height: ContextMenu.arenaHeight
) else { exit(1) }

model.editor = editor

// The plate paints the wash. The window under it paints nothing, the same as
// the panel's: an opaque window fill would cover the frost completely, and
// every plate — a fly-out included — is a window of this process.
WindowBackdrop.current = .none

// Remembered until `run` has a surface. Set once: the root surface lives for
// the whole session and is only hidden between menus, and the compositor
// keeps the radius with it.
LavaClient.setBackdropBlur(radius: ContextMenu.backdropBlur)

// Before `run`, which is where the surface is created: the subscription is
// held until there is an id to make it with, the same way a panel's
// `onPanelArea` is.
LavaClient.onMenuRequest { request, reply in
    model.open(request, reply: reply)
}

LavaClient.run(editor: editor, onRawKey: handleKey) { ContextMenuView() }
