import LavaIDL
import LavaMenu
import LavaUI

/// One row of a menu this panel asked the compositor to draw.
///
/// `OpenMenu` carries a `u32` and nothing else. What the row does — run a
/// menu item, or open the submenu under it — stays here, and comes back
/// when `MenuChoice` names the id.
enum HostedMenuAction {
    case barItem(MenuID)
    case trayItem(MenuID)
}

/// The menu the compositor is showing for this panel, if one is.
struct HostedMenu {
    var serial: UInt32
    var actions: [UInt32: HostedMenuAction]
    /// Where it was anchored, so a submenu opens in the same place.
    var x: Float
    var y: Float
    /// Set when the rows came from a tray icon, so a second poll does not
    /// open the same menu again.
    var trayKey: String?
}

/// A menu whose rows were not ready at the click.
///
/// Tray menus and some application menus answer `aboutToShow` a frame or
/// two later. Asked again from the pump until the rows exist, or until the
/// one that was up is dismissed.
enum PendingMenu {
    case bar(MenuID)
    case tray(key: String, x: Float, y: Float)
}

enum MenuWire {
    /// `MenuEntry` tree → the flat rows `OpenMenu` takes.
    ///
    /// A submenu stays a submenu. Its children carry its id as `parent`,
    /// which is how the wire spells a tree: the menu client flies the branch
    /// out beside the row, and the compositor places that plate. Choosing a
    /// submenu is not an action — the menu does not close, and nothing here
    /// is asked to run.
    static func convert(
        _ entries: [MenuEntry], tray: Bool
    ) -> (items: [LavaIDL.MenuItem], actions: [UInt32: HostedMenuAction]) {
        var items: [LavaIDL.MenuItem] = []
        var actions: [UInt32: HostedMenuAction] = [:]
        var next: UInt32 = 1
        func emit(_ entries: [MenuEntry], parent: UInt32) {
            for entry in entries {
                switch entry {
                case .separator:
                    var row = LavaIDL.MenuItem()
                    row.kind = .separator
                    row.parent = parent
                    items.append(row)
                case .item(let item):
                    let id = next
                    next += 1
                    let checkable = item.isChecked != nil
                    var row = LavaIDL.MenuItem()
                    row.id = id
                    row.title = item.title
                    row.kind = checkable ? .checkbox : .command
                    row.checked = item.isChecked == true
                    row.enabled = item.isEnabled
                    row.shortcut = item.shortcut.map(MenuShortcutLabel.format) ?? ""
                    row.parent = parent
                    items.append(row)
                    actions[id] = tray ? .trayItem(item.id) : .barItem(item.id)
                case .submenu(let node):
                    let id = next
                    next += 1
                    var row = LavaIDL.MenuItem()
                    row.id = id
                    row.title = node.title
                    row.kind = .submenu
                    row.enabled = true
                    row.parent = parent
                    items.append(row)
                    emit(node.items, parent: id)
                }
            }
        }
        emit(entries, parent: 0)
        return (items, actions)
    }
}
