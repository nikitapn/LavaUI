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

    /// A menu never narrower than this, however short its items: a column of
    /// one-word verbs is unreadable at its natural width, because the eye
    /// reads the shape of a menu before the words. Applied by the plate, so
    /// the measurement sees it like everything else.
    static let minWidth: Float = 180

    /// What the measurement looks for. The plate hugs its rows, so its frame
    /// after a layout pass is exactly the surface the compositor should place.
    static let plateId = "context-menu.plate"
}

@Observable
final class MenuModel {
    private(set) var title = ""
    private(set) var rows: [MenuRow] = []

    /// The request being answered. 0 when nothing is open — and the guard on
    /// every reply, so a click arriving after a dismissal answers nothing.
    @ObservationIgnored private(set) var serial: UInt32 = 0
    @ObservationIgnored var editor: Editor?
    @ObservationIgnored private var reply: (@Sendable (UInt32, UInt32) -> Void)?

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
        self.reply = reply
        serial = request.serial
        title = MenuModel.shortened(request.title)
        rows = MenuRow.rows(from: request.items)
        // Back to the full arena before measuring. The plate is laid out
        // inside whatever the surface currently is, and the surface is still
        // the *last* menu's size — so without this, every menu bigger than the
        // one before it is measured against that smaller rectangle and shown
        // at the size of its own clipping. It cost a window menu that opened
        // as a 251×129 stub of itself, and the give-away was that the menu
        // before it had been exactly 251×129.
        editor?.setClientSize(
            width: ContextMenu.arenaWidth, height: ContextMenu.arenaHeight
        )
        // Structure, not paint: the row set is what the tree is built from, so
        // a redraw alone would lay out the previous menu's items.
        ViewInvalidation.markNeedsBody()
        measureThenShow()
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
        guard let editor else { return }
        let asking = serial
        FrameTasks.after { [self] in
            // Superseded while that frame was drawn: a second right-click has
            // already replaced this menu, and the compositor would drop a
            // `ShowMenu` naming the old serial anyway.
            guard serial == asking,
                  let plate = LavaApp.mainLayoutHost?.agentFrame(
                      sid: ContextMenu.plateId)
            else { return }
            let width = plate.w.rounded(.up)
            let height = plate.h.rounded(.up)
            editor.setClientSize(width: width, height: height)
            // The plate is pinned to the top-left of a surface that was much
            // larger; at its own size it fills one, and the tree has to be
            // rebuilt against that before the frame the compositor reveals.
            ViewInvalidation.markNeedsBody()
            FrameTasks.after { [self] in
                guard serial == asking else { return }
                LavaClient.showMenu(serial: asking, width: width, height: height)
            }
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
        guard serial != 0 else { return }
        serial = 0
        title = ""
        rows = []
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
        // Pinned to the top-left of whatever surface this is, at its natural
        // size, so `agentFrame` measures the menu and not the window. Once the
        // surface has been resized to it, the two are the same rectangle.
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
        let rows = model.rows
        // Nothing open: no view, not an empty *plate*. The surface is hidden
        // either way, but a client that painted a panel-coloured rectangle
        // every frame would be one whose bugs are invisible until the
        // compositor's are.
        if rows.isEmpty {
            EmptyView()
        } else {
            let style = MenuBarStyle.panel()
            let checks = MenuRow.hasChecks(rows)
            VStack(padding: style.dropdownPadding, spacing: style.itemSpacing) {
                if !model.title.isEmpty {
                    heading(style)
                    separator(style)
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { entry in
                    row(entry.element, index: entry.offset,
                        checks: checks, style: style)
                }
            }
            .frame(minWidth: ContextMenu.minWidth)
            .background(style.dropdownBackground)
            .cornerRadius(style.dropdownCornerRadius)
            .agentId(ContextMenu.plateId)
        }
    }

    /// The window the menu is about. Not clickable, and dim: it is a label
    /// saying what these items will act on, not one of them.
    @ViewBuilder
    private func heading(_ style: MenuBarStyle) -> some View {
        Text(model.title, color: Environment.current.theme.textSecondary)
            .padding(style.itemPadding)
    }

    @ViewBuilder
    private func separator(_ style: MenuBarStyle) -> some View {
        Divider()
            .padding(EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6))
    }

    @ViewBuilder
    private func row(
        _ row: MenuRow, index: Int, checks: Bool, style: MenuBarStyle
    ) -> some View {
        let theme = Environment.current.theme
        switch row {
        case .separator:
            separator(style)
        case let .item(item):
            let colour = item.enabled ? theme.textPrimary : theme.textDim
            // The tick column is a fixed width for every row of a menu that
            // has one, so ticking a box moves nothing: the alternative is a
            // prefix string, which changes width with the glyph and shuffles
            // every title sideways as the state changes.
            let content = HStack(
                padding: 0, alignment: .center, spacing: 0,
                onClick: item.enabled ? { model.activate(item.id) } : nil
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
                content.hoverBackground(style.itemHover)
            } else {
                content
            }
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

// Before `run`, which is where the surface is created: the subscription is
// held until there is an id to make it with, the same way a panel's
// `onPanelArea` is.
LavaClient.onMenuRequest { request, reply in
    model.open(request, reply: reply)
}

LavaClient.run(editor: editor, onRawKey: handleKey) { ContextMenuView() }
