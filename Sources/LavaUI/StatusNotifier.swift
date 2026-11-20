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
    /// One tray icon, ready to draw.
    public struct TrayItem: Identifiable {
        /// The item's identity, which is its `key`.
        public var id: String { key }
        /// `uniqueName/objectPath` on the session bus; what every call about the item takes.
        public var key: String
        /// The item's tooltip or display title.
        public var title: String
        /// `"Passive"`, `"Active"` or `"NeedsAttention"`.
        public var status: String
        /// Whether the item says a left click should open its menu (`ItemIsMenu`).
        public var isMenu: Bool
        /// Exports a DBusMenu the panel can draw.
        public var hasMenu: Bool
        /// A left click should open that menu rather than call `Activate`.
        public var prefersMenu: Bool
        /// The icon theme's file for it, when there is one: drawn with
        /// `Image(path:)`, which decodes at the size it is drawn — an SVG
        /// rasterised there, a 48px PNG resampled down properly — rather than
        /// at the file's own size and shrunk by the GPU.
        public var iconPath: String?
        /// The item's own pixels (`IconPixmap`), already brought down to
        /// `iconPixels`, when it has no theme file. With neither, the panel
        /// shows a letter fallback.
        public var image: UIImage?
        /// Single character when there is no icon.
        public var fallback: String
    }

    private let editor: Editor
    private var revision: UInt64 = 0
    /// The longest edge an `IconPixmap` is uploaded at. Electron apps send
    /// 256px pictures, and drawn at 18 the GPU's one bilinear tap from that
    /// far away is a speckle; averaged down here first, the GPU is left at
    /// most a 2:1 step. Twice the drawn size, so a 2× screen is native.
    public var iconPixels = 36
    /// Last uploaded pixmap key → texture, so we do not re-upload every poll.
    private var pixmapKeys: [String: String] = [:]

    /// Whether the tray is live: owning `org.kde.StatusNotifierWatcher`, or
    /// following the one another desktop owns.
    public private(set) var isServing = false
    /// The tray items, in the order the host lists them.
    public private(set) var items: [TrayItem] = []

    /// Starts the tray through `editor`: owns the watcher name if it is free,
    /// follows the existing one otherwise.
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
    /// Rows of the open menu. Empty until the applet answers, which `poll()` picks up.
    public private(set) var menuEntries: [MenuEntry] = []
    private var menuRevision: UInt64 = 0

    /// Opens `item`'s menu. Returns `false` if it exports none — activate it instead.
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

    /// Closes the open tray menu. The applet is not told.
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

    /// Sends the item `delta` vertical scroll steps.
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
            let iconPath = info.iconPath.isEmpty ? nil : info.iconPath
            let image = iconPath == nil ? resolveImage(info) : nil
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
                iconPath: iconPath,
                image: image,
                fallback: fallback
            ))
        }

        // Drop pixmap cache entries for gone items so textures can age out.
        pixmapKeys = pixmapKeys.filter { liveKeys.contains($0.key) }
        items = next
    }

    /// The item's `IconPixmap`, averaged down to `iconPixels` and uploaded.
    private func resolveImage(_ info: StatusNotifierItemInfo) -> UIImage? {
        if info.iconWidth > 0, info.iconHeight > 0,
           info.iconRgba.count >= info.iconWidth * info.iconHeight * 4
        {
            let (pixels, w, h) = Self.areaDownscale(
                info.iconRgba, width: info.iconWidth, height: info.iconHeight,
                maxEdge: iconPixels
            )
            let cacheKey =
                "sni-pixmap:\(info.key):\(info.iconWidth)x\(info.iconHeight):\(info.iconRgba.count)@\(w)"
            if let img = editor.uploadImage(
                key: cacheKey,
                path: info.key,
                pixels: pixels,
                width: UInt32(w),
                height: UInt32(h)
            ) {
                pixmapKeys[info.key] = cacheKey
                return img
            }
        }
        return nil
    }

    /// Straight RGBA shrunk so its longer edge is at most `maxEdge`, by
    /// averaging every source pixel each output pixel covers — weighted by
    /// alpha, so the transparent margin round an icon does not darken its
    /// edge. Returned unchanged when it is already small enough.
    static func areaDownscale(
        _ rgba: [UInt8], width: Int, height: Int, maxEdge: Int
    ) -> ([UInt8], Int, Int) {
        let long = max(width, height)
        guard maxEdge > 0, long > maxEdge else { return (rgba, width, height) }
        let scale = Double(maxEdge) / Double(long)
        let ow = max(1, Int((Double(width) * scale).rounded()))
        let oh = max(1, Int((Double(height) * scale).rounded()))
        var out = [UInt8](repeating: 0, count: ow * oh * 4)
        let sx = Double(width) / Double(ow), sy = Double(height) / Double(oh)
        for oy in 0..<oh {
            let y0 = Double(oy) * sy, y1 = y0 + sy
            for ox in 0..<ow {
                let x0 = Double(ox) * sx, x1 = x0 + sx
                var r = 0.0, g = 0.0, b = 0.0, a = 0.0, area = 0.0
                for y in Int(y0)..<min(height, Int(y1.rounded(.up))) {
                    let wy = min(Double(y + 1), y1) - max(Double(y), y0)
                    guard wy > 0 else { continue }
                    for x in Int(x0)..<min(width, Int(x1.rounded(.up))) {
                        let wx = min(Double(x + 1), x1) - max(Double(x), x0)
                        guard wx > 0 else { continue }
                        let w = wx * wy
                        let i = (y * width + x) * 4
                        let alpha = Double(rgba[i + 3]) / 255
                        r += Double(rgba[i]) * alpha * w
                        g += Double(rgba[i + 1]) * alpha * w
                        b += Double(rgba[i + 2]) * alpha * w
                        a += alpha * w
                        area += w
                    }
                }
                let o = (oy * ow + ox) * 4
                guard area > 0, a > 0 else { continue }
                out[o] = UInt8(min(255, (r / a).rounded()))
                out[o + 1] = UInt8(min(255, (g / a).rounded()))
                out[o + 2] = UInt8(min(255, (b / a).rounded()))
                out[o + 3] = UInt8(min(255, (a / area * 255).rounded()))
            }
        }
        return (out, ow, oh)
    }
}
