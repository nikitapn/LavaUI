#if canImport(CxxCanvas)
import Foundation
import LavaMenu

/// The global menu, from a panel's side: the focused window's menu, imported
/// over DBusMenu and turned into the same `MenuModel` an app's own menubar is.
///
/// `MenuHost` is the mirror of this — what an application does to *publish* a
/// menu — and the two never meet in one process except by coincidence. What
/// they share is the model: once imported, another application's menu is an
/// ordinary `MenuModel`, which is what lets a panel draw it with `MenuBarStrip`
/// rather than growing a second menu renderer that would drift from the first.
///
/// Activation goes back the way it came. A `MenuID` here is a DBusMenu item id
/// in a string, so activating one is a lookup and a `clicked` event to the
/// application that owns the menu — nothing runs in the panel, which owns none
/// of these actions and could not run them if it wanted to.
public final class PanelMenu {
    private let editor: Editor
    /// Last imported revision, so a poll that changed nothing costs a compare.
    private var revision: UInt64 = 0
    private var lastWindow: UInt32 = 0

    /// The imported menu. Empty when nothing is focused, when the focused
    /// window exported no menu, or before the layout has arrived.
    public private(set) var model = MenuModel()

    /// Whether this panel is serving a registrar at all. False means no bus,
    /// or every registrar name already taken — see `Editor.menuImportStart`.
    public private(set) var isServing = false

    /// Which registrar name is owned. `com.canonical.AppMenu.Registrar` also
    /// picks up Qt and GTK applications; the lava-specific fallback picks up
    /// only LavaUI ones.
    public var busName: String { editor.menuImportBusName }

    public init(editor: Editor) {
        self.editor = editor
        isServing = editor.menuImportStart()
        if isServing {
            FileHandle.standardError.write(
                Data("LavaUI: global menu registrar = \(busName)\n".utf8)
            )
        } else {
            FileHandle.standardError.write(
                Data("LavaUI: no menu registrar; the panel shows no menus\n".utf8)
            )
        }
    }

    /// Show this window's menu. Cheap to call with an unchanged id.
    public func setActiveWindow(_ surfaceId: UInt32) {
        guard isServing, surfaceId != lastWindow else { return }
        lastWindow = surfaceId
        editor.menuImportSetActiveWindow(surfaceId)
    }

    /// Pumps DBus and rebuilds the model when the far side changed it.
    ///
    /// Returns true when `model` is different from the last time it did, which
    /// is the panel's signal to rebuild its view — and, more to the point, its
    /// signal *not* to, on the overwhelming majority of frames where a menu
    /// sits still.
    @discardableResult
    public func poll() -> Bool {
        guard isServing else { return false }
        editor.menuImportPoll()
        let current = editor.menuImportRevision
        guard current != revision else { return false }
        revision = current
        model = buildModel()
        return true
    }

    /// Runs an item in the application that owns it.
    ///
    /// The `MenuID` is a DBusMenu id in a string — see `menuID(for:)`. An id
    /// from a menu that has since been replaced simply resolves to nothing,
    /// which is the right answer: the item the user clicked is gone.
    public func activate(_ id: MenuID) {
        guard let itemId = Int32(id.raw) else { return }
        editor.menuImportActivate(itemId)
    }

    /// "This submenu is about to open." Applications are allowed to fill a
    /// submenu only when asked, so a menu opened without this can be
    /// legitimately empty — and stay that way until the user gives up.
    public func aboutToShow(_ id: MenuID) {
        guard let itemId = Int32(id.raw) else { return }
        editor.menuImportAboutToShow(itemId)
    }

    // MARK: - Import

    private func buildModel() -> MenuModel {
        let count = editor.menuImportItemCount
        guard count > 0 else { return MenuModel() }

        // One pass, parents before children — the order the importer emits —
        // so a child always finds its parent already in the map.
        var children: [Int32: [ImportedMenuItem]] = [:]
        for index in 0..<count {
            let item = editor.menuImportItem(index)
            children[item.parent, default: []].append(item)
        }

        let roots = children[-1] ?? []
        let menus = roots.compactMap { root -> MenuNode? in
            // A top-level entry that is a separator is not a menu; some
            // applications emit one anyway.
            guard !root.isSeparator else { return nil }
            return MenuNode(
                id: menuID(for: root.id),
                title: root.label,
                items: entries(under: root.id, children: children)
            )
        }
        return MenuModel(menus: menus)
    }

    private func entries(
        under parent: Int32,
        children: [Int32: [ImportedMenuItem]]
    ) -> [MenuEntry] {
        (children[parent] ?? []).map { item in
            if item.isSeparator { return .separator }
            let nested = children[item.id] ?? []
            // A submenu with nothing under it yet is drawn as an item: it is
            // one until the application answers `aboutToShow`, and an empty
            // dropdown reads as a broken menu where a plain entry does not.
            if item.hasSubmenu, !nested.isEmpty {
                return .submenu(MenuNode(
                    id: menuID(for: item.id),
                    title: item.label,
                    items: entries(under: item.id, children: children)
                ))
            }
            return .item(MenuItemModel(
                id: menuID(for: item.id),
                title: item.label,
                isEnabled: item.isEnabled,
                isChecked: item.checked < 0 ? nil : item.checked == 1
            ))
        }
    }

    /// A DBusMenu id as a `MenuID`. Deliberately the number and nothing else,
    /// so `activate` can turn it back without a side table that would have to
    /// be invalidated every time the layout changed.
    private func menuID(for itemId: Int32) -> MenuID {
        MenuID(String(itemId))
    }
}

#endif
