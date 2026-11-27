import Foundation

/// A key the project tree answers, with the page size already worked out
/// from the view's height.
public enum ProjectTreeKey: Equatable, Sendable {
    case up, down, left, right, home, end
    case pageUp(rows: Int)
    case pageDown(rows: Int)
}

/// What one key does to the tree: move the selection, or open or close the
/// folder it is on.
public enum ProjectTreeStep: Equatable, Sendable {
    case select(String)
    case expand(String)
    case collapse(String)
    case none
}

extension ProjectTree {
    /// What `key` does with `selected` on `rows`, as file trees everywhere
    /// answer it: Left closes an open folder and otherwise goes to the
    /// parent, Right opens a closed folder and otherwise goes to its first
    /// child. Up, Down, Home, End and the page keys move along the visible
    /// rows and stop at the ends.
    ///
    /// With nothing selected — or a selection that is no longer on screen —
    /// the first key selects the row that key would reach from outside the
    /// list: the top for Down, Home and Right, the bottom for Up and End.
    public static func step(
        _ key: ProjectTreeKey, from selected: String?, in rows: [ProjectRow]
    ) -> ProjectTreeStep {
        guard let last = rows.indices.last else { return .none }
        guard let index = rows.firstIndex(where: { $0.node.path == selected }) else {
            switch key {
            case .up, .end, .pageUp: return .select(rows[last].node.path)
            default: return .select(rows[0].node.path)
            }
        }
        let row = rows[index]
        func select(_ target: Int) -> ProjectTreeStep {
            let clamped = min(max(target, 0), last)
            return clamped == index ? .none : .select(rows[clamped].node.path)
        }
        switch key {
        case .up: return select(index - 1)
        case .down: return select(index + 1)
        case .home: return select(0)
        case .end: return select(last)
        case .pageUp(let n): return select(index - max(1, n))
        case .pageDown(let n): return select(index + max(1, n))
        case .left:
            if row.node.isDirectory, row.isExpanded { return .collapse(row.node.path) }
            // The parent is the nearest row above that is one level out.
            guard row.depth > 0,
                  let parent = rows[..<index].lastIndex(where: { $0.depth == row.depth - 1 })
            else { return .none }
            return .select(rows[parent].node.path)
        case .right:
            guard row.node.isDirectory else { return .none }
            if !row.isExpanded { return .expand(row.node.path) }
            // An open folder with nothing in it has no first child to go to.
            guard index < last, rows[index + 1].depth == row.depth + 1 else { return .none }
            return .select(rows[index + 1].node.path)
        }
    }
}
