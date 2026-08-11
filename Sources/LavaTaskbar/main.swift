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
// It also owns the **system tray** (`org.kde.StatusNotifierWatcher`): icons
// from nm-applet, Blueman, pasystray, and other StatusNotifierItems. Click
// calls Activate / ContextMenu on the item; the app draws its own menu window.
// That is phase 1 of tray support — stock applets without rewriting them.
//
// And a **native volume applet** next to the tray: PulseAudio (or PipeWire's
// Pulse shim) via libpulse, drawn entirely in LavaUI — no pasystray.
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

    /// Client editor, for local size updates that must not wait on a Resize
    /// event from the compositor (see `ensureExpanded`).
    @ObservationIgnored var editor: Editor?

    /// Which top-level menu is open, if any. Kept here rather than in the view
    /// because the panel's *hit region* depends on it — see `openBinding`.
    var openMenu: MenuID?

    /// Volume (or any other) strip popover is open. Same input-region rule as
    /// `openMenu`: the surface is tall, but without a deep hit region the
    /// popover paints into dead space and nothing in it is clickable.
    var volumeOpen = false

    func attach(editor: Editor) {
        self.editor = editor
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

    /// Pumps DBus, publishes a new model when there is one, and keeps the
    /// panel's hit region in step with whether a menu is open.
    func poll() {
        // Surface id exists only after `LavaClient.run` creates it; the first
        // poll is the earliest safe moment to expand the panel for menus.
        ensureExpanded()
        guard let menus else {
            syncInputRegion()
            return
        }
        if menus.poll() { refreshModel() }
        syncInputRegion()
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

    // ─── Opening a menu without resizing the surface ─────────────────────
    //
    // In-window menus sit inside a tall window; the dropdown just paints below
    // the strip. A panel that is only 32pt tall cannot do that — the overlay
    // would layout against a 32pt viewport, clip, then jump when the surface
    // grew. That read as a blink and a bad transition.
    //
    // So the panel is expanded *once* to `openHeight` (reservation stays the
    // strip) and only the input region changes: closed → strip only (clicks
    // fall through to windows below); open → full surface (clicks outside the
    // dropdown dismiss). Same idea as the dock's trigger strip.

    func openMenu(_ id: MenuID) {
        // AboutToShow before presentation so a deferred submenu is asked for
        // before the first frame that shows the dropdown.
        menus?.aboutToShow(id)
        openMenu = id
        // One popover at a time: a volume panel under an open menu is noise.
        volumeOpen = false
        syncInputRegion()
    }

    func closeMenu() {
        guard openMenu != nil else { return }
        openMenu = nil
        syncInputRegion()
    }

    func setVolumeOpen(_ open: Bool) {
        guard volumeOpen != open else { return }
        volumeOpen = open
        if open {
            // Drop the menubar dropdown if it was up — same one-popover rule.
            openMenu = nil
        }
        syncInputRegion()
    }

    /// Grows the panel to menu depth once, keeps the strip reservation, and
    /// updates the local layout size so the first open does not wait on a
    /// Resize stream event.
    private func ensureExpanded() {
        guard !expanded else { return }
        expanded = true
        LavaClient.setPanelThickness(Self.openHeight)
        if let editor {
            let size = editor.framebufferSize()
            let width = size.w > 1 ? size.w : 1920
            editor.setClientSize(width: width, height: Self.openHeight)
        }
        syncInputRegion()
    }

    /// Whether any strip popover needs the deep hit region.
    private var wantsCapture: Bool { openMenu != nil || volumeOpen }

    /// Hit-test region: strip when idle, full panel while a menu or volume
    /// popover is open so the dropdown is clickable and outside clicks dismiss.
    private func syncInputRegion() {
        ensureExpanded()
        let height = wantsCapture ? Self.openHeight : Self.stripHeight
        // Width is the surface length; compositor clamps. A large constant is
        // fine — the panel is always full edge width.
        let width: Float = 8192
        let region = (x: Float(0), y: Float(0), w: width, h: height)
        guard region != appliedRegion else { return }
        appliedRegion = region
        LavaClient.setInputRegion(
            x: region.x, y: region.y, width: region.w, height: region.h
        )
    }

    @ObservationIgnored private var expanded = false
    @ObservationIgnored private var appliedRegion:
        (x: Float, y: Float, w: Float, h: Float) = (0, 0, 0, 0)

    /// The strip, and how deep the panel surface is for dropdown room.
    ///
    /// A fixed number because the panel does not know how tall the screen is —
    /// it is told its own size and nothing else — and this is comfortably more
    /// than any menubar depth while staying under the smallest display anyone
    /// runs this on.
    static let stripHeight: Float = 32
    static let openHeight: Float = 600
}

nonisolated(unsafe) let session = MenuSession()
nonisolated(unsafe) var tray: StatusNotifierTray?
nonisolated(unsafe) let pulse = PulseSession()

struct TaskbarView: View {
    let brandIcon: UIImage

    var body: some View {
        // The strip is what paints; the surface is always tall enough for a
        // dropdown (see MenuSession.ensureExpanded). Transparent below the
        // strip so the desktop shows through; input region is strip-only when
        // closed so those pixels do not steal clicks.
        VStack(flexGrow: 1, padding: 0) {
            HStack(height: .pt(MenuSession.stripHeight), padding: 10,
                   alignment: .center, spacing: 16) {
                Image(
                    brandIcon,
                    width: .pt(22), height: .pt(22), contentMode: .fit
                )

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

                // Pushes the clock (and tray) to the far end: an empty growing
                // child is the spacer, since the stack distributes leftover
                // space by flex.
                HStack(flexGrow: 1, padding: 0) {}

                trayStrip

                // Native sound control before the clock — scroll, mute, popover.
                VolumeApplet(pulse: pulse, isOpen: volumeOpenBinding)

                Text(clock.text, color: Theme.current.textPrimary)
            }
            .background(Theme.current.panel)

            // Fills the expanded surface so the strip stays top-aligned; never
            // painted (backdrop is none, no fill here).
            HStack(flexGrow: 1, padding: 0) {}
        }
    }

    /// StatusNotifier icons, left of the clock. Empty when no items or when
    /// another process owns the watcher.
    @ViewBuilder
    private var trayStrip: some View {
        let items = tray?.items ?? []
        if !items.isEmpty {
            HStack(padding: 0, alignment: .center, spacing: 6) {
                ForEach(items) { item in
                    trayIcon(item)
                }
            }
        }
    }

    @ViewBuilder
    private func trayIcon(_ item: StatusNotifierTray.TrayItem) -> some View {
        // Stack owns the hit target so left and right both work: left is
        // Activate (or ContextMenu when ItemIsMenu), right is always
        // ContextMenu — what nm-applet / Blueman expect from a tray.
        HStack(
            padding: 0,
            alignment: .center,
            onPointer: { _, button in
                if button == PointerButton.right {
                    tray?.contextMenu(item)
                } else if button == PointerButton.left {
                    tray?.activate(item)
                }
            }
        ) {
            // Fixed 22pt so a large IconPixmap does not blow the strip height.
            if let image = item.image {
                Image(
                    image,
                    width: .pt(22), height: .pt(22),
                    contentMode: .fit
                )
            } else {
                Text(item.fallback, color: Theme.current.textPrimary)
                    .padding(4)
            }
        }
        .hoverBackground(Theme.current.hover)
        .cornerRadius(3)
        .agentId("tray.\(item.key)")
    }

    /// The strip's open-menu state, with the input region attached to it.
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

    /// Volume popover visibility — same input-region plumbing as the menubar.
    private var volumeOpenBinding: Binding<Bool> {
        Binding(
            get: { session.volumeOpen },
            set: { session.setVolumeOpen($0) }
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

guard let brandIcon = ImageStore.loadAsset(
    named: "lavaui-icon.svg", bundle: .module, into: editor
) else {
    FileHandle.standardError.write(
        Data("LavaTaskbar: could not load lavaui-icon.svg\n".utf8)
    )
    exit(1)
}

// Owns the registrar from here on, so an application starting after this point
// finds somewhere to export to. Before `run`, because an app that registers
// while the panel is still coming up should not have to try twice.
session.attach(editor: editor)

// System tray watcher — same timing as the menu registrar.
tray = StatusNotifierTray(editor: editor)

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
// doing it 60 times a second to find nothing. Same loop pumps the tray
// watcher — one GLib context for both.
Thread.detachNewThread {
    while true {
        MainQueue.async {
            session.poll()
            _ = tray?.poll()
        }
        Thread.sleep(forTimeInterval: 0.05)
    }
}

LavaClient.run(editor: editor) { TaskbarView(brandIcon: brandIcon) }
