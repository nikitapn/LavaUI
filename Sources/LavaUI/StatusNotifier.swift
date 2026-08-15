import Foundation
import Observation

/// System tray host: owns `org.kde.StatusNotifierWatcher` and surfaces items
/// for a panel strip.
///
/// Pair of `PanelMenu` for global menus. The heavy lifting is in canvas
/// (`StatusNotifierHost`); this is the Swift view-model — poll, rebuild a
/// list of `TrayItem`s with uploaded textures, and forward clicks.
@Observable
public final class StatusNotifierTray {
    public struct TrayItem: Identifiable {
        public var id: String { key }
        public var key: String
        public var title: String
        public var status: String
        public var isMenu: Bool
        /// Exports a DBusMenu the panel can draw.
        public var hasMenu: Bool
        /// A left click should open that menu rather than call `Activate`.
        public var prefersMenu: Bool
        /// Drawn when non-nil; otherwise the panel shows a letter fallback.
        public var image: UIImage?
        /// Single character when there is no icon.
        public var fallback: String
    }

    private let editor: Editor
    private var revision: UInt64 = 0
    /// Last uploaded pixmap key → texture, so we do not re-upload every poll.
    private var pixmapKeys: [String: String] = [:]

    public private(set) var isServing = false
    public private(set) var items: [TrayItem] = []

    public init(editor: Editor) {
        self.editor = editor
        isServing = editor.statusNotifierStart()
        if isServing {
            // Own vs follow is logged from canvas; both are live trays.
            FileHandle.standardError.write(
                Data("LavaUI: StatusNotifier tray active\n".utf8)
            )
        } else {
            FileHandle.standardError.write(
                Data("LavaUI: StatusNotifier tray unavailable (no session bus)\n".utf8)
            )
        }
    }

    /// Pump D-Bus and rebuild `items` when something changed.
    @discardableResult
    public func poll() -> Bool {
        guard isServing else { return false }
        editor.statusNotifierPoll()

        var changed = false
        // The open menu first, and separately: an applet answering the layout
        // we just asked for changes nothing about the icon strip, and the item
        // revision would not move for it. This is what fills a menu that was
        // empty when it opened, a frame or two ago.
        if openMenuKey != nil {
            let menuNow = editor.statusNotifierMenuRevision
            if menuNow != menuRevision {
                menuRevision = menuNow
                menuEntries = buildEntries()
                changed = true
            }
        }

        let current = editor.statusNotifierRevision
        if current != revision {
            revision = current
            rebuild()
            // An applet that went away takes its open menu with it.
            if let key = openMenuKey, !items.contains(where: { $0.key == key }) {
                closeMenu()
            }
            changed = true
        }
        return changed
    }

    /// A left click.
    ///
    /// `Activate` when the item implements it, and its menu when it does not
    /// — which is not a fallback but the normal case: everything built on
    /// libappindicator (nm-applet, most GTK applets) implements no methods at
    /// all and publishes a `Menu` object instead. Calling `Activate` on one of
    /// those is a message to nobody, which is exactly what clicking the icon
    /// used to do.
    ///
    /// Returns true when a menu was opened, so the caller can show it.
    @discardableResult
    public func activate(_ item: TrayItem) -> Bool {
        if item.prefersMenu { return openMenu(item) }
        editor.statusNotifierActivate(item.key)
        return false
    }

    /// A right click: the menu if there is one, `ContextMenu` otherwise —
    /// some applets implement the call and export nothing to render.
    @discardableResult
    public func contextMenu(_ item: TrayItem) -> Bool {
        if item.hasMenu { return openMenu(item) }
        editor.statusNotifierContextMenu(item.key)
        return false
    }

    /// The item whose menu is open, and its contents.
    ///
    /// One at a time: a tray menu is a popup, and the pointer that opens a
    /// second one closed the first.
    public private(set) var openMenuKey: String?
    public private(set) var menuEntries: [MenuEntry] = []
    private var menuRevision: UInt64 = 0

    @discardableResult
    public func openMenu(_ item: TrayItem) -> Bool {
        guard item.hasMenu, editor.statusNotifierOpenMenu(item.key) else {
            return false
        }
        openMenuKey = item.key
        menuRevision = 0
        // Usually empty right here: the applet is being asked for its layout
        // and answers over the bus. `poll` fills it in, within a frame or two.
        menuEntries = buildEntries()
        return true
    }

    public func closeMenu() {
        guard openMenuKey != nil else { return }
        openMenuKey = nil
        menuEntries = []
        editor.statusNotifierCloseMenu()
    }

    /// Runs an item in the applet that owns it.
    public func activateMenuItem(_ id: MenuID) {
        guard let itemId = Int32(id.raw) else { return }
        editor.statusNotifierMenuActivate(itemId)
    }

    /// "This submenu is about to open" — applets are allowed to fill one only
    /// when asked.
    public func aboutToShow(_ id: MenuID) {
        guard let itemId = Int32(id.raw) else { return }
        editor.statusNotifierMenuAboutToShow(itemId)
    }

    private func buildEntries() -> [MenuEntry] {
        ImportedMenu.rootEntries(
            count: editor.statusNotifierMenuItemCount,
            item: { editor.statusNotifierMenuItem($0) }
        )
    }

    public func scroll(_ item: TrayItem, delta: Int32) {
        editor.statusNotifierScroll(item.key, delta: delta)
    }

    private func rebuild() {
        let count = editor.statusNotifierItemCount
        var next: [TrayItem] = []
        next.reserveCapacity(count)
        var liveKeys = Set<String>()

        for i in 0..<count {
            let info = editor.statusNotifierItem(i)
            liveKeys.insert(info.key)
            let image = resolveImage(info)
            let label = info.title.isEmpty
                ? (info.id.isEmpty ? "?" : info.id)
                : info.title
            let fallback: String = {
                if let c = label.unicodeScalars.first,
                   CharacterSet.letters.contains(c) || CharacterSet.decimalDigits.contains(c)
                {
                    return String(c).uppercased()
                }
                return "·"
            }()
            next.append(TrayItem(
                key: info.key,
                title: label,
                status: info.status,
                isMenu: info.isMenu,
                hasMenu: info.hasMenu,
                prefersMenu: info.prefersMenu,
                image: image,
                fallback: fallback
            ))
        }

        // Drop pixmap cache entries for gone items so textures can age out.
        pixmapKeys = pixmapKeys.filter { liveKeys.contains($0.key) }
        items = next
    }

    private func resolveImage(_ info: StatusNotifierItemInfo) -> UIImage? {
        // Prefer a theme file we resolved on the C++ side.
        if !info.iconPath.isEmpty,
           let img = ImageStore.load(path: info.iconPath, into: editor)
        {
            return img
        }
        // Raw IconPixmap from the bus.
        if info.iconWidth > 0, info.iconHeight > 0,
           info.iconRgba.count >= info.iconWidth * info.iconHeight * 4
        {
            let cacheKey =
                "sni-pixmap:\(info.key):\(info.iconWidth)x\(info.iconHeight):\(info.iconRgba.count)"
            if let img = editor.uploadImage(
                key: cacheKey,
                path: info.key,
                pixels: info.iconRgba,
                width: UInt32(info.iconWidth),
                height: UInt32(info.iconHeight)
            ) {
                pixmapKeys[info.key] = cacheKey
                return img
            }
        }
        return nil
    }
}
