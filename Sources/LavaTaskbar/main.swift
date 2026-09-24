import Foundation
import LavaClient
import LavaIDL
import LavaMpris
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
// And native applets next to the tray: volume (PulseAudio / PipeWire-Pulse),
// a month calendar on the clock, and a media chip that talks MPRIS —
// preferring spotifyd, falling back to any other player on the session
// bus. Cover, title, next/previous; the same popover contract as volume.
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
    static let about = MenuID("desktop.about")
    static let settings = MenuID("desktop.settings")
    static let launcher = MenuID("desktop.launcher")
    static let terminal = MenuID("desktop.terminal")
    static let logout = MenuID("desktop.logout")
}

/// A confirm drawn on the panel itself. About is a window of its own —
/// a card this tall does not belong in the strip's surface.
enum SystemDialog: Equatable {
    case none
    case logout
}

/// `LAVA_MENU_DEBUG=1`, the same switch the importer reads. Global menus fail
/// silently by nature — a window that exports nothing and one whose menu we
/// failed to find look identical from the outside — so the tracing has to be
/// there, and has to be off.
let menuDebug: Bool = {
    guard let value = ProcessInfo.processInfo.environment["LAVA_MENU_DEBUG"]
    else { return false }
    return !value.isEmpty && value != "0"
}()

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
    var openMenu: MenuID? {
        didSet {
            // Every path that puts a dropdown away goes through this — the
            // click-out, a popover taking over, a dialog, a workspace switch.
            // The importer has to hear it, or it keeps refreshing a menu
            // nobody is looking at. See `PanelMenu.closed`.
            if openMenu == nil, oldValue != nil { menus?.closed() }
        }
    }

    /// Log-out confirm. A popup, not a row of the menu that opened it:
    /// confirming and choosing are different gestures.
    var dialog: SystemDialog = .none

    /// The About window, if it is up. A second click does not open another.
    @ObservationIgnored var aboutWindow: WindowID?
    /// The volume window, if it is up. Clicking the speaker again closes it.
    @ObservationIgnored var volumeWindow: WindowID?
    /// The calendar window, if it is up. Clicking the clock again closes it.
    @ObservationIgnored var calendarWindow: WindowID?
    /// The player window, if it is up.
    @ObservationIgnored var playerWindow: WindowID?
    /// The log-out confirm, if it is up.
    @ObservationIgnored var logoutWindow: WindowID?
    /// The menu the compositor is drawing for us, if one is.
    @ObservationIgnored var hosted: HostedMenu?
    /// Rows that had not arrived yet. Filled from the pump.
    @ObservationIgnored var pendingMenu: PendingMenu?
    /// What About draws. Set once the assets exist, before `run`.
    @ObservationIgnored var aboutImage: UIImage?
    @ObservationIgnored var aboutFont: UIFont?

    /// How far down the surface the notification stack currently reaches, or
    /// 0 for none. Not `wantsCapture`: a toast needs its own pixels clickable
    /// and nothing else, where a dropdown wants the whole panel so a click
    /// outside it dismisses. Stealing 600pt of desktop for a toast that is
    /// 90pt tall would be a click nobody meant to give up.

    func attach(editor: Editor, brandIcon: UIImage) {
        self.editor = editor
        self.brandIcon = MenuIcon(size: 18, path: brandIcon.path)
        menus = PanelMenu(editor: editor)
        // Start on the desktop menu: nothing is focused yet.
        model = Self.desktopMenu(icon: self.brandIcon)
    }

    /// Called on the frame loop when the compositor's focus changes.
    func focus(_ window: LavaClient.FocusedWindow) {
        self.title = window.title
        self.focusedSurface = window.surfaceId
        // An open menu belongs to the window that is no longer focused.
        closeMenu()
        if menuDebug {
            let line = "LavaTaskbar: focus surface=\(window.surfaceId)"
                + " registrar=\(window.registrarId) pid=\(window.pid)"
                + " kde=\(window.menuService) \(window.menuObjectPath)"
                + " title=\(window.title)\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
        // The *registrar* id, not the surface id: an X11 client registered its
        // menu under its XID and has never heard of our surface numbering.
        menus?.setActiveWindow(
            window.registrarId,
            menuService: window.menuService,
            menuObjectPath: window.menuObjectPath,
            pid: window.pid
        )
        refreshModel()
    }

    /// Pumps DBus and publishes a new model when there is one. Menus are
    /// not drawn here, so this no longer grows the panel to hold one.
    func poll() {
        if menus?.poll() == true { refreshModel() }
        _ = tray?.poll()
        flushPendingMenu()
        syncSurface()
    }

    func activate(_ id: MenuID) {
        switch id {
        case DesktopMenuID.about:
            openAbout()
        case DesktopMenuID.settings:
            closeMenu()
            launchDesktopProgram("LavaSettings")
        case DesktopMenuID.launcher:
            closeMenu()
            launchDesktopProgram("LavaLauncher")
        case DesktopMenuID.terminal:
            closeMenu()
            launchDesktopProgram("LavaTerm")
        case DesktopMenuID.logout:
            setDialog(.logout)
        default:
            menus?.activate(id)
            closeMenu()
        }
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
        if hasAppMenu, menuDebug {
            let titles = imported.menus.map(\.title).joined(separator: ", ")
            FileHandle.standardError.write(
                Data("LavaTaskbar: imported [\(titles)]\n".utf8)
            )
        }
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
                        id: DesktopMenuID.about, title: "About Lava"
                    )),
                    .submenu(MenuNode(
                        id: MenuID("desktop.session"),
                        title: "Session",
                        items: [
                            .item(MenuItemModel(
                                id: MenuID("desktop.session.lock"), title: "Lock Screen"
                            )),
                            .submenu(MenuNode(
                                id: MenuID("desktop.session.more"),
                                title: "More",
                                items: [
                                    .item(MenuItemModel(
                                        id: MenuID("desktop.session.more.a"),
                                        title: "Nested item"
                                    )),
                                ]
                            )),
                        ]
                    )),
                    .item(MenuItemModel(
                        id: DesktopMenuID.settings, title: "Settings…"
                    )),
                    .separator,
                    .item(MenuItemModel(
                        id: DesktopMenuID.launcher, title: "Applications"
                    )),
                    .item(MenuItemModel(
                        id: DesktopMenuID.terminal, title: "Terminal"
                    )),
                    .separator,
                    .item(MenuItemModel(
                        id: DesktopMenuID.logout, title: "Log Out…"
                    )),
                ]
            ),
        ])
    }

    @ObservationIgnored var brandIcon: MenuIcon?

    // ─── Menus the compositor draws ──────────────────────────────────────
    //
    // The strip is 32pt and it stays that. A dropdown does not fit in it,
    // and growing the surface to hold one is a transparent window over the
    // top of the screen. The rows go through `OpenMenu`: the same path as
    // a right-click on the desktop, drawn by the menu client, placed and
    // dismissed by the compositor. This process only knows what the rows
    // say.

    func openMenu(_ id: MenuID) {
        // AboutToShow before presentation so a deferred submenu is asked for
        // before the first frame that shows the dropdown. Chromium (VSCode,
        // Teams) only fills File/Edit here, and the boolean it returns does
        // not tell libdbusmenu to refetch — `aboutToShow` has already asked
        // for the layout itself and rebuilt the model.
        menus?.aboutToShow(id)
        refreshModel()
        openMenu = id
        closePlayer()
        if dialog != .none { setDialog(.none) }
        if presentBar(id) {
            pendingMenu = nil
        } else {
            pendingMenu = .bar(id)
        }
    }

    func closeMenu() {
        guard openMenu != nil else { return }
        openMenu = nil
    }

    /// The pump, after the importer and the tray have had a turn. A menu
    /// whose rows were empty at the click is asked again until they arrive.
    func flushPendingMenu() {
        guard let pending = pendingMenu else {
            noteTray()
            return
        }
        switch pending {
        case .bar(let id):
            if presentBar(id) { pendingMenu = nil }
        case .tray(let key, let x, let y):
            if presentTray(key: key, x: x, y: y) { pendingMenu = nil }
        }
        noteTray()
    }

    /// A tray icon asked for its menu. The rows usually arrive a poll
    /// later; opening with nothing is a grab the user cannot use.
    func noteTray() {
        guard let tray = tray, let key = tray.openMenuKey else { return }
        if hosted?.trayKey == key { return }
        if case .tray(let pending, _, _) = pendingMenu, pending == key { return }
        let frame = LavaApp.mainLayoutHost?.agentFrame(sid: "tray.\(key)")
        let x = frame?.x ?? 0
        let y = (frame?.y ?? 0) + (frame?.h ?? Self.stripHeight)
        if presentTray(key: key, x: x, y: y) {
            pendingMenu = nil
        } else {
            pendingMenu = .tray(key: key, x: x, y: y)
        }
    }

    /// The answer to a menu this panel asked for. A serial that is not the
    /// one up is the menu a newer one replaced, and it is not a dismissal
    /// of the newer one.
    func menuChosen(serial: UInt32, chosen: UInt32) {
        guard let hosted, hosted.serial == serial else { return }
        let action = hosted.actions[chosen]
        let trayKey = hosted.trayKey
        self.hosted = nil
        guard chosen != 0, let action else {
            pendingMenu = nil
            if trayKey != nil {
                tray?.closeMenu()
            } else {
                openMenu = nil
            }
            return
        }
        switch action {
        case .barItem(let id):
            openMenu = nil
            activate(id)
        case .trayItem(let id):
            tray?.activateMenuItem(id)
            tray?.closeMenu()
        }
    }

    @discardableResult
    private func presentBar(_ id: MenuID) -> Bool {
        // Branches an application fills only when asked. One pass is the
        // menu the user opened; the passes after that are the branches that
        // pass just filled in. Four is a menu deeper than the ones this
        // panel has seen, and a branch that is still empty after that stays
        // a row — an empty fly-out is a worse answer than a door that does
        // not open yet.
        warmSubmenus(tray: false) {
            model.menus.first { $0.id == id }?.items ?? []
        }
        guard let menu = model.menus.first(where: { $0.id == id }),
              !menu.items.isEmpty
        else { return false }
        let (x, y) = anchor(for: "menu.\(id.raw)")
        return present(
            menu.items, title: menu.title, x: x, y: y, tray: false, trayKey: nil
        )
    }

    @discardableResult
    private func presentTray(key: String, x: Float, y: Float) -> Bool {
        warmSubmenus(tray: true) { tray?.menuEntries ?? [] }
        guard let entries = tray?.menuEntries, !entries.isEmpty else { return false }
        return present(entries, title: "", x: x, y: y, tray: true, trayKey: key)
    }

    /// `aboutToShow` on every submenu that has not been asked yet.
    ///
    /// Application menus fill the branch before the call returns. Tray
    /// menus answer on the bus, and `poll` is what copies that answer into
    /// `menuEntries` — which is why this reads the entries again after each
    /// pass instead of walking the list it started with.
    private func warmSubmenus(tray isTray: Bool, entries: () -> [MenuEntry]) {
        var seen = Set<MenuID>()
        for _ in 0..<4 {
            let ids = Self.submenuIDs(in: entries()).filter { seen.insert($0).inserted }
            if ids.isEmpty { break }
            for id in ids {
                if isTray { tray?.aboutToShow(id) }
                else { menus?.aboutToShow(id) }
            }
            if isTray { _ = tray?.poll() }
        }
    }

    private static func submenuIDs(in entries: [MenuEntry]) -> [MenuID] {
        var ids: [MenuID] = []
        func walk(_ entries: [MenuEntry]) {
            for entry in entries {
                guard case .submenu(let node) = entry else { continue }
                ids.append(node.id)
                walk(node.items)
            }
        }
        walk(entries)
        return ids
    }

    @discardableResult
    private func present(
        _ entries: [MenuEntry], title: String, x: Float, y: Float,
        tray: Bool, trayKey: String?
    ) -> Bool {
        let converted = MenuWire.convert(entries, tray: tray)
        guard !converted.items.isEmpty else { return false }
        let serial = LavaClient.openMenu(
            x: x, y: y, title: title, items: converted.items
        )
        guard serial != 0 else {
            FileHandle.standardError.write(
                Data("LavaTaskbar: no menu client — menu not shown\n".utf8)
            )
            return false
        }
        hosted = HostedMenu(
            serial: serial, actions: converted.actions, x: x, y: y, trayKey: trayKey
        )
        return true
    }

    private func anchor(for sid: String) -> (Float, Float) {
        if let frame = LavaApp.mainLayoutHost?.agentFrame(sid: sid) {
            return (frame.x, frame.y + frame.h)
        }
        return (0, Self.stripHeight)
    }

    private func openLogout() {
        if let id = logoutWindow, LavaApp.isWindowOpen(id) { return }
        let panelW = editor?.framebufferSize().w ?? 1280
        let width = LogoutWindow.width
        let anchor = LavaApp.SurfaceAnchor(
            x: max(8, (panelW - width) / 2),
            y: 0,
            w: width,
            h: Self.stripHeight
        )
        var opened: WindowID?
        opened = LavaApp.openPopup(
            title: "Log Out",
            width: width,
            height: LogoutWindow.height,
            anchor: anchor,
            backdropBlur: TaskbarChrome.popupBlurRadius,
            onClose: {
                if let id = opened, session.logoutWindow == id {
                    session.logoutWindow = nil
                    if session.dialog != .none { session.dialog = .none }
                }
            }
        ) {
            LogoutWindow()
        }
        logoutWindow = opened
    }

    /// "About Lava" as a window of this process. Already up means leave it:
    /// a second copy would be the same card twice, and the one that is up
    /// has its own close.
    func openAbout() {
        closeMenu()
        if dialog != .none { setDialog(.none) }
        if let id = aboutWindow, LavaApp.isWindowOpen(id) { return }
        guard let image = aboutImage, let font = aboutFont else { return }
        let panelW = editor?.framebufferSize().w ?? 1280
        let width: Float = 560
        // Centred under the strip. The compositor places the popup below
        // this rectangle and keeps it on the output.
        let anchor = LavaApp.SurfaceAnchor(
            x: max(8, (panelW - width) / 2),
            y: 0,
            w: width,
            h: Self.stripHeight
        )
        var opened: WindowID?
        opened = LavaApp.openPopup(
            title: "About Lava",
            width: width,
            height: 520,
            anchor: anchor,
            backdropBlur: TaskbarChrome.popupBlurRadius,
            onClose: {
                if let id = opened, session.aboutWindow == id {
                    session.aboutWindow = nil
                }
            }
        ) {
            AboutWindow(image: image, font: font)
        }
        aboutWindow = opened
    }

    /// Speaker click. Opens the volume window, or closes it when it is
    /// already the thing on screen — the same toggle the dropdown used,
    /// without the panel having to catch the click that dismisses it.
    func toggleVolume() {
        if let id = volumeWindow, LavaApp.isWindowOpen(id) {
            LavaApp.closeWindow(id)
            return
        }
        closeMenu()
        let panelW = editor?.framebufferSize().w ?? 1280
        // The speaker, in this panel. Missing — the first frame has not
        // laid out yet — is the right-hand end of the strip, which is
        // where the icon lives.
        let anchor: LavaApp.SurfaceAnchor
        if let icon = LavaApp.mainLayoutHost?.agentFrame(sid: "applet.volume") {
            anchor = LavaApp.SurfaceAnchor(icon)
        } else {
            anchor = LavaApp.SurfaceAnchor(
                x: panelW - 48, y: 0, w: 40, h: Self.stripHeight
            )
        }
        var opened: WindowID?
        opened = LavaApp.openPopup(
            title: "Volume",
            width: 280,
            height: 180,
            anchor: anchor,
            backdropBlur: TaskbarChrome.popupBlurRadius,
            onClose: {
                if let id = opened, session.volumeWindow == id {
                    session.volumeWindow = nil
                }
            }
        ) {
            VolumeWindow(pulse: pulse)
        }
        volumeWindow = opened
    }

    /// Clock click. Opens the calendar under the clock, or closes it when
    /// it is already up. A press that misses the popup is the compositor's
    /// to swallow — the panel does not grow to catch it.
    func toggleCalendar() {
        if let id = calendarWindow, LavaApp.isWindowOpen(id) {
            LavaApp.closeWindow(id)
            return
        }
        closeMenu()
        let panelW = editor?.framebufferSize().w ?? 1280
        let anchor: LavaApp.SurfaceAnchor
        if let clock = LavaApp.mainLayoutHost?.agentFrame(sid: "applet.calendar") {
            anchor = LavaApp.SurfaceAnchor(clock)
        } else {
            anchor = LavaApp.SurfaceAnchor(
                x: panelW - 180, y: 0, w: 160, h: Self.stripHeight
            )
        }
        var opened: WindowID?
        opened = LavaApp.openPopup(
            title: "Calendar",
            width: CalendarWindow.width,
            height: CalendarWindow.height,
            anchor: anchor,
            backdropBlur: TaskbarChrome.popupBlurRadius,
            onClose: {
                if let id = opened, session.calendarWindow == id {
                    session.calendarWindow = nil
                }
            }
        ) {
            CalendarWindow()
        }
        calendarWindow = opened
    }

    func togglePlayer() {
        if let id = playerWindow, LavaApp.isWindowOpen(id) {
            LavaApp.closeWindow(id)
            return
        }
        let panelW = editor?.framebufferSize().w ?? 1280
        let anchor: LavaApp.SurfaceAnchor
        if let chip = LavaApp.mainLayoutHost?.agentFrame(sid: "applet.player") {
            anchor = LavaApp.SurfaceAnchor(chip)
        } else {
            anchor = LavaApp.SurfaceAnchor(
                x: panelW * 0.5, y: 0, w: 120, h: Self.stripHeight
            )
        }
        var opened: WindowID?
        opened = LavaApp.openPopup(
            title: "Player",
            width: PlayerWindow.width,
            height: PlayerWindow.height,
            anchor: anchor,
            backdropBlur: TaskbarChrome.popupBlurRadius,
            onClose: {
                if let id = opened, session.playerWindow == id {
                    session.playerWindow = nil
                }
            }
        ) {
            PlayerWindow(mpris: mpris)
        }
        playerWindow = opened
    }

    func closePlayer() {
        guard let id = playerWindow, LavaApp.isWindowOpen(id) else { return }
        LavaApp.closeWindow(id)
    }

    func setDialog(_ next: SystemDialog) {
        guard dialog != next else { return }
        dialog = next
        if next == .none {
            if let id = logoutWindow, LavaApp.isWindowOpen(id) {
                LavaApp.closeWindow(id)
            }
            return
        }
        openMenu = nil
        closePlayer()
        tray?.closeMenu()
        openLogout()
    }

    /// The strip, plus the notification stack when there is one.
    ///
    /// Menus do not figure in it: those are a surface of their own. A toast
    /// still lives in this one, so the surface grows to the stack and
    /// shrinks back when the last card goes — never to the old fixed depth
    /// a dropdown used to need.
    private func syncSurface() {
        let height = surfaceHeight()
        if height != appliedHeight {
            appliedHeight = height
            LavaClient.setPanelThickness(height)
            if let editor {
                let size = editor.framebufferSize()
                let width = size.w > 1 ? size.w : 1920
                editor.setClientSize(width: width, height: height)
            }
        }
        syncInputRegion()
    }

    private func surfaceHeight() -> Float {
        guard !toastIds.isEmpty else { return Self.stripHeight }
        let estimate = Self.stripHeight + 16 + Float(toastIds.count) * 180
        guard appliedHeight + 1 >= estimate,
              let frame = toastFrame(), frame.h > 40
        else { return max(appliedHeight, estimate) }
        return max(Self.stripHeight, Float(frame.y) + Float(frame.h) + 8)
    }

    /// The notification stack changed shape; the hit region follows it.
    ///
    /// Deferred by a frame, because the rectangle now comes from the layout
    /// and the layout has not happened yet: this runs from the D-Bus pump,
    /// which the frame loop drains *before* it builds the tree. Measuring here
    /// would size the region to the stack as it was one toast ago — and on the
    /// first toast there is no node to measure at all.
    func setToasts(_ toasts: [Notifications.Toast]) {
        let ids = toasts.map(\.id)
        guard ids != toastIds else { return }
        toastIds = ids
        FrameTasks.after { [self] in syncSurface() }
    }

    /// Hit-test region: the strip, plus whatever else is currently claiming
    /// clicks.
    ///
    /// Two rectangles rather than one, and that is the whole point of the list
    /// form. The strip spans the screen; the notification cards sit at the
    /// right edge *below* it. Neither contains the other, so the only single
    /// rectangle covering both is the entire top of the display — which is
    /// what a toast used to claim, leaving the desktop under it dead to
    /// clicks until the notification expired.
    ///
    /// A menu or popover is still one rectangle covering the whole panel, and
    /// deliberately: the click that dismisses an open dropdown is the one that
    /// lands *outside* it, so the panel has to be the thing that receives it.
    private func syncInputRegion() {
        // Width is the surface length; the compositor clamps. A large constant
        // is fine — the panel is always full edge width.
        let width: Float = 8192
        var region = [InputRect(x: 0, y: 0, w: UInt32(width),
                                h: UInt32(Self.stripHeight))]
        if let toasts = toastFrame() {
            region.append(toasts)
        }
        guard !Self.sameRegion(region, appliedRegion) else { return }
        appliedRegion = region
        LavaClient.setInputRegion(region)
    }

    /// Field-by-field, because the generated `InputRect` is not `Equatable`
    /// and `Sources/LavaIDL` is not ours to hand-edit. The comparison is what
    /// keeps this to one round trip per actual change rather than one per
    /// D-Bus pump.
    private static func sameRegion(_ a: [InputRect], _ b: [InputRect]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy {
            $0.x == $1.x && $0.y == $1.y && $0.w == $1.w && $0.h == $1.h
        }
    }

    /// The notification stack's rectangle, as it was actually laid out, or nil
    /// when there is none on screen.
    ///
    /// Measured rather than estimated. The estimate it replaces added up a
    /// guess per card — two lines of summary, three of body if any, thirty
    /// points for actions — and erred high on purpose, because a region too
    /// short means a button on the last card does nothing. Reading the
    /// committed frame is exact and needs no such margin, and it stops being
    /// wrong the moment a card's contents wrap differently than the guess
    /// assumed.
    private func toastFrame() -> InputRect? {
        guard !toastIds.isEmpty,
              let frame = LavaApp.mainLayoutHost?.agentFrame(sid: "notifications"),
              frame.w > 0, frame.h > 0
        else { return nil }
        return InputRect(
            x: Int32(frame.x.rounded(.down)), y: Int32(frame.y.rounded(.down)),
            w: UInt32(frame.w.rounded(.up)), h: UInt32(frame.h.rounded(.up))
        )
    }

    @ObservationIgnored private var appliedHeight: Float = MenuSession.stripHeight
    @ObservationIgnored private var appliedRegion: [InputRect] = []
    /// Which notifications are up, so a pump that changed nothing costs a
    /// compare rather than a layout read and a round trip.
    @ObservationIgnored private var toastIds: [UInt32] = []

    /// The strip, and how deep the panel surface is for dropdown room.
    ///
    /// A fixed number because the panel does not know how tall the screen is —
    /// it is told its own size and nothing else — and this is comfortably more
    /// than any menubar depth while staying under the smallest display anyone
    /// runs this on.
    static let stripHeight: Float = 32
}

nonisolated(unsafe) let session = MenuSession()
nonisolated(unsafe) var tray: StatusNotifierTray?
nonisolated(unsafe) var notifications: Notifications?
let pulse = PulseSession()
let mpris = MprisSession()

/// Every popover on the panel — menubar dropdown, tray menu, volume,
/// calendar — wears this, so a theme change retints all of them and a
/// frost/radius tweak is not four call sites.
enum TaskbarChrome {
    static var style: MenuBarStyle { .panel() }

    /// About, the volume card and the calendar, over the compositor's frost.
    ///
    /// A menu row stays near opaque (`MenuBarStyle.panel`) because a
    /// column of labels has to read as solid. These cards can sit lower
    /// so the desktop comes through — and not so low that `textDim`,
    /// which is the sink name, falls into a bright wallpaper.
    static var popupWash: Color { Theme.current.panel.opacity(0.88) }

    /// Same radius a menu dropdown asks for. The plate's *corner* is not
    /// this — the compositor cuts it to the window's own corner radius.
    static let popupBlurRadius: Float = 12
}

struct TaskbarView: View {
    let brandIcon: UIImage
    let brandImage: UIImage
    let menuFont: UIFont
    /// Running text in the About card. Open Sans at the UI size is a label
    /// face; this is a paragraph, so it gets a reading face at 14px.
    let bodyFont: UIFont

    var body: some View {
        let chrome = TaskbarChrome.style
        // The strip is what paints. The surface is the strip, and grows only
        // while a notification stack needs the room under it. Transparent
        // below the strip so the desktop shows through; the input region is
        // the strip plus the cards, and nothing else.
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
                    icons: [DesktopMenuID.root: brandIcon],
                    externalMenus: true
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

                if mpris.present {
                    PlayerApplet(mpris: mpris)
                }

                trayStrip

                // Native sound control before the clock — scroll, mute, window.
                VolumeApplet(pulse: pulse)

                CalendarApplet(clockText: clock.text)
            }
            .padding(.horizontal, 10)
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
        // in the item's DBusMenu. The panel does not draw it: `OpenMenu`
        // hands the rows to the compositor, the same way a right-click on
        // the desktop does. An SNI item has no window of its own, and the
        // ones that implement no methods at all — nm-applet, and most of
        // libappindicator's users — have nothing but that menu to offer.
        HStack(
            padding: 0,
            alignment: .center,
            onPointer: { _, button in
                guard let tray else { return }
                // A second click on the icon whose menu is open closes it,
                // which is what every panel does and what the pointer already
                // suggests by dismissing on click-out.
                if button == PointerButton.right {
                    tray.contextMenu(item)
                } else if button == PointerButton.left {
                    tray.activate(item)
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
        .hoverBackground(TaskbarChrome.style.titleHover)
        .cornerRadius(6)
        .agentId("tray.\(item.key)")
    }

    /// The strip's open-menu state. The menu itself is the compositor's.
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

/// About, as a popup. Same glass as the volume card: a translucent wash
/// over the compositor's frost, not the panel's opaque background.
struct AboutWindow: View {
    var image: UIImage
    var font: UIFont

    var body: some View {
        VStack(padding: 12, spacing: 10) {
            HStack {
                Spacer()
                Image(image, width: .pt(400), contentMode: .fit)
                Spacer()
            }
            Text(
                "Lava is a free and open-source desktop environment. " +
                "It is designed to be fast, lightweight, and ready to use from the initial launch " +
                "— no tinkering with the config is needed. It is built by Claude, Grok and ChatGPT " +
                "for Nikita to use. During his life, Nikita has always struggled with computers and " +
                "particularly with Linux Desktop Environments. He has tried many, but none of them " +
                "have been able to provide him with the experience he desires. Then one day, he decided " +
                "to have Claude build him a new desktop environment, and thus Lava was born, and now " +
                "Nikita is not struggling with computers anymore, and he is happy."
            )
        }
        .flexGrow(1)
        .background(TaskbarChrome.popupWash)
        .agentId("dialog.about")
    }
}

/// Log out, as a popup. Confirming is not a menu row: the menu that offered
/// it has already closed, and the card is the question.
struct LogoutWindow: View {
    static let width: Float = 360
    static let height: Float = 150

    var body: some View {
        let theme = Theme.current
        VStack(padding: 0, spacing: 12) {
            Text("Log out?", color: theme.textPrimary)
            Text(
                "This ends the session and closes every window.",
                color: theme.textSecondary,
                lineLimit: 3
            )
            HStack(padding: 0, spacing: 8) {
                Spacer()
                Button("Cancel") { session.setDialog(.none) }
                Button(
                    "Log Out",
                    style: ButtonStyle(
                        background: theme.accent.opacity(0.22),
                        hover: theme.accent.opacity(0.38),
                        foreground: theme.accent
                    )
                ) {
                    session.setDialog(.none)
                    LavaClient.endSession()
                }
            }
        }
        .padding(16)
        .frame(width: .pt(Self.width), height: .pt(Self.height))
        .background(TaskbarChrome.popupWash)
        .agentId("dialog.logout")
    }
}

// ─── Desktop actions ─────────────────────────────────────────────────────────

/// Starts a sibling desktop program the way the compositor starts the
/// panel: look beside this binary first (tree build / installed layout),
/// then fall through to PATH.
func launchDesktopProgram(_ name: String) {
    let candidates: [String] = {
        var paths: [String] = []
        let args = CommandLine.arguments
        if let selfPath = args.first {
            let dir = URL(fileURLWithPath: selfPath).deletingLastPathComponent()
            paths.append(dir.appendingPathComponent(name).path)
            // compositor/scripts/dev-run often puts clients in .build/debug
            // while the panel may also live there — same dir is enough.
            paths.append(dir
                .appendingPathComponent("../debug/\(name)").path)
            paths.append(dir
                .appendingPathComponent("../release/\(name)").path)
        }
        paths.append(name)
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
        Data("LavaTaskbar: could not launch \(name)\n".utf8)
    )
}

/// Face for a paragraph, not a toolbar.
///
/// Open Sans is packed for UI labels. A 16px label face in a 500pt column is
/// what made the About card look like chrome with a story pasted on. Prefer
/// Adwaita Sans (Inter, the current GNOME reading face), then Noto Sans,
/// then the bundled Open Sans at the same 14px.
func loadReadingFace(pixelSize: Float) -> UIFont? {
    let paths = [
        "/usr/share/fonts/Adwaita/AdwaitaSans-Regular.ttf",
        "/usr/share/fonts/noto/NotoSans-Regular.ttf",
        "/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf",
        "/usr/share/fonts/liberation/LiberationSans-Regular.ttf",
        "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
        "/usr/share/fonts/TTF/DejaVuSans.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    ]
    for path in paths {
        if FileManager.default.fileExists(atPath: path),
           let font = UIFont(path: path, pixelSize: pixelSize)
        {
            return font
        }
    }
    return UIFont.loadUI(assetsRoot: LavaResources.root, pixelSize: pixelSize)
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

guard let brandImage = ImageStore.loadAsset(
    named: "lavaui.png", bundle: .module, into: editor
) else {
    FileHandle.standardError.write(
        Data("LavaTaskbar: could not load lavaui.png\n".utf8)
    )
    exit(1)
}

// Owns the registrar from here on, so an application starting after this point
// finds somewhere to export to. Before `run`, because an app that registers
// while the panel is still coming up should not have to try twice.
session.attach(editor: editor, brandIcon: brandIcon)
mpris.onAbsent = { session.closePlayer() }

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

guard let bodyFont = loadReadingFace(pixelSize: 14) else {
    FileHandle.standardError.write(
        Data("LavaTaskbar: could not load body face\n".utf8)
    )
    exit(1)
}
bodyFont.registerWithEngine(editor)
session.aboutImage = brandImage
session.aboutFont = bodyFont

// System tray watcher — same timing as the menu registrar.
tray = StatusNotifierTray(editor: editor)

// And the notification daemon, if the session has none. Started here for the
// same reason as the other two: anything that fires a notification during
// login should find somewhere to send it.
notifications = Notifications(editor: editor)

// Focus, from the compositor. Delivered on the frame loop, so touching
// observable state from it is the same as touching it from a click handler.
LavaClient.onActiveWindow { window in
    session.focus(window)
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

// Before any menu is opened. The compositor refuses `OpenMenu` for a
// surface that is not listening — a grab whose answer would go nowhere.
LavaClient.onMenuChoice { serial, chosen in
    session.menuChosen(serial: serial, chosen: chosen)
}

LavaClient.run(editor: editor) {
    TaskbarView(
        brandIcon: brandIcon, brandImage: brandImage,
        menuFont: menuFont, bodyFont: bodyFont
    )
}
