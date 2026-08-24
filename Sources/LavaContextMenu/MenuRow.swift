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

    /// The compositor's items, as rows. Unknown ordinals cannot occur — the
    /// enum is generated from the same IDL both sides compile — so the switch
    /// is total rather than defensive.
    static func rows(from items: [LavaIDL.MenuItem]) -> [MenuRow] {
        items.map { item in
            switch item.kind {
            case .separator:
                return .separator
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

    /// Whether any row wants a tick column — see `Row.checkable`.
    static func hasChecks(_ rows: [MenuRow]) -> Bool {
        rows.contains { row in
            if case let .item(item) = row { return item.checkable }
            return false
        }
    }
}
