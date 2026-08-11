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
        let current = editor.statusNotifierRevision
        guard current != revision else { return false }
        revision = current
        rebuild()
        return true
    }

    public func activate(_ item: TrayItem) {
        if item.isMenu {
            editor.statusNotifierContextMenu(item.key)
        } else {
            editor.statusNotifierActivate(item.key)
        }
    }

    public func contextMenu(_ item: TrayItem) {
        editor.statusNotifierContextMenu(item.key)
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
