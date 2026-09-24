import Foundation
import LavaIDL

/// One row of a menu, in the form the view reads it.
///
/// A shape of its own rather than the IDL's `MenuItem`, because the wire type
/// carries an ordinal for its kind and everything here wants the cases apart —
/// and because a test that had to build an NPRPC struct to check a conversion
/// is a test nobody writes.
enum MenuRow: Equatable {
    case separator
    case item(Row)
    /// `rows` are this branch, not spilled into the parent. One level per
    /// plate: the fly-out beside this row is another menu, not more lines
    /// in this one.
    case submenu(id: UInt32, title: String, enabled: Bool, rows: [MenuRow])

    struct Row: Equatable {
        var id: UInt32
        var title: String
        var enabled: Bool
        /// Whether the row shows a tick column at all. A menu of commands has
        /// none and its titles start at the padding; one checkable item gives
        /// the column to every row, so the titles stay in line.
        var checkable: Bool
        var checked: Bool
        var shortcut: String
    }

    /// The compositor's flat list, as a tree.
    ///
    /// `parent` 0 is the root. A `submenu` row's children are the items whose
    /// `parent` is that row's id. A row whose parent is not a submenu in this
    /// list is dropped — see `MenuItem.parent`.
    static func rows(from items: [LavaIDL.MenuItem]) -> [MenuRow] {
        var byParent: [UInt32: [LavaIDL.MenuItem]] = [:]
        for item in items {
            byParent[item.parent, default: []].append(item)
        }
        func build(_ parent: UInt32, depth: Int) -> [MenuRow] {
            // A cycle — a row parenting itself — would recurse until the
            // stack died. Eight is more menu than anybody has written.
            guard depth < 8 else { return [] }
            return (byParent[parent] ?? []).map { item in
                switch item.kind {
                case .separator:
                    return .separator
                case .submenu:
                    return .submenu(
                        id: item.id, title: item.title, enabled: item.enabled,
                        rows: build(item.id, depth: depth + 1)
                    )
                case .checkbox:
                    return .item(Row(
                        id: item.id, title: item.title, enabled: item.enabled,
                        checkable: true, checked: item.checked,
                        shortcut: item.shortcut
                    ))
                case .command:
                    return .item(Row(
                        id: item.id, title: item.title, enabled: item.enabled,
                        checkable: false, checked: false, shortcut: item.shortcut
                    ))
                }
            }
        }
        return build(0, depth: 0)
    }

    /// The rows under `id`, searched from this plate downward.
    static func children(of id: UInt32, in rows: [MenuRow]) -> [MenuRow]? {
        for row in rows {
            guard case .submenu(let sid, _, _, let nested) = row else { continue }
            if sid == id { return nested }
            if let found = children(of: id, in: nested) { return found }
        }
        return nil
    }

    /// Whether any row wants a tick column — see `Row.checkable`.
    static func hasChecks(_ rows: [MenuRow]) -> Bool {
        rows.contains { row in
            if case let .item(item) = row { return item.checkable }
            return false
        }
    }
}
