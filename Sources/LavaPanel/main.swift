import Foundation
import LavaBluetooth
import LavaNetwork
import LavaClient
import LavaIDL
import LavaMpris
import LavaShell
import LavaUI
import Observation

// The desktop's top panel, as an ordinary LavaUI client.
//
//   terminal 1:  compositor/scripts/dev-run
//   terminal 2:  swift run LavaPanel
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
    /// "Thu 19 Nov", beside the time rather than run into it.
    var date = ""
    /// "23:55:08", in the bar's tabular face.
    var time = ""

    @ObservationIgnored private let dateFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE d MMM"
        return formatter
    }()
    @ObservationIgnored private let timeFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    func tick() {
        let now = Date()
        // Compared before assigning: an observed write that changes nothing
        // still invalidates the body, and the date changes once a day.
        let nextDate = dateFormat.string(from: now)
        if nextDate != date { date = nextDate }
        time = timeFormat.string(from: now)
    }
}

/// How the bar sits, from `[panel] style`, for the life of the process.
let panelMetrics = PanelMetrics(style: PanelStyle.configured())

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
    static let about = MenuID("desktop.about")
    static let settings = MenuID("desktop.settings")
    static let lock = MenuID("desktop.session.lock")
    static let logout = MenuID("desktop.logout")
    static let sleep = MenuID("desktop.session.sleep")
    static let hibernate = MenuID("desktop.session.hibernate")
    static let powerOff = MenuID("desktop.session.power-off")
}

/// The Window menu every focused window gets, whatever it exports itself.
///
/// What a title bar's right-click offers, for windows that have no title
/// bar — a Lava app drawing its own chrome has no non-client area to click.
/// The compositor does the work; the panel only knows which window is
/// active. Not numeric, so no id here can be mistaken for a DBusMenu item
/// when it lands in an application's own Window menu.
enum WindowMenuID {
    static let root = MenuID("window")
    static let alwaysOnTop = MenuID("window.always-on-top")
    static let center = MenuID("window.center")
    static let close = MenuID("window.close")
}

/// The application menu supplied when an exported bar has no name menu:
/// the application's name over a Quit, also used when it exports nothing.
enum AppMenuID {
    static let root = MenuID("app")
    static let quit = MenuID("app.quit")
}

/// Session confirmations and failures, in a popup of their own.
enum SystemDialog: Equatable {
    case none
    case logout
    case powerOff
    case restart
    case powerError
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
    /// Whether that window is pinned, for the Window menu's checkmark.
    var focusedOnTop = false
    /// The focused window's application, as the compositor names it.
    var focusedAppId = ""
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

    /// Session confirmation in a separate popup: choosing an action and
    /// confirming it are different gestures.
    var dialog: SystemDialog = .none

    /// The About window, if it is up. A second click does not open another.
    @ObservationIgnored var aboutWindow: WindowID?
    /// The volume window, if it is up. Clicking the speaker again closes it.
    var volumeWindow: WindowID?
    /// The network window, if it is up. Clicking the glyph again closes it.
    var networkWindow: WindowID?
    /// The pane of every Wi-Fi network beside it, if that is up. Observed:
    /// the row that opens it shows whether it is open.
    var networkListWindow: WindowID?
    /// A window per secret prompt the agent is waiting on, with what has been
    /// typed into it.
    @ObservationIgnored var authWindows: [UInt64: (window: WindowID, draft: AuthDraft)] = [:]
    /// The Bluetooth window, if it is up. Clicking the rune again closes it.
    var bluetoothWindow: WindowID?
    /// The search pane beside it. Observed: the row that opens it shows
    /// whether it is open.
    var bluetoothSearchWindow: WindowID?
    /// A window per pairing request the agent is waiting on.
    @ObservationIgnored var pairWindows: [UInt64: (window: WindowID, draft: PairDraft)] = [:]
    /// The face a pairing code is shown in, big enough to read off at a
    /// glance while typing it on a keyboard.
    @ObservationIgnored var codeFont: UIFont?
    /// The calendar window, if it is up. Clicking the clock again closes it.
    var calendarWindow: WindowID?
    /// The year beside it, if that is up. Observed: the month title it was
    /// opened from shows whether it is.
    var yearWindow: WindowID?
    /// The month the calendar shows, and the year the year window does.
    @ObservationIgnored let calendarModel = CalendarModel()
    /// The player window, if it is up.
    var playerWindow: WindowID?
    /// The power button's card, while it is up.
    var sessionCard: WindowID?
    /// The battery card, while it is up.
    var batteryWindow: WindowID?
    /// The session confirmation or error popup, if it is up.
    @ObservationIgnored var sessionWindow: WindowID?
    var powerBusy = false
    var powerError = ""
    var powerErrorTitle = ""
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

    func attach(editor: Editor) {
        self.editor = editor
        menus = PanelMenu(editor: editor)
        // Start on the desktop menu: nothing is focused yet.
        model = emptyBar()
    }

    /// Called on the frame loop when the compositor's focus changes.
    func focus(_ window: LavaClient.FocusedWindow) {
        self.title = window.title
        self.focusedSurface = window.surfaceId
        self.focusedOnTop = window.alwaysOnTop
        self.focusedAppId = window.appId
        // An open menu belongs to the window that is no longer focused.
        closeMenu()
        if menuDebug {
            let line = "LavaPanel: focus surface=\(window.surfaceId)"
                + " registrar=\(window.registrarId) pid=\(window.pid)"
                + " onTop=\(window.alwaysOnTop)"
                + " kde=\(window.menuService) \(window.menuObjectPath)"
                + " app=\(window.appId) title=\(window.title)\n"
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
        // Once now, so the bar sees the importer emptied for the new window.
        _ = menus?.poll()
        if window.surfaceId != 0, menus?.model.menus.isEmpty ?? true {
            awaitMenu(for: window.surfaceId)
        } else {
            awaitingMenu = 0
            refreshModel()
        }
    }

    /// A window just focused whose menu has not been read yet — the usual
    /// case for an app that has only just started, which registers its menu
    /// and is asked for the layout over D-Bus after its window is up.
    ///
    /// Showing what the panel has in the meantime is showing the fallback
    /// (its name over a Quit) and then, a moment later, the real menus: the
    /// bar blinks on every launch. So the bar stays as it was until the menu
    /// arrives, and falls back only if none has after `menuGrace` — an app
    /// that exports nothing pays that much delay on its name, once per focus.
    private func awaitMenu(for surface: UInt32) {
        awaitingMenu = surface
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.menuGrace) {
            MainQueue.async {
                guard session.awaitingMenu == surface else { return }
                session.awaitingMenu = 0
                session.refreshModel()
            }
        }
    }

    /// The focused surface whose menu the bar is waiting on, or 0.
    @ObservationIgnored var awaitingMenu: UInt32 = 0
    static let menuGrace: TimeInterval = 0.4

    /// Pumps DBus and publishes a new model when there is one. Menus are
    /// not drawn here, so this no longer grows the panel to hold one.
    func poll() {
        if menus?.poll() == true {
            // Still nothing for the window waited on: a change on the way
            // there, not the menu. Keep waiting.
            let stillWaiting = awaitingMenu != 0 && (menus?.model.menus.isEmpty ?? true)
            if !stillWaiting {
                awaitingMenu = 0
                refreshModel()
            }
        }
        _ = tray?.poll()
        flushPendingMenu()
        syncSurface()
    }

    func activate(_ id: MenuID) {
        if id.raw.hasPrefix(DesktopMenus.goPrefix) {
            closeMenu()
            let path = String(id.raw.dropFirst(DesktopMenus.goPrefix.count))
            launchDesktopProgram("LavaExplorer", arguments: [path])
            return
        }
        if id.raw.hasPrefix(DesktopMenus.workspacePrefix),
           let index = UInt32(id.raw.dropFirst(DesktopMenus.workspacePrefix.count)) {
            closeMenu()
            LavaClient.switchWorkspace(index)
            return
        }
        switch id {
        case DesktopMenus.showDesktop:
            closeMenu()
            LavaClient.toggleShowDesktop()
        case DesktopMenus.background:
            closeMenu()
            launchDesktopProgram("LavaSettings", arguments: ["--section", "background"])
        case DesktopMenus.displays:
            closeMenu()
            launchDesktopProgram("LavaSettings", arguments: ["--section", "display"])
        case DesktopMenus.shortcuts:
            closeMenu()
            openShortcuts()
        case DesktopMenuID.about:
            openAbout()
        case DesktopMenuID.settings:
            closeMenu()
            launchDesktopProgram("LavaSettings")
        case DesktopMenuID.lock:
            closeMenu()
            // The compositor's lock, the one Mod+L takes. Nothing to report
            // on failure that the user would not already see: the screen
            // either locked or it did not.
            try? DesktopSettings.lockSession()
        case DesktopMenuID.logout:
            setDialog(.logout)
        case DesktopMenuID.sleep:
            requestPower(.sleep)
        case DesktopMenuID.hibernate:
            requestPower(.hibernate)
        case DesktopMenuID.powerOff:
            setDialog(.powerOff)
        // On the window that was focused when the menu opened — which is
        // still the focused one: the panel takes no focus to draw a menu.
        case WindowMenuID.alwaysOnTop:
            closeMenu()
            if focusedSurface != 0 {
                LavaClient.setAlwaysOnTop(focusedSurface, !focusedOnTop)
            }
        case WindowMenuID.center:
            closeMenu()
            if focusedSurface != 0 { LavaClient.centerWindow(focusedSurface) }
        case WindowMenuID.close:
            closeMenu()
            if focusedSurface != 0 { LavaClient.closeWindow(focusedSurface) }
        // The panel's fallback can close this window; it has no application-
        // wide quit action to dispatch to a foreign client.
        case AppMenuID.quit:
            closeMenu()
            if focusedSurface != 0 { LavaClient.closeWindow(focusedSurface) }
        default:
            menus?.activate(id)
            closeMenu()
        }
    }

    /// The system menu (Lava icon) always stays first. A focused window's
    /// application name follows it, supplying an application menu when the
    /// exported bar has none — its name, over a Quit.
    func refreshModel() {
        if focusedSurface == 0 {
            hasAppMenu = false
            model = emptyBar()
            return
        }
        var imported = menus?.model ?? MenuModel()
        hasAppMenu = !imported.menus.isEmpty
        if hasAppMenu, menuDebug {
            let titles = imported.menus.map(\.title).joined(separator: ", ")
            FileHandle.standardError.write(
                Data("LavaPanel: imported [\(titles)]\n".utf8)
            )
        }
        imported = imported.adding(applicationMenu: Self.appMenu(name: appName()))
        model = MenuModel(
            menus: imported.adding(shellMenu: Self.windowMenu(onTop: focusedOnTop)).menus
        )
    }

    static func appMenu(name: String) -> MenuNode {
        MenuNode(
            id: AppMenuID.root,
            title: name,
            items: [.item(MenuItemModel(id: AppMenuID.quit, title: "Quit \(name)"))]
        )
    }

    /// What to call the focused application: its desktop entry's name when
    /// one matches the app id, the app id itself when none does, and the
    /// window's title only when the client never gave an app id at all.
    private func appName() -> String {
        let appId = focusedAppId
        if appId.isEmpty { return title.isEmpty ? "Application" : title }
        if catalog == nil {
            // Once, on the first focused application: a scan of every
            // applications directory is not something to do per focus.
            var map: [String: String] = [:]
            for entry in DesktopEntry.installed() where !entry.name.isEmpty {
                map[entry.id.lowercased()] = entry.name
                if !entry.startupWMClass.isEmpty {
                    map[entry.startupWMClass.lowercased()] = entry.name
                }
            }
            catalog = map
        }
        if let name = catalog?[appId.lowercased()] { return name }
        // `org.mozilla.firefox` with no entry by that id: the last part is the
        // name the user would recognise.
        let last = appId.split(separator: ".").last.map(String.init) ?? appId
        return last.prefix(1).uppercased() + last.dropFirst()
    }

    /// App id (lowercased) or `StartupWMClass` → desktop entry name. Built on
    /// first use; an application installed after that shows its app id.
    @ObservationIgnored private var catalog: [String: String]?

    /// Before Help, or merged into the app's own Window menu — see
    /// `MenuModel.adding(shellMenu:)`.
    static func windowMenu(onTop: Bool) -> MenuNode {
        MenuNode(
            id: WindowMenuID.root,
            title: "Window",
            items: [
                .item(MenuItemModel(
                    id: WindowMenuID.alwaysOnTop, title: "Always on Top",
                    isChecked: onTop
                )),
                .item(MenuItemModel(id: WindowMenuID.center, title: "Center on Screen")),
                .separator,
                .item(MenuItemModel(id: WindowMenuID.close, title: "Close")),
            ]
        )
    }

    /// Whether the focused window exported titles of its own.
    var hasAppMenu = false

    // ─── The bar with nothing focused ────────────────────────────────────

    /// Which workspace is on screen and what is on each, for the Workspaces
    /// menu. From `SubscribeWindows`, the dock's own feed.
    @ObservationIgnored var workspaces = DesktopMenus.Workspaces()
    /// The same, observed: the dots on the bar redraw when it changes, and
    /// the menu model above deliberately does not.
    var workspaceDots = DesktopMenus.Workspaces()
    /// The compositor's shortcut modifier, for the shortcuts beside each
    /// workspace. Read at startup; the next panel start shows a change.
    @ObservationIgnored var modKey = "alt"
    @ObservationIgnored var shortcutsWindow: WindowID?

    /// The desktop's own menus.
    func emptyBar() -> MenuModel {
        MenuModel(menus: DesktopMenus.menus(workspaces: workspaces, modKey: modKey))
    }

    func refreshDesktopBar() {
        if focusedSurface == 0 { refreshModel() }
    }

    func setWorkspaces(_ current: UInt32, _ windows: [WindowInfo]) {
        let next = DesktopMenus.Workspaces(current: current, windows: DesktopMenus.counts(windows))
        guard next != workspaces else { return }
        workspaces = next
        workspaceDots = next
        // The empty bar is the only one that shows them. A dropdown already
        // open keeps the rows it was drawn with until it is opened again.
        if focusedSurface == 0 { refreshModel() }
    }

    /// Help → Keyboard Shortcuts: a card under the Help title, like the
    /// calendar under the clock. A window had a title bar and a maximize
    /// button for a list that is read and dismissed; this goes away with a
    /// click anywhere else.
    func openShortcuts() {
        if let id = shortcutsWindow, LavaApp.isWindowOpen(id) { return }
        let bindings = (try? DesktopSettings.keyBindings()) ?? []
        let panelW = editor?.framebufferSize().w ?? 1280
        let anchor = LavaApp.SurfaceAnchor(
            x: max(8, (panelW - ShortcutsWindow.width) / 2),
            y: 0,
            w: ShortcutsWindow.width,
            h: Self.stripHeight
        )
        var opened: WindowID?
        opened = LavaApp.openPopup(
            title: "Keyboard Shortcuts",
            width: ShortcutsWindow.width,
            height: ShortcutsWindow.height(bindings.count),
            anchor: anchor,
            onClose: {
                if let id = opened, session.shortcutsWindow == id { session.shortcutsWindow = nil }
            }
        ) {
            ShortcutsWindow(bindings: bindings)
                .backdropBlur(radius: PanelChrome.popupBlurRadius)
                .glassEffect(magnification: PanelChrome.popupMagnification)
        }
        shortcutsWindow = opened
    }

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
        // Opened while a launch's menu is still on its way: what is known
        // now is what a dropdown can honestly show.
        awaitingMenu = 0
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
        // No header: the menu hangs from the title that was just clicked, and
        // a first row repeating it is a row that does nothing.
        return present(
            menu.items, title: "", x: x, y: y, tray: false, trayKey: nil
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
                Data("LavaPanel: no menu client — menu not shown\n".utf8)
            )
            return false
        }
        hosted = HostedMenu(
            serial: serial, actions: converted.actions, x: x, y: y, trayKey: trayKey
        )
        return true
    }

    /// Under a menu title: its left edge, the bar's gap below the bar —
    /// the compositor puts the plate's corner exactly here.
    private func anchor(for sid: String) -> (Float, Float) {
        let host = LavaApp.mainLayoutHost
        let barBottom = host?.agentFrame(sid: "panel.bar").map { $0.y + $0.h }
            ?? Self.stripHeight
        let x = host?.agentFrame(sid: sid)?.x ?? 0
        return (x, barBottom + panelMetrics.popupGap)
    }

    private func openSessionDialog() {
        if let id = sessionWindow, LavaApp.isWindowOpen(id) { return }
        var opened: WindowID?
        opened = LavaApp.openPopup(
            title: "Session",
            width: SessionWindow.width,
            height: SessionWindow.height,
            anchor: centredAnchor(width: SessionWindow.width),
            onClose: {
                if let id = opened, session.sessionWindow == id {
                    session.sessionWindow = nil
                    if session.dialog != .none { session.dialog = .none }
                }
            }
        ) {
            // The card frosts itself, at its own corner, and sizes the popup
            // to its text.
            SessionWindow()
        }
        sessionWindow = opened
    }

    /// "About Lava" as a window of this process. Already up means leave it:
    /// a second copy would be the same card twice, and the one that is up
    /// has its own close.
    func openAbout() {
        closeMenu()
        if dialog != .none { setDialog(.none) }
        if let id = aboutWindow, LavaApp.isWindowOpen(id) { return }
        guard let image = aboutImage, let font = aboutFont else { return }
        let width = AboutWindow.width
        var opened: WindowID?
        opened = LavaApp.openPopup(
            title: "About Lava",
            width: width,
            height: AboutWindow.height,
            anchor: centredAnchor(width: width),
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
        let anchor = popupAnchor(under: "tray", width: SoundBlock.width)
        var opened: WindowID?
        // Sized to what is there when it opens. Something that starts
        // playing while it is up makes the list scroll rather than the
        // window grow: a popup's size is fixed at creation.
        opened = LavaApp.openPopup(
            title: "Volume",
            width: SoundBlock.width,
            height: SoundBlock.height(of: SoundBlock.blocks(pulse)),
            anchor: anchor,
            onClose: {
                if let id = opened, session.volumeWindow == id {
                    session.volumeWindow = nil
                }
            }
        ) {
            // The card frosts itself, at its own corner radius.
            VolumeWindow(pulse: pulse)
        }
        volumeWindow = opened
    }

    /// Network glyph click. Opens the network window — and asks for a scan,
    /// so the list is fresh by the time anyone reads it — or closes it.
    func toggleNetwork() {
        if let id = networkWindow, LavaApp.isWindowOpen(id) {
            LavaApp.closeWindow(id)
            return
        }
        closeMenu()
        network.scan()
        let anchor = popupAnchor(under: "tray", width: NetworkBlock.width)
        var opened: WindowID?
        // Sized to what is there when it opens; a scan that finds more
        // makes the list scroll, as the sound window's does.
        opened = LavaApp.openPopup(
            title: "Network",
            width: NetworkBlock.width,
            height: NetworkBlock.height(of: NetworkBlock.blocks(network)),
            anchor: anchor,
            onClose: {
                if let id = opened, session.networkWindow == id {
                    session.networkWindow = nil
                    // The pane hangs off this window; it goes with it.
                    session.closeNetworkList()
                }
            }
        ) {
            // The card frosts itself, at its own corner radius.
            NetworkWindow(network: network)
        }
        networkWindow = opened
    }

    /// "All Wi-Fi networks". A popup of the network window rather than of
    /// the panel, to its left, top edges level: the compositor keeps the
    /// network window up while the pane is pressed, because it is the pane's
    /// parent.
    func toggleNetworkList() {
        if let id = networkListWindow, LavaApp.isWindowOpen(id) {
            closeNetworkList()
            return
        }
        guard let parent = networkWindow, LavaApp.isWindowOpen(parent) else { return }
        network.scan()
        let width = NetworkBlock.listWidth
        var opened: WindowID?
        opened = LavaApp.openPopup(
            title: "Wi-Fi Networks",
            width: width,
            height: NetworkBlock.height(of: NetworkBlock.listBlocks(network)),
            anchor: .leftOf(parent, width: width, gap: 10),
            onClose: {
                if let id = opened, session.networkListWindow == id {
                    session.networkListWindow = nil
                }
            }
        ) {
            // The card frosts itself, at its own corner radius.
            NetworkWindow(network: network, isList: true)
        }
        networkListWindow = opened
    }

    func closeNetworkList() {
        guard let id = networkListWindow else { return }
        networkListWindow = nil
        if LavaApp.isWindowOpen(id) { LavaApp.closeWindow(id) }
    }

    /// The agent needs something typed. A window of its own: a popup takes
    /// no keyboard, and the network window may not even be open — a VPN
    /// that reconnects on its own asks just the same.
    func openAuth(_ prompt: NetworkSession.SecretPrompt) {
        guard authWindows[prompt.id] == nil else { return }
        let draft = AuthDraft(prompt)
        var opened: WindowID?
        opened = LavaClient.openWindow(
            title: prompt.title.isEmpty ? "Network" : prompt.title,
            width: NetworkAuthWindow.width,
            height: NetworkAuthWindow.height(prompt),
            frame: .client,
            dialogParent: 0,
            onClose: {
                // Closing the prompt is a no.
                if session.authWindows[prompt.id] != nil { session.cancelAuth(prompt.id) }
            }
        ) {
            NetworkAuthWindow(prompt: prompt, draft: draft)
        }
        if let opened { authWindows[prompt.id] = (opened, draft) }
        else { network.decline(prompt.id) }
    }

    func submitAuth(_ id: UInt64) {
        guard let entry = authWindows.removeValue(forKey: id) else { return }
        network.answer(id, values: entry.draft.values)
        entry.draft.clear()
        LavaApp.closeWindow(entry.window)
    }

    func cancelAuth(_ id: UInt64) {
        guard let entry = authWindows.removeValue(forKey: id) else { return }
        network.decline(id)
        entry.draft.clear()
        LavaApp.closeWindow(entry.window)
    }

    /// NetworkManager stopped waiting: another agent answered, or the
    /// connection was cancelled.
    func dropAuth(_ id: UInt64) {
        guard let entry = authWindows.removeValue(forKey: id) else { return }
        entry.draft.clear()
        LavaApp.closeWindow(entry.window)
    }

    /// Bluetooth rune click. Opens the Bluetooth window, or closes it.
    func toggleBluetooth() {
        if let id = bluetoothWindow, LavaApp.isWindowOpen(id) {
            LavaApp.closeWindow(id)
            return
        }
        closeMenu()
        let anchor = popupAnchor(under: "tray", width: BluetoothBlock.width)
        var opened: WindowID?
        opened = LavaApp.openPopup(
            title: "Bluetooth",
            width: BluetoothBlock.width,
            height: BluetoothBlock.height(of: BluetoothBlock.blocks(bluetooth)),
            anchor: anchor,
            onClose: {
                if let id = opened, session.bluetoothWindow == id {
                    session.bluetoothWindow = nil
                    session.closeBluetoothSearch()
                }
            }
        ) {
            // The card frosts itself, at its own corner radius.
            BluetoothWindow(bluetooth: bluetooth)
        }
        bluetoothWindow = opened
    }

    /// "Add a device…": a popup of the Bluetooth window, to its left, that
    /// searches for as long as it is open.
    func toggleBluetoothSearch() {
        if let id = bluetoothSearchWindow, LavaApp.isWindowOpen(id) {
            closeBluetoothSearch()
            return
        }
        guard let parent = bluetoothWindow, LavaApp.isWindowOpen(parent) else { return }
        bluetooth.setSearching(true)
        let width = BluetoothBlock.searchWidth
        var opened: WindowID?
        opened = LavaApp.openPopup(
            title: "Add a Device",
            width: width,
            height: BluetoothBlock.searchHeight,
            anchor: .leftOf(parent, width: width, gap: 10),
            onClose: {
                if let id = opened, session.bluetoothSearchWindow == id {
                    session.bluetoothSearchWindow = nil
                    bluetooth.setSearching(false)
                }
            }
        ) {
            // The card frosts itself, at its own corner radius.
            BluetoothWindow(bluetooth: bluetooth, isSearch: true)
        }
        bluetoothSearchWindow = opened
        if opened == nil { bluetooth.setSearching(false) }
    }

    func closeBluetoothSearch() {
        guard let id = bluetoothSearchWindow else { return }
        bluetoothSearchWindow = nil
        bluetooth.setSearching(false)
        if LavaApp.isWindowOpen(id) { LavaApp.closeWindow(id) }
    }

    /// The pairing agent wants the user: a code to compare or type, or a
    /// device asking to be let in. A window of its own, as a secret prompt
    /// is — it may need the keyboard, and a phone pairing from its side
    /// asks with no window of ours open.
    func openPairing(_ prompt: BluetoothSession.PairingPrompt) {
        guard pairWindows[prompt.id] == nil else { return }
        let draft = PairDraft()
        let font = codeFont
        var opened: WindowID?
        opened = LavaClient.openWindow(
            title: prompt.text.title,
            width: BluetoothPairWindow.width,
            height: BluetoothPairWindow.height(prompt),
            frame: .client,
            dialogParent: 0,
            onClose: {
                // Closing the prompt is a no.
                if session.pairWindows[prompt.id] != nil {
                    session.answerPairing(prompt.id, accept: false)
                }
            }
        ) {
            BluetoothPairWindow(bluetooth: bluetooth, id: prompt.id, draft: draft, codeFont: font)
        }
        if let opened { pairWindows[prompt.id] = (opened, draft) }
        else { bluetooth.decline(prompt.id) }
    }

    func answerPairing(_ id: UInt64, accept: Bool) {
        guard let entry = pairWindows.removeValue(forKey: id) else { return }
        let wantsInput = bluetooth.prompt(id)?.wantsInput == true
        if accept {
            let text = entry.draft.text.trimmingCharacters(in: .whitespaces)
            bluetooth.accept(id, text: wantsInput ? text : nil)
        } else {
            bluetooth.decline(id)
        }
        entry.draft.clear()
        LavaApp.closeWindow(entry.window)
    }

    /// BlueZ stopped waiting, or the pairing a shown code was for ended.
    func dropPairing(_ id: UInt64) {
        guard let entry = pairWindows.removeValue(forKey: id) else { return }
        entry.draft.clear()
        LavaApp.closeWindow(entry.window)
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
        // The design hangs it 40pt past the clock's right edge, over the
        // power button, so the month sits under the time.
        let anchor = popupAnchor(under: "applet.calendar", width: CalendarWindow.width,
                                 rightOverhang: 40)
        // Opens on today, wherever it was paged to last time.
        calendarModel.reset()
        let model = calendarModel
        var opened: WindowID?
        opened = LavaApp.openPopup(
            title: "Calendar",
            width: CalendarWindow.width,
            height: CalendarWindow.height,
            anchor: anchor,
            onClose: {
                if let id = opened, session.calendarWindow == id {
                    session.calendarWindow = nil
                    // The year hangs off this window; it goes with it.
                    session.closeYear()
                }
            }
        ) {
            // The card frosts itself, at its own corner radius.
            CalendarWindow(model: model)
        }
        calendarWindow = opened
    }

    /// The month title: the whole year, to the calendar's left, top edges
    /// level. A popup of the calendar rather than of the panel, so a click
    /// in it does not count as a click outside the calendar.
    func toggleYear() {
        if let id = yearWindow, LavaApp.isWindowOpen(id) {
            closeYear()
            return
        }
        guard let parent = calendarWindow, LavaApp.isWindowOpen(parent) else { return }
        calendarModel.year = Calendar.current.component(.year, from: calendarModel.visibleMonth)
        let model = calendarModel
        let width = YearWindow.width
        var opened: WindowID?
        opened = LavaApp.openPopup(
            title: "Year",
            width: width,
            height: YearWindow.height,
            anchor: .leftOf(parent, width: width, gap: 10),
            onClose: {
                if let id = opened, session.yearWindow == id {
                    session.yearWindow = nil
                }
            }
        ) {
            // The card frosts itself, at its own corner radius.
            YearWindow(model: model)
        }
        yearWindow = opened
    }

    func closeYear() {
        guard let id = yearWindow else { return }
        yearWindow = nil
        if LavaApp.isWindowOpen(id) { LavaApp.closeWindow(id) }
    }

    func togglePlayer() {
        if let id = playerWindow, LavaApp.isWindowOpen(id) {
            LavaApp.closeWindow(id)
            return
        }
        let anchor = popupAnchor(under: "applet.player", width: PlayerWindow.width,
                                 leftAligned: true)
        var opened: WindowID?
        opened = LavaApp.openPopup(
            title: "Player",
            width: PlayerWindow.width,
            height: PlayerWindow.height,
            anchor: anchor,
            onClose: {
                if let id = opened, session.playerWindow == id {
                    session.playerWindow = nil
                }
            }
        ) {
            // The card frosts itself, at its own corner radius.
            PlayerWindow(mpris: mpris)
        }
        playerWindow = opened
    }

    /// The battery glyph: its card under the tray, or closed if it is up.
    func toggleBattery() {
        if let id = batteryWindow, LavaApp.isWindowOpen(id) {
            LavaApp.closeWindow(id)
            return
        }
        let anchor = popupAnchor(under: "tray", width: BatteryWindow.width)
        var opened: WindowID?
        opened = LavaApp.openPopup(
            title: "Battery",
            width: BatteryWindow.width,
            height: BatteryWindow.height(details: BatteryWindow.details(battery).count),
            anchor: anchor,
            onClose: {
                if let id = opened, session.batteryWindow == id { session.batteryWindow = nil }
            }
        ) {
            BatteryWindow()
        }
        batteryWindow = opened
        // Read now rather than at the next slow tick: the card should open on
        // the current numbers.
        DispatchQueue.global().async { battery.poll() }
    }

    /// The power button: the session card under it, or closed if it is up.
    func toggleSessionCard() {
        if let id = sessionCard, LavaApp.isWindowOpen(id) {
            LavaApp.closeWindow(id)
            return
        }
        let anchor = popupAnchor(under: "applet.power", width: SessionCard.width)
        var opened: WindowID?
        opened = LavaApp.openPopup(
            title: "Session",
            width: SessionCard.width,
            height: SessionCard.height,
            anchor: anchor,
            onClose: {
                if let id = opened, session.sessionCard == id { session.sessionCard = nil }
            }
        ) {
            SessionCard()
        }
        sessionCard = opened
    }

    func closeSessionCard() {
        guard let id = sessionCard, LavaApp.isWindowOpen(id) else { return }
        LavaApp.closeWindow(id)
    }

    func closePlayer() {
        guard let id = playerWindow, LavaApp.isWindowOpen(id) else { return }
        LavaApp.closeWindow(id)
    }

    func requestPower(_ action: PowerAction) {
        guard !powerBusy else { return }
        closeMenu()
        setDialog(.none)
        powerBusy = true
        DispatchQueue.global().async {
            let error = action.perform()
            MainQueue.async {
                session.powerBusy = false
                if let error {
                    session.powerErrorTitle = "Could not \(action.title.lowercased())"
                    session.powerError = error
                    session.setDialog(.powerError)
                }
            }
        }
    }

    func setDialog(_ next: SystemDialog) {
        guard dialog != next else { return }
        dialog = next
        if next == .none {
            if let id = sessionWindow, LavaApp.isWindowOpen(id) {
                LavaApp.closeWindow(id)
            }
            return
        }
        openMenu = nil
        closePlayer()
        tray?.closeMenu()
        openSessionDialog()
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
            // Deeper than what is reserved: the surface also holds the
            // bar's shadow and any notifications, both over the windows.
            LavaClient.setPanelThickness(height, reserved: panelMetrics.reserved)
            if let editor {
                let size = editor.framebufferSize()
                let width = size.w > 1 ? size.w : 1920
                editor.setClientSize(width: width, height: height)
            }
            // A first toast grows the surface to an estimate, because there is
            // no stack to measure until it has been laid out at a size it fits
            // in. Measure again once it has: this used to fall out of the next
            // D-Bus poll 50 ms later, and the poll no longer runs unasked.
            FrameTasks.after { [self] in syncSurface() }
        }
        syncInputRegion()
    }

    private func surfaceHeight() -> Float {
        let base = panelMetrics.surfaceHeight
        guard !toastIds.isEmpty else { return base }
        let estimate = panelMetrics.reserved + 16 + Float(toastIds.count) * 180
        guard appliedHeight + 1 >= estimate,
              let frame = toastFrame(), frame.h > 40
        else { return max(appliedHeight, estimate) }
        return max(base, Float(frame.y) + Float(frame.h) + 8)
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
        // The bar itself — not its margins, and not the shadow under it, which
        // falls over windows that should still take those clicks. The length
        // is the surface's; before the first frame, a constant the
        // compositor clamps.
        let bar = barFrame()
        var region = [InputRect(
            x: Int32(bar.x.rounded(.down)), y: Int32(bar.y.rounded(.down)),
            w: UInt32(bar.w.rounded(.up)), h: UInt32(bar.h.rounded(.up))
        )]
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

    /// The bar as laid out, or where the metrics put it before the first
    /// layout — at a length the compositor clamps.
    private func barFrame() -> (x: Float, y: Float, w: Float, h: Float) {
        if let frame = LavaApp.mainLayoutHost?.agentFrame(sid: "panel.bar"),
           frame.w > 0, frame.h > 0 {
            return (frame.x, frame.y, frame.w, frame.h)
        }
        let length = editor?.framebufferSize().w ?? 0
        return panelMetrics.barFrame(surfaceWidth: length > 1 ? length : 8192)
    }

    /// The bar was laid out somewhere new — the first layout, or the screen
    /// changed size. The input region follows it, a frame later, once the
    /// layout that moved it has been committed.
    func barMoved() {
        FrameTasks.after { [self] in syncInputRegion() }
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

    @ObservationIgnored private var appliedHeight: Float = panelMetrics.surfaceHeight
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
let network = NetworkSession()
let bluetooth = BluetoothSession()

/// Every popover on the panel — menubar dropdown, tray menu, volume,
/// calendar — wears this, so a theme change retints all of them and a
/// frost/radius tweak is not four call sites.
enum PanelChrome {
    static var style: MenuBarStyle { .panel() }

    /// The bar's menu titles: chips the height of every other control on it,
    /// round-ended, with the system menu's flame on an accent disc.
    static func barStyle(metrics: PanelMetrics, palette: PanelPalette) -> MenuBarStyle {
        var style = MenuBarStyle.panel()
        let chip = metrics.control
        style.titleHeight = chip
        style.titlePadding = EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10)
        style.titleCornerRadius = chip / 2
        // Brighter than the other chips': the design's menu titles take
        // white at 65% under the pointer and 75% while open.
        style.titleHover = palette.chipOpen
        style.titleOpenFill = palette.menuOpen
        // The design keeps an open title's text as it was; the white chip
        // under it is what says it is open.
        style.titleOpenText = palette.text
        return style
    }

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

    /// Magnification factor for the popup's glass effect, controlling how much
    /// the background is scaled when the popup is displayed.
    static let popupMagnification: Float = 1.35
}

struct PanelView: View {
    /// The flame, white, for the accent disc the system menu sits on.
    let brandIcon: UIImage
    let brandImage: UIImage
    let fonts: PanelFonts
    /// Running text in the About card. Open Sans at the UI size is a label
    /// face; this is a paragraph, so it gets a reading face at 14px.
    let bodyFont: UIFont

    var body: some View {
        let metrics = panelMetrics
        let palette = PanelPalette.current
        // The bar is what paints; the rest of the surface is transparent. It
        // is deeper than the bar for two things that fall over the windows
        // below — the bar's shadow, and a notification stack — and the input
        // region is the bar plus the cards, nothing else.
        //
        // `spacing: 0` is load-bearing. The theme default is 8px, and a gap
        // here would move the bar off the margin `reserved` was computed for.
        return VStack(flexGrow: 1, padding: 0, spacing: 0) {
            bar(metrics: metrics, palette: palette)
                .padding(EdgeInsets(top: metrics.marginTop, leading: metrics.marginSide,
                                    bottom: 0, trailing: metrics.marginSide))

            // Where the notification stack goes, pinned to the top right
            // under the bar. Never painted.
            HStack(flexGrow: 1, padding: 0, alignment: .start) {
                Spacer()
                if let notifications, !notifications.toasts.isEmpty {
                    ToastStack(notifications: notifications)
                        .padding(EdgeInsets(top: 8, leading: 0, bottom: 0,
                                            trailing: 10 + metrics.marginSide))
                }
            }
        }
    }

    private func bar(metrics: PanelMetrics, palette: PanelPalette) -> some View {
        HStack(height: .pt(metrics.barHeight), padding: 0, alignment: .center, spacing: 6) {
            // The flame starts the launcher. It used to be the system menu;
            // what was on it is where the design puts it now — About under
            // Help, the session under the power button.
            LavaButton(icon: brandIcon, metrics: metrics, palette: palette)

            MenuBarStrip(
                model: session.model,
                openMenuID: openBinding,
                onActivate: { session.activate($0) },
                style: PanelChrome.barStyle(metrics: metrics, palette: palette),
                externalMenus: true
            )
            .font(fonts.label)

            // What is playing, after the menus. The workspace dots used to
            // sit here, and every application's menus are a different width,
            // so switching workspace moved the dots out from under the
            // pointer that had just clicked them.
            if mpris.present {
                Canvas(label: "divider", width: .pt(13), height: .pt(18)) { list, frame in
                    list.rect(x: frame.x + 6, y: frame.y, w: 1, h: frame.h,
                              color: palette.divider)
                }
                NowPlayingChip(mpris: mpris, metrics: metrics, palette: palette, fonts: fonts)
            }

            // Pushes the rest to the far end: an empty growing child is the
            // spacer, since the stack distributes leftover space by flex.
            HStack(flexGrow: 1, padding: 0) {}

            // At the right, where nothing before them changes width with
            // the focused window.
            WorkspaceDots(workspaces: session.workspaceDots, metrics: metrics, palette: palette)

            trayStrip(palette: palette, metrics: metrics)

            // Bluetooth, network and sound: Bluetooth only with an adapter,
            // network only while NetworkManager is there to ask.
            TrayCluster(metrics: metrics, palette: palette)

            ClockChip(date: clock.date, time: clock.time, metrics: metrics,
                      palette: palette, fonts: fonts)
            PowerButton(metrics: metrics, palette: palette)
        }
        .padding(.horizontal, 3)
        .background(palette.glass)
        .border(metrics.style == .floating ? palette.glassBorder : .clear)
        .cornerRadius(metrics.radius)
        .backdropBlur(radius: 22, adaptation: 0, saturation: 1.7)
        // Over the bar, not under it. The frost is a compositor plate *and* an
        // in-window blur of whatever this surface drew first (`withBlurScope`),
        // and an underlay is drawn first: the shadow round the bar was blurred
        // back into the glass as a grey band along its edges. CSS's
        // `backdrop-filter` never sees its own element's `box-shadow`. A hollow
        // shadow has nothing inside the bar to cover it with, so on top it
        // looks the same and is drawn after the capture.
        .overlayLayer {
            Canvas(label: "bar-shadow", width: .pct(100), height: .pct(100)) { list, frame in
                // The layer covers the box the margins are padding *inside*
                // (`.padding` lands on this node, not on a wrapper), so the
                // bar is that box less the margins — and the caster has to be
                // the bar, or the hole is cut at the wrong place.
                list.shadow(x: frame.x + metrics.marginSide, y: frame.y + metrics.marginTop,
                            w: frame.w - 2 * metrics.marginSide,
                            h: frame.h - metrics.marginTop, cornerRadius: metrics.radius,
                            blur: metrics.shadowBlur,
                            color: palette.shadow.opacity(metrics.shadowAlpha),
                            offsetY: metrics.shadowOffset, hollow: true)
                // Docked, the strip has no rim of its own; a light line along
                // its bottom edge is what parts it from a window under it
                // (the design's `0 1px 0 rgba(255,255,255,.5)`).
                if metrics.style == .docked {
                    list.rect(x: frame.x, y: frame.y + frame.h, w: frame.w, h: 1,
                              color: palette.glassBorder)
                }
            }
        }
        .onFrame { _ in session.barMoved() }
        .agentId("panel.bar")
    }

    /// StatusNotifier icons, left of the clock. Empty when no items or when
    /// another process owns the watcher.
    @ViewBuilder
    private func trayStrip(palette: PanelPalette, metrics: PanelMetrics) -> some View {
        let items = tray?.items ?? []
        if !items.isEmpty {
            // A capsule of their own beside the system one, drawn the same
            // way: other programs' icons, kept apart from the panel's own
            // so the cluster that is always there does not change width
            // when an applet comes and goes.
            let size = metrics.control - 4
            HStack(padding: 0, alignment: .center, spacing: 2) {
                ForEach(items) { item in
                    trayIcon(item, palette: palette, size: size)
                }
            }
            .padding(2)
            .background(palette.chip)
            .cornerRadius((size + 4) / 2)
            .agentId("tray.apps")
        }
    }

    @ViewBuilder
    private func trayIcon(
        _ item: StatusNotifierTray.TrayItem, palette: PanelPalette, size: Float
    ) -> some View {
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
            // Fixed size so a large IconPixmap does not blow the bar height;
            // the same disc the built-in tray glyphs sit on. 18 on 22: these
            // are pictures, not strokes, and at 16 an app's logo is mush.
            if let path = item.iconPath {
                Image(path: path, width: .pt(size - 4), height: .pt(size - 4),
                      contentMode: .fit)
                    .padding(2)
            } else if let image = item.image {
                Image(
                    image,
                    width: .pt(size - 4), height: .pt(size - 4),
                    contentMode: .fit
                )
                .padding(2)
            } else {
                Text(item.fallback, color: palette.text)
                    .padding(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
            }
        }
        .hoverBackground(palette.chipOpen)
        .cornerRadius(size / 2)
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

/// About Lava: the artwork, the name, and the story, on the cards' glass.
struct AboutWindow: View {
    var image: UIImage
    var font: UIFont

    static let width: Float = 480
    static let padding: Float = 16
    /// A first guess; the card measures itself and the popup follows.
    static let height: Float = 560

    var body: some View {
        let palette = PopupPalette.current
        let fonts = popupFonts!
        let artW = Self.width - Self.padding * 2
        return FittedCard(padding: Self.padding) {
            // The artwork, cut to the card's inner curve.
            Image(image, width: .pt(artW), height: .pt(artW * 2 / 3), contentMode: .fill)
                .cornerRadius(Self.radius)
            HStack(padding: 0, alignment: .end, spacing: 10) {
                Text("Lava", color: palette.bar.text, font: fonts.heading22)
                Text("A desktop environment", color: palette.bar.textSoft, font: fonts.small13)
                    .padding(EdgeInsets(top: 0, leading: 0, bottom: 3, trailing: 0))
                Spacer()
                TagLabel(text: "Wayland · Vulkan", tone: .sage)
                    .padding(EdgeInsets(top: 0, leading: 0, bottom: 2, trailing: 0))
            }
            .padding(EdgeInsets(top: 14, leading: 4, bottom: 8, trailing: 4))
            Text(
                "Lava is a free and open-source desktop environment. " +
                "It is designed to be fast, lightweight, and ready to use from the initial launch " +
                "— no tinkering with the config is needed. It is built by Claude, Grok and ChatGPT " +
                "for Nikita to use. During his life, Nikita has always struggled with computers and " +
                "particularly with Linux Desktop Environments. He has tried many, but none of them " +
                "have been able to provide him with the experience he desires. Then one day, he decided " +
                "to have Claude build him a new desktop environment, and thus Lava was born, and now " +
                "Nikita is not struggling with computers anymore, and he is happy.",
                color: palette.bar.textSoft, font: font
            )
            .padding(EdgeInsets(top: 0, leading: 4, bottom: 4, trailing: 4))
        }
        .agentId("dialog.about")
    }

    /// The card's 24, less its padding: concentric with the card's corner.
    static var radius: Float { 24 - padding / 2 }
}

/// Asks before ending something — log out, restart, shut down — or says why
/// it did not happen. Destructive actions take a second click here, after
/// the session card has closed.
struct SessionWindow: View {
    static let width: Float = 380
    static let padding: Float = 20
    /// A first guess; the card measures itself and the popup follows.
    static let height: Float = 220

    var body: some View {
        let palette = PopupPalette.current
        let fonts = popupFonts!
        let isError = session.dialog == .powerError
        let powerOff = session.dialog == .powerOff
        let restart = session.dialog == .restart
        let heading = isError ? session.powerErrorTitle
            : powerOff ? "Shut down?" : restart ? "Restart?" : "Log out?"
        let detail = isError ? session.powerError
            : powerOff
                ? "This turns off the computer and closes every window. Save your work before continuing."
            : restart
                ? "This restarts the computer and closes every window. Save your work before continuing."
                : "This ends the session and closes every window."
        let glyph = isError ? MenuGlyphs.info
            : powerOff ? MenuGlyphs.power : restart ? MenuGlyphs.restart : MenuGlyphs.logout
        let verb = powerOff ? "Shut down" : restart ? "Restart" : "Log out"

        return FittedCard(padding: Self.padding) {
            HStack(padding: 0, alignment: .start, spacing: 14) {
                IconDisc(icon: [.path(glyph)], size: 40, glyph: 18,
                         fill: palette.bar.accentSoft, color: palette.bar.accentInk,
                         strokeWidth: 2.25)
                VStack(flexGrow: 1, padding: 0, spacing: 6) {
                    Text(heading, color: palette.bar.text, font: fonts.heading19)
                    Text(detail, color: palette.bar.textSoft, font: fonts.body14)
                }
                .padding(EdgeInsets(top: 2, leading: 0, bottom: 0, trailing: 0))
            }
            HStack(padding: 0, alignment: .center, spacing: 8) {
                Spacer()
                PillButton(title: isError ? "Close" : "Cancel",
                           agentId: "dialog.session.cancel") {
                    session.setDialog(.none)
                }
                if !isError {
                    PillButton(title: verb, prominent: true, isEnabled: !session.powerBusy,
                               agentId: "dialog.session.confirm") {
                        if powerOff {
                            session.requestPower(.powerOff)
                        } else if restart {
                            session.requestPower(.reboot)
                        } else {
                            session.setDialog(.none)
                            LavaClient.endSession()
                        }
                    }
                }
            }
            .padding(EdgeInsets(top: 18, leading: 0, bottom: 0, trailing: 0))
        }
        .agentId(powerOff ? "dialog.power-off" : restart ? "dialog.restart"
                 : isError ? "dialog.power-error" : "dialog.logout")
    }
}

// ─── Desktop actions ─────────────────────────────────────────────────────────

/// Starts a sibling desktop program the way the compositor starts the
/// panel: look beside this binary first (tree build / installed layout),
/// then fall through to PATH.
func launchDesktopProgram(_ name: String, arguments: [String] = []) {
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
            process.arguments = arguments
        } else {
            // Let the shell resolve PATH for a bare name.
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [path] + arguments
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
        Data("LavaPanel: could not launch \(name)\n".utf8)
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
    thickness: panelMetrics.surfaceHeight, reserve: true,
    reserved: panelMetrics.reserved
) else { exit(1) }

guard let brandImage = ImageStore.loadAsset(
    named: "lavaui.png", bundle: .module, into: editor
) else {
    FileHandle.standardError.write(
        Data("LavaPanel: could not load lavaui.png\n".utf8)
    )
    exit(1)
}

// Owns the registrar from here on, so an application starting after this point
// finds somewhere to export to. Before `run`, because an app that registers
// while the panel is still coming up should not have to try twice.
session.attach(editor: editor)
mpris.onAbsent = { session.closePlayer() }
network.onPrompt = { session.openAuth($0) }
network.onPromptGone = { session.dropAuth($0) }
bluetooth.onPrompt = { session.openPairing($0) }
bluetooth.onPromptGone = { session.dropPairing($0) }

// One face, loaded once. Building it inside `body` would reopen FreeType
// every clock tick, and a face that is never `registerWithEngine`'d
// measures at 64px while the compositor rasterizes font id 0 — the
// default 16px — which is the widely spaced "S e t t i n g s" look.
guard let panelFonts = PanelFonts.load(into: editor) else {
    FileHandle.standardError.write(
        Data("LavaPanel: could not load Figtree from LavaUI's fonts\n".utf8)
    )
    exit(1)
}

guard let loadedPopupFonts = PopupFonts.load(into: editor) else {
    FileHandle.standardError.write(
        Data("LavaPanel: could not load the popups' faces from LavaUI's fonts\n".utf8)
    )
    exit(1)
}
popupFonts = loadedPopupFonts

// The flame, white, for the lava button's accent disc.
guard let flameIcon = ImageStore.loadAsset(named: "flame.svg", bundle: .module, into: editor)
else {
    FileHandle.standardError.write(Data("LavaPanel: could not load flame.svg\n".utf8))
    exit(1)
}

guard let bodyFont = loadReadingFace(pixelSize: 14) else {
    FileHandle.standardError.write(
        Data("LavaPanel: could not load body face\n".utf8)
    )
    exit(1)
}
bodyFont.registerWithEngine(editor)
if let codeFont = loadReadingFace(pixelSize: 30) {
    codeFont.registerWithEngine(editor)
    session.codeFont = codeFont
}
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
// Workspaces for the empty bar's menu. The first answer is the state now.
LavaClient.onWindowList { current, windows in
    session.setWorkspaces(current, windows)
}
if let keyboard = try? DesktopSettings.keyboard() {
    session.modKey = keyboard.modKey == "super" ? "super" : "alt"
    session.refreshDesktopBar()
}

LavaClient.onActiveWindow { window in
    session.focus(window)
}

Thread.detachNewThread {
    battery.poll()
    var second = 0
    while true {
        MainQueue.async { clock.tick() }
        Thread.sleep(forTimeInterval: 1.0)
        // The battery on the same thread: a few small file reads, and the
        // interval is read here so an open card speeds it up at once.
        second += 1
        if second >= battery.interval {
            second = 0
            battery.poll()
        }
    }
}

// DBus has no frame clock of its own, and the traffic goes both ways: this is
// what answers an application's `GetLayout` as much as what collects it. It
// used to run from a 50 ms timer, twenty wakeups a second to find nothing;
// `GLibPump` runs it when the bus actually delivers something. Same pump for
// the tray watcher — one GLib context for both.
GLibPump.add {
    session.poll()
    // Notifications ride the same context, and they need it for more than
    // delivery: an expiry is a clock nobody else is watching, so a stack that
    // stopped being polled would stay on screen forever. That is why this
    // says when it next has to run — the pump sleeps until then if nothing
    // else arrives.
    if notifications?.poll() == true {
        session.setToasts(notifications?.toasts ?? [])
    }
    return notifications?.nextExpiryMs
}

// Before any menu is opened. The compositor refuses `OpenMenu` for a
// surface that is not listening — a grab whose answer would go nowhere.
LavaClient.onMenuChoice { serial, chosen in
    session.menuChosen(serial: serial, chosen: chosen)
}

// A test lever: open popups by name once the bar has drawn, for screenshots
// of cards a headless session has no pointer to open — the agent port drives
// the bar's window only. `LAVA_PANEL_OPEN=calendar,year`; also `player`,
// `network`, `volume`, `bluetooth`, `power`, `battery`, `about`, `shutdown`,
// `restart`, `logout`. Each waits a frame for the one before.
if let names = ProcessInfo.processInfo.environment["LAVA_PANEL_OPEN"] {
    func openNext(_ rest: ArraySlice<Substring>, delay: Int) {
        guard let name = rest.first else { return }
        // Some frames in: the bar has to be laid out for an anchor to exist.
        FrameScheduler.requestRedraw(in: 0.05)
        FrameTasks.after {
            if delay > 0 { return openNext(rest, delay: delay - 1) }
            switch name {
            case "calendar": session.toggleCalendar()
            case "year": session.toggleYear()
            case "player": session.togglePlayer()
            case "network": session.toggleNetwork()
            case "volume": session.toggleVolume()
            case "bluetooth": session.toggleBluetooth()
            case "power": session.toggleSessionCard()
            case "battery": session.toggleBattery()
            case "about": session.openAbout()
            case "shutdown": session.setDialog(.powerOff)
            case "restart": session.setDialog(.restart)
            case "logout": session.setDialog(.logout)
            default: FileHandle.standardError.write(Data("LAVA_PANEL_OPEN: no '\(name)'\n".utf8))
            }
            openNext(rest.dropFirst(), delay: 10)
        }
    }
    openNext(names.split(separator: ",")[...], delay: 10)
}

LavaClient.run(editor: editor) {
    PanelView(
        brandIcon: flameIcon, brandImage: brandImage,
        fonts: panelFonts, bodyFont: bodyFont
    )
}
