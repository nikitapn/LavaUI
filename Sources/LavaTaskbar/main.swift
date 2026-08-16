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
// And native applets next to the tray: volume (PulseAudio / PipeWire-Pulse)
// and a month calendar on the clock — both pure LavaUI popovers.
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

    /// Strip popovers that need the deep hit region (volume, calendar, …).
    /// Same rule as `openMenu`: without it, dropdowns paint into dead space.
    var volumeOpen = false
    var calendarOpen = false
    /// A tray applet's imported menu. Which applet is the tray's business.
    var trayMenuOpen = false

    /// How far down the surface the notification stack currently reaches, or
    /// 0 for none. Not `wantsCapture`: a toast needs its own pixels clickable
    /// and nothing else, where a dropdown wants the whole panel so a click
    /// outside it dismisses. Stealing 600pt of desktop for a toast that is
    /// 90pt tall would be a click nobody meant to give up.
    @ObservationIgnored private var toastDepth: Float = 0

    func attach(editor: Editor, brandIcon: UIImage) {
        self.editor = editor
        self.brandIcon = MenuIcon(size: 18, path: brandIcon.path)
        menus = PanelMenu(editor: editor)
        // Start on the desktop menu: nothing is focused yet.
        model = Self.desktopMenu(icon: self.brandIcon)
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

    /// The system menu (Lava icon) always stays first. A focused window's
    /// titles follow it; a focused window with nothing to export just leaves
    /// the icon and we paint its name beside the strip.
    private func refreshModel() {
        let desktop = Self.desktopMenu(icon: brandIcon)
        if focusedSurface == 0 {
            hasAppMenu = false
            model = desktop
            return
        }
        let imported = menus?.model ?? MenuModel()
        hasAppMenu = !imported.menus.isEmpty
        var menus = desktop.menus
        menus.append(contentsOf: imported.menus)
        model = MenuModel(menus: menus)
    }

    /// Whether the focused window exported titles of its own. The strip
    /// always has the system icon; this decides whether to also print the
    /// window's name.
    var hasAppMenu = false

    /// macOS-style: the brand mark is the system menu, always present.
    /// `title` stays "Lava" for anything that cannot draw a picture.
    static func desktopMenu(icon: MenuIcon?) -> MenuModel {
        MenuModel(menus: [
            MenuNode(
                id: DesktopMenuID.root,
                title: "Lava",
                icon: icon ?? MenuIcon(size: 18),
                items: [
                    .item(MenuItemModel(
                        id: DesktopMenuID.settings,
                        title: "Settings…"
                    )),
                ]
            ),
        ])
    }

    @ObservationIgnored var brandIcon: MenuIcon?

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
        // One popover at a time.
        volumeOpen = false
        calendarOpen = false
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
            openMenu = nil
            calendarOpen = false
        }
        syncInputRegion()
    }

    func setCalendarOpen(_ open: Bool) {
        guard calendarOpen != open else { return }
        calendarOpen = open
        if open {
            openMenu = nil
            volumeOpen = false
        }
        syncInputRegion()
    }

    /// An applet's own menu, open in the tray strip. The tray holds which
    /// item it belongs to; all this needs to know is that the panel has to
    /// keep the clicks.
    func setTrayMenuOpen(_ open: Bool) {
        guard trayMenuOpen != open else { return }
        trayMenuOpen = open
        if open {
            openMenu = nil
            volumeOpen = false
            calendarOpen = false
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

    /// The notification stack changed shape; keep the hit region in step.
    func setToasts(_ toasts: [Notifications.Toast]) {
        let depth = ToastStack.estimatedDepth(of: toasts)
        guard depth != toastDepth else { return }
        toastDepth = depth
        syncInputRegion()
    }

    /// Whether any strip popover needs the deep hit region.
    private var wantsCapture: Bool {
        openMenu != nil || volumeOpen || calendarOpen || trayMenuOpen
    }

    /// Hit-test region: strip when idle, full panel while a menu or volume
    /// popover is open so the dropdown is clickable and outside clicks dismiss.
    private func syncInputRegion() {
        ensureExpanded()
        let height = wantsCapture
            ? Self.openHeight
            : max(Self.stripHeight, min(toastDepth, Self.openHeight))
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
nonisolated(unsafe) var notifications: Notifications?
let pulse = PulseSession()

struct TaskbarView: View {
    let brandIcon: UIImage
    let menuFont: UIFont

    var body: some View {
        let chrome = MenuBarStyle.panel()
        // The strip is what paints; the surface is always tall enough for a
        // dropdown (see MenuSession.ensureExpanded). Transparent below the
        // strip so the desktop shows through; input region is strip-only when
        // closed so those pixels do not steal clicks.
        //
        // Horizontal inset only: 10pt on every edge of a 32pt bar left
        // 12pt for the icon and the titles overflowed the row.
        // `spacing: 0` is load-bearing. The theme default is 8px, and a
        // gap here is a hole between the painted strip and the work area
        // — maximized windows start at `reserved` (the 32px strip) and
        // that 8px is either empty desktop or a black band over them.
        return VStack(flexGrow: 1, padding: 0, spacing: 0) {
            HStack(height: .pt(MenuSession.stripHeight), padding: 0,
                   alignment: .center, spacing: 10) {
                // The flame is a top-level menu title, not a separate
                // picture: click it for Settings, the way a panel logo
                // always is the system menu. Window titles follow it.
                MenuBarStrip(
                    model: session.model,
                    openMenuID: openBinding,
                    onActivate: { session.activate($0) },
                    style: chrome,
                    icons: [DesktopMenuID.root: brandIcon]
                )
                .font(menuFont)

                if session.focusedSurface != 0 && !session.hasAppMenu {
                    // Focused window exports no menu (LavaTerm, a foreign
                    // app that never registered). Its name sits after the
                    // icon so the panel still says who is focused.
                    Text(
                        session.title.isEmpty ? "no window" : session.title,
                        color: Theme.current.textDim
                    )
                }

                // Pushes the clock (and tray) to the far end: an empty growing
                // child is the spacer, since the stack distributes leftover
                // space by flex.
                HStack(flexGrow: 1, padding: 0) {}

                trayStrip

                // Native sound control before the clock — scroll, mute, popover.
                VolumeApplet(pulse: pulse, isOpen: volumeOpenBinding)

                CalendarApplet(clockText: clock.text, isOpen: calendarOpenBinding)
            }
            .padding(.horizontal, 10)
            // Paint 33px of strip colour, reserve 32. Yoga is flush at
            // y=32; the hairline under the bar is the bottom coverage
            // of that fill blended in linear light against the clear
            // rest of this surface (and then over the window). Same
            // cover-up as LavaTerm's canvas fill at y-1. FIXME: fix
            // in the quad rasterizer, not here.
            .frame(height: .pt(MenuSession.stripHeight + 1))
            .background(Theme.current.background)

            // Fills the expanded surface so the strip stays top-aligned. Never
            // painted (backdrop is none, no fill here) — but it is where the
            // notification stack goes, pinned to the top right corner under
            // the strip, which is the one part of this surface that is empty
            // whether or not a menu is open.
            HStack(flexGrow: 1, padding: 0, alignment: .start) {
                Spacer()
                if let notifications, !notifications.toasts.isEmpty {
                    ToastStack(notifications: notifications)
                        .padding(EdgeInsets(top: 8, leading: 0, bottom: 0, trailing: 10))
                }
            }
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
        // Stack owns the hit target so left and right both work. Both may end
        // in the item's DBusMenu, drawn here rather than by the applet: an
        // SNI item has no window of its own, and the ones that implement no
        // methods at all — nm-applet, and most of libappindicator's users —
        // have nothing but that menu to offer.
        HStack(
            padding: 0,
            alignment: .center,
            onPointer: { _, button in
                guard let tray else { return }
                // A second click on the icon whose menu is open closes it,
                // which is what every panel does and what the pointer already
                // suggests by dismissing on click-out.
                if tray.openMenuKey == item.key {
                    session.setTrayMenuOpen(false)
                    tray.closeMenu()
                    return
                }
                let opened: Bool
                if button == PointerButton.right {
                    opened = tray.contextMenu(item)
                } else if button == PointerButton.left {
                    opened = tray.activate(item)
                } else {
                    opened = false
                }
                session.setTrayMenuOpen(opened)
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
        .hoverBackground(MenuBarStyle.panel().titleHover)
        .cornerRadius(6)
        .agentId("tray.\(item.key)")
        .overlay(
            isPresented: trayMenuBinding(item),
            alignment: .below,
            style: MenuBarStyle.panel().overlayStyle
        ) {
            trayMenu
        }
    }

    /// The open applet menu, drawn with the same panel a menu-bar dropdown
    /// uses — an imported menu is an imported menu, whether it came from the
    /// focused window or from an icon in the tray.
    @ViewBuilder
    private var trayMenu: some View {
        let entries = tray?.menuEntries ?? []
        if entries.isEmpty {
            // The applet was asked and has not answered yet. Saying so beats
            // an empty box that looks like a menu with nothing in it.
            Text("…", color: Theme.current.textDim)
        } else {
            MenuDropdownPanel(
                entries: entries,
                onActivate: { id in
                    tray?.activateMenuItem(id)
                    session.setTrayMenuOpen(false)
                    tray?.closeMenu()
                },
                style: MenuBarStyle.panel()
            )
        }
    }

    /// Open state for one item's menu. Setting it false is the click-out
    /// path — the overlay dismisses itself, and the tray has to hear about it
    /// or the next click on the icon would be treated as a re-open.
    private func trayMenuBinding(
        _ item: StatusNotifierTray.TrayItem
    ) -> Binding<Bool> {
        Binding(
            get: { tray?.openMenuKey == item.key },
            set: { open in
                guard !open else { return }
                session.setTrayMenuOpen(false)
                tray?.closeMenu()
            }
        )
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

    private var calendarOpenBinding: Binding<Bool> {
        Binding(
            get: { session.calendarOpen },
            set: { session.setCalendarOpen($0) }
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
session.attach(editor: editor, brandIcon: brandIcon)

// One face, loaded once. Building it inside `body` would reopen FreeType
// every clock tick, and a face that is never `registerWithEngine`'d
// measures at 64px while the compositor rasterizes font id 0 — the
// default 16px — which is the widely spaced "S e t t i n g s" look.
guard let menuFont = UIFont.loadUI(assetsRoot: LavaResources.root, pixelSize: 12)
else {
    FileHandle.standardError.write(
        Data("LavaTaskbar: could not load menu face\n".utf8)
    )
    exit(1)
}
menuFont.registerWithEngine(editor)

// System tray watcher — same timing as the menu registrar.
tray = StatusNotifierTray(editor: editor)

// And the notification daemon, if the session has none. Started here for the
// same reason as the other two: anything that fires a notification during
// login should find somewhere to send it.
notifications = Notifications(editor: editor)

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
            // Notifications ride the same context, and they need it for more
            // than delivery: an expiry is a clock nobody else is watching, so
            // a stack that stopped being polled would stay on screen forever.
            if notifications?.poll() == true {
                session.setToasts(notifications?.toasts ?? [])
            }
        }
        Thread.sleep(forTimeInterval: 0.05)
    }
}

LavaClient.run(editor: editor) {
    TaskbarView(brandIcon: brandIcon, menuFont: menuFont)
}
