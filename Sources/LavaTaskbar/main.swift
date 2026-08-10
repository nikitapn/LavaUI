import Foundation
import LavaClient
import LavaIDL
import LavaUI
import Observation

// The desktop's top panel, as an ordinary LavaUI client.
//
//   terminal 1:  compositor/scripts/dev-run
//   terminal 2:  swift run LavaTaskbar
//   terminal 3:  swift run LavaSurface
//
// Nothing here is privileged. It publishes draw lists into a shared arena and
// reads input off a stream, exactly like the app next to it — the only
// difference is one call at startup: `openPanel` instead of `open`, which asks
// the compositor for a surface docked to an edge rather than a window placed
// wherever it likes.
//
// That is the whole reason the panel role went into the IDL rather than being
// a compositor built-in. A shell written as a client is a shell that can be
// replaced, restarted, and debugged like anything else — and one that proves
// the client API is complete enough to build a desktop with, which a built-in
// would have quietly avoided answering.
//
// It carries the desktop's **global menu**: the focused window's menubar,
// exported by that application over DBusMenu and drawn here instead of inside
// its own window. Two channels meet to make that work, and they are separate
// on purpose:
//
//   * the *menu* arrives over the session bus. This panel owns the AppMenu
//     registrar, so applications hand it an object path and it reads the menu
//     from there — the same protocol Qt and GTK applications already speak, so
//     they need nothing added to appear here.
//   * *which* menu arrives over the control plane, as `SubscribeActiveWindow`.
//     Focus belongs to the compositor and to nothing else, and a global menu
//     is the first thing on this panel that genuinely had to know it.
//
// What it does not have yet, and why:
//
//   * no window list. The compositor knows which surfaces exist; the panel now
//     knows which one is *focused*, which is half of it, but not what else is
//     open. That is what minimize is still waiting for.

/// Refreshed on a timer, because a clock is the one thing on a panel that
/// changes without anybody touching it.
@Observable
final class Clock {
    var text = ""

    func tick() {
        let now = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE d MMM  HH:mm:ss"
        text = formatter.string(from: now)
    }
}

nonisolated(unsafe) let clock = Clock()

/// The focused window and its menu, as this panel currently understands them.
///
/// Two sources, one object, because they are two halves of one fact: the
/// compositor says *which* window is active and the session bus says what its
/// menu contains, and a panel showing one without the other would either draw
/// a menu belonging to a window nobody is using or a title with no menu under
/// it.
/// Stable ids for the desktop menu the panel shows when nothing is focused.
/// Kept out of the DBus namespace (those are numeric strings) so a click can
/// never be mistaken for an imported item.
enum DesktopMenuID {
    static let root = MenuID("desktop")
    static let settings = MenuID("desktop.settings")
}

@Observable
final class MenuSession {
    /// What the focused window is called. Shown when it has no menu — a
    /// terminal, a foreign application that exports nothing — so the panel
    /// says something true rather than going blank.
    var title = ""
    /// Non-zero while a real window owns focus. Zero is the desktop itself.
    var focusedSurface: UInt32 = 0
    var model = MenuModel()

    /// The importer is not observable state: it is the machinery that produces
    /// `model`, and a view that depended on it would rebuild on every poll.
    @ObservationIgnored var menus: PanelMenu?

    /// Which top-level menu is open, if any. Kept here rather than in the view
    /// because the panel's *size* depends on it — see `openBinding`.
    var openMenu: MenuID?

    func attach(editor: Editor) {
        menus = PanelMenu(editor: editor)
        // Start on the desktop menu: nothing is focused yet.
        model = Self.desktopMenu
    }

    /// Called on the frame loop when the compositor's focus changes.
    func focus(
        surfaceId: UInt32, title: String,
        menuService: String = "", menuObjectPath: String = ""
    ) {
        self.title = title
        self.focusedSurface = surfaceId
        // An open menu belongs to the window that is no longer focused.
        closeMenu()
        menus?.setActiveWindow(
            surfaceId, menuService: menuService, menuObjectPath: menuObjectPath
        )
        refreshModel()
    }

    /// Pumps DBus, publishes a new model when there is one, and brings the
    /// panel's height into line with whether a menu is open.
    func poll() {
        guard let menus else {
            applyThickness()
            return
        }
        if menus.poll() { refreshModel() }
        applyThickness()
    }

    func activate(_ id: MenuID) {
        if id == DesktopMenuID.settings {
            closeMenu()
            launchSettings()
            return
        }
        menus?.activate(id)
        closeMenu()
    }

    /// The focused window's menu when it has one; otherwise the desktop menu
    /// (nothing focused) or just the window's name (focused but silent).
    private func refreshModel() {
        if focusedSurface == 0 {
            model = Self.desktopMenu
            return
        }
        let imported = menus?.model ?? MenuModel()
        model = imported
    }

    /// macOS-style: when no window owns the menu bar, the panel still offers a
    /// way into Settings rather than going blank.
    static let desktopMenu = MenuModel(menus: [
        MenuNode(
            id: DesktopMenuID.root,
            title: "Lava",
            items: [
                .item(MenuItemModel(
                    id: DesktopMenuID.settings,
                    title: "Settings…"
                )),
            ]
        ),
    ])

    // ─── Opening a menu, and the panel growing to hold it ────────────────
    //
    // The panel is a 32pt strip and a dropdown is not 32pt tall. Rather than a
    // second surface to position, the panel asks the compositor to make it
    // deeper while a menu is open and to put it back afterwards — the
    // reservation never changes, so the windows underneath do not move, and
    // the extra surface is also what catches the click that closes the menu.

    func openMenu(_ id: MenuID) {
        openMenu = id
        // Applications are allowed to fill a submenu only when asked. Most
        // send everything up front; the ones that do not would show an empty
        // dropdown without this.
        menus?.aboutToShow(id)
    }

    func closeMenu() {
        openMenu = nil
    }

    /// Resizes the panel to match `openMenu`, if it does not already.
    ///
    /// On the poll tick rather than in the two functions above, and that is
    /// not tidiness. Clicking an open menu's title closes and reopens it
    /// within one click — the overlay dismisses on the press, the title
    /// handler runs after — and resizing the surface *between* those two left
    /// the panel tall with no menu in it: the resize churn arrived in the
    /// middle of the overlay being re-presented and it never came back.
    /// Reconciling here collapses that pair into the state it settles on.
    private func applyThickness() {
        let want = openMenu != nil ? Self.openHeight : Self.stripHeight
        guard want != applied else { return }
        applied = want
        LavaClient.setPanelThickness(want)
    }

    @ObservationIgnored private var applied: Float = MenuSession.stripHeight

    /// The strip, and how deep the panel goes while a menu is open.
    ///
    /// A fixed number because the panel does not know how tall the screen is —
    /// it is told its own size and nothing else — and this is comfortably more
    /// than any menubar depth while staying under the smallest display anyone
    /// runs this on.
    static let stripHeight: Float = 32
    static let openHeight: Float = 600
}

nonisolated(unsafe) let session = MenuSession()

struct TaskbarView: View {
    var body: some View {
        // The strip is the panel; the space below it exists only while a menu
        // is open, and only so the dropdown has somewhere to be. Transparent,
        // so what is really underneath shows through.
        VStack(flexGrow: 1, padding: 0) {
            HStack(height: .pt(MenuSession.stripHeight), padding: 10,
                   alignment: .center, spacing: 16) {
                Text("Lava", color: Theme.current.accent)

                if session.model.menus.isEmpty {
                    // Focused window exports no menu (LavaTerm, a foreign app
                    // that never registered). Its name is the honest thing to
                    // show, and it is also how a user can tell the panel is
                    // tracking focus at all.
                    Text(
                        session.title.isEmpty ? "no window" : session.title,
                        color: Theme.current.textDim
                    )
                } else {
                    // Either the focused window's menu, or the desktop menu
                    // shown when nothing is focused — both are ordinary models.
                    MenuBarStrip(
                        model: session.model,
                        openMenuID: openBinding,
                        onActivate: { session.activate($0) }
                    )
                }

                // Pushes the clock to the far end: an empty growing child is
                // the spacer, since the stack distributes leftover space by
                // flex.
                HStack(flexGrow: 1, padding: 0) {}

                Text(clock.text, color: Theme.current.textPrimary)
            }
            .background(Theme.current.panel)

            // Only while something is open: an always-present growing box
            // would make the strip's own background 600pt tall.
            if session.openMenu != nil {
                HStack(flexGrow: 1, padding: 0) {}
            }
        }
    }

    /// The strip's open-menu state, with the panel's height attached to it.
    ///
    /// A plain `@State` would leave the panel 32pt tall and the dropdown
    /// clipped to nothing, which is exactly what it looked like before the
    /// compositor could be asked for more room.
    private var openBinding: Binding<MenuID?> {
        Binding(
            get: { session.openMenu },
            set: { id in
                if let id {
                    session.openMenu(id)
                } else {
                    session.closeMenu()
                }
            }
        )
    }
}

// ─── Desktop actions ─────────────────────────────────────────────────────────

/// Starts LavaSettings the way the compositor starts the panel: look beside
/// this binary first (tree build / installed layout), then fall through to PATH.
func launchSettings() {
    let candidates: [String] = {
        var paths: [String] = []
        let args = CommandLine.arguments
        if let selfPath = args.first {
            let dir = URL(fileURLWithPath: selfPath).deletingLastPathComponent()
            paths.append(dir.appendingPathComponent("LavaSettings").path)
            // compositor/scripts/dev-run often puts clients in .build/debug
            // while the panel may also live there — same dir is enough.
            paths.append(dir
                .appendingPathComponent("../debug/LavaSettings").path)
            paths.append(dir
                .appendingPathComponent("../release/LavaSettings").path)
        }
        paths.append("LavaSettings")
        return paths
    }()

    for path in candidates {
        let process = Process()
        if path.contains("/") {
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.isExecutableFile(atPath: url.path) else {
                continue
            }
            process.executableURL = url
        } else {
            // Let the shell resolve PATH for a bare name.
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [path]
        }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            return
        } catch {
            continue
        }
    }
    FileHandle.standardError.write(
        Data("LavaTaskbar: could not launch LavaSettings\n".utf8)
    )
}

// ─── Bring-up ───────────────────────────────────────────────────────────────

// Nothing at all, and the strip paints its own background instead.
//
// It used to be an opaque fill, which is right for a panel that is only ever
// its strip. This one grows to hold an open menu, and a filled surface would
// mean opening a menu greyed out the whole screen — so the fill moved onto the
// strip's own `HStack`, where it covers what the panel actually occupies.
WindowBackdrop.current = .none

guard let editor = LavaClient.openPanel(
    title: "Lava Panel", edge: .top,
    thickness: MenuSession.stripHeight, reserve: true
) else { exit(1) }

// Owns the registrar from here on, so an application starting after this point
// finds somewhere to export to. Before `run`, because an app that registers
// while the panel is still coming up should not have to try twice.
session.attach(editor: editor)

// Focus, from the compositor. Delivered on the frame loop, so touching
// observable state from it is the same as touching it from a click handler.
LavaClient.onActiveWindow { surfaceId, title, menuService, menuObjectPath in
    session.focus(
        surfaceId: surfaceId, title: title,
        menuService: menuService, menuObjectPath: menuObjectPath
    )
}

Thread.detachNewThread {
    while true {
        MainQueue.async { clock.tick() }
        Thread.sleep(forTimeInterval: 1.0)
    }
}

// DBus has no frame clock of its own, and the traffic goes both ways: this is
// what answers an application's `GetLayout` as much as what collects it. 20 Hz
// because a menu appearing 50ms after the application published it is
// imperceptible, and because a panel that iterated GLib per frame would be
// doing it 60 times a second to find nothing.
Thread.detachNewThread {
    while true {
        MainQueue.async { session.poll() }
        Thread.sleep(forTimeInterval: 0.05)
    }
}

LavaClient.run(editor: editor) { TaskbarView() }
