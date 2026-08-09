#if canImport(CxxCanvas)
import CxxCanvas
import Foundation
import LavaMenu

/// Which code path owns the menubar.
public enum MenuBackendKind: Equatable, Sendable {
    /// In-window strip + overlays drawn by LavaUI.
    case vulkan
    /// System global menu via DBusMenu + AppMenu Registrar (Vala Panel, etc.).
    case dbusMenu
}

/// App-level menubar owner: retains `MenuController` and the active backend.
///
/// Backend selection (once at init, unless `LAVA_MENU` forces):
/// ```
/// LAVA_MENU=vulkan → always in-window
/// LAVA_MENU=dbus   → try DBusMenu, else vulkan
/// (unset / auto)   → DBusMenu if registrar + X11, else vulkan
/// ```
public final class MenuHost {
    /// The id to register this app's menu under, when the window is not an
    /// X11 one and has no id of its own to offer.
    ///
    /// Set by `LavaClient` to the compositor's surface id, before the first
    /// `MenuHost` exists. That number is what the compositor reports as
    /// focused, so it is the one a panel can match a menu to — and without it
    /// a client's menu could be exported but never *found*, which is why a
    /// client used to fall back to drawing its own strip.
    nonisolated(unsafe) public static var exportWindowId: UInt32 = 0

    public let controller = MenuController()
    public private(set) var backend: MenuBackendKind = .vulkan
    private let editor: Editor
    private var lastApplied: MenuModel?

    public init(editor: Editor) {
        self.editor = editor
        self.backend = Self.selectBackend(editor: editor)
        if backend == .dbusMenu {
            FileHandle.standardError.write(
                Data("LavaUI: menubar backend = dbusMenu (global panel)\n".utf8)
            )
        } else {
            FileHandle.standardError.write(
                Data("LavaUI: menubar backend = vulkan (in-window)\n".utf8)
            )
        }
    }

    /// Whether the in-window `MenuChromeRoot` strip should be composed.
    public var showsInWindowChrome: Bool {
        backend == .vulkan && !isEmpty
    }

    /// DBusMenu replies (GetLayout / AboutToShow / Event) only run when the
    /// GLib main context is iterated. The panel blocks on those calls — if we
    /// sit forever in `glfwWaitEvents` without pumping GLib, XFCE freezes.
    public var needsDBusPump: Bool { backend == .dbusMenu }

    /// Cap for `pumpEvents` idle wait while a global menu is exported (seconds).
    public static let dbusPumpInterval: Double = 0.02

    /// Rebuild IR from a menubar description. Pushes to DBus when that backend
    /// is active. Returns whether the platform-facing model changed.
    @discardableResult
    public func update(_ bar: MenuBar) -> Bool {
        let changed = controller.update(bar)
        if backend == .dbusMenu {
            // Always re-export when attached: actions may have changed even if
            // the Equatable model did not (same labels, new closures).
            if changed || lastApplied == nil {
                exportToDBus(model)
            }
        }
        if changed {
            lastApplied = model
        }
        return changed
    }

    @discardableResult
    public func update(@MenuBarBuilder _ content: () -> [Menu]) -> Bool {
        update(MenuBar(content: content))
    }

    @discardableResult
    public func activate(_ id: MenuID) -> Bool {
        guard let item = controller.model.item(id: id) else {
            return invalidating(controller.activate(id))
        }
        guard item.isEnabled else { return false }
        return invalidating(controller.activate(id))
    }

    @discardableResult
    public func activate(
        matchingKey key: Int32,
        mods: Int32
    ) -> Bool {
        invalidating(controller.activate(matchingKey: key, mods: mods))
    }

    /// A menu action is a repaint request, for the same reason a click is: the
    /// handler exists to change something, and a handler that mutates an
    /// `@Observable` model invalidates nothing by itself unless some body read
    /// that property. Panel activations arrive from `poll()`, outside any input
    /// event, so without this a global-menu action could sit unpainted
    /// indefinitely — the window is idle and nothing else asks for a frame.
    private func invalidating(_ activated: Bool) -> Bool {
        if activated { ViewInvalidation.markNeedsRedraw() }
        return activated
    }

    /// Pump GLib/DBus and run any panel activations. Call once per frame.
    public func poll() {
        guard backend == .dbusMenu else { return }
        editor.appMenuPoll()
        while true {
            let id = editor.appMenuPopActivation()
            if id.isEmpty { break }
            activate(MenuID(id))
        }
    }

    public var model: MenuModel { controller.model }

    public var isEmpty: Bool { model.menus.isEmpty }

    /// Default strip height in layout pixels (Vulkan backend only).
    public static let barHeight: Float = 30

    // MARK: - Backend selection

    private static func selectBackend(editor: Editor) -> MenuBackendKind {
        let forced = ProcessInfo.processInfo.environment["LAVA_MENU"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if forced == "vulkan" {
            return .vulkan
        }
        let preferDBus = forced == "dbus" || forced == "auto" || forced == nil || forced == ""
        guard preferDBus else { return .vulkan }

        guard Editor.appMenuRegistrarAvailable() else {
            if forced == "dbus" {
                FileHandle.standardError.write(
                    Data("LavaUI: LAVA_MENU=dbus but no AppMenu registrar; using vulkan\n".utf8)
                )
            }
            return .vulkan
        }
        // An X11 window registers itself; a compositor client has no X11 id
        // and registers under the surface id the panel knows it by. Tried in
        // that order rather than either/or, because a windowed app on X11 has
        // both a real id and (if it is also a client, which it is not) nothing
        // to gain from the second.
        let attached = editor.appMenuAttach()
            || (exportWindowId != 0 && editor.appMenuAttach(windowId: exportWindowId))
        guard attached else {
            if forced == "dbus" {
                FileHandle.standardError.write(
                    Data("LavaUI: LAVA_MENU=dbus but attach failed; using vulkan\n".utf8)
                )
            }
            return .vulkan
        }
        return .dbusMenu
    }

    // MARK: - DBus export

    private func exportToDBus(_ model: MenuModel) {
        editor.appMenuBeginUpdate()
        for menu in model.menus {
            exportNode(menu)
        }
        editor.appMenuCommitUpdate()
    }

    private func exportNode(_ node: MenuNode) {
        editor.appMenuBeginMenu(id: node.id.raw, title: node.title)
        for entry in node.items {
            switch entry {
            case .separator:
                editor.appMenuAddSeparator()
            case .item(let item):
                let checked: Int32
                if let c = item.isChecked {
                    checked = c ? 1 : 0
                } else {
                    checked = -1
                }
                editor.appMenuAddItem(
                    id: item.id.raw,
                    title: item.title,
                    enabled: item.isEnabled,
                    checked: checked
                )
            case .submenu(let sub):
                exportNode(sub)
            }
        }
        editor.appMenuEndMenu()
    }
}

#endif
