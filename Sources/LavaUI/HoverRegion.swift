// "Is the pointer over this view?" — for a view as a whole, children included.
//
// The renderer answers a narrower question. It names the one innermost node
// under the pointer, which is right for a hover tint and wrong for anything
// about an area: a floating control bar whose pointer is on its play button is
// still a bar with the pointer on it, and a bar that hid itself then would be
// hiding from under the hand using it. So a region is resolved here, from the
// renderer's answer, as "that node or one of its ancestors" — the same walk
// `CursorBridge` does to find the cursor a node inherits.
//
// A region is also a hit-test node of its own, tinted or not. Without that, a
// pointer on the bar's bare background is over nothing the renderer would
// name, and the region would read as left.

extension View {
    /// Calls `action(true)` when the pointer comes over this view or anything
    /// inside it, and `action(false)` when it leaves all of them.
    ///
    /// Not called again while the pointer moves between the view's children:
    /// crossing from one button to the next inside a bar is not leaving it.
    /// Both run modes — the compositor's hover events and a window's own
    /// resolve it the same way.
    ///
    /// ```swift
    /// ControlBar()
    ///     .onHover { inside in session.pointerOnBar = inside }
    /// ```
    public func onHover(_ action: @escaping (Bool) -> Void) -> ModifiedView<Self> {
        var style = ViewStyle()
        style.hoverRegion = HoverRegionAction(action)
        return ModifiedView(content: self, style: style)
    }
}

extension ModifiedView {
    /// See `View.onHover(_:)`.
    public func onHover(_ action: @escaping (Bool) -> Void) -> ModifiedView<Content> {
        var next = ViewStyle()
        next.hoverRegion = HoverRegionAction(action)
        return ModifiedView(
            content: content, style: next.merged(over: style),
            forceWrapper: forceWrapper
        )
    }
}

/// A region's callback, as a `ViewStyle` field.
///
/// Never equal, not even to itself: closures cannot be compared, and a style
/// that compared equal would let reconcile keep the closure from the first
/// body pass — one capturing state that has since been replaced.
public struct HoverRegionAction: Equatable {
    let action: (Bool) -> Void

    init(_ action: @escaping (Bool) -> Void) { self.action = action }

    public static func == (lhs: Self, rhs: Self) -> Bool { false }
}

/// Which regions the pointer is in, and the calls that keep that true.
///
/// One set for the process, like `HoverState`: there is one pointer, and the
/// node ids are unique across windows, so a move into another window's node
/// leaves every region of the first one by the same rule as any other move.
enum HoverRegions {
    /// The regions the pointer is in, innermost last, with the callback each
    /// had when it was entered — kept so a region whose node has gone from the
    /// tree can still be told it was left.
    nonisolated(unsafe) private static var inside: [(id: NodeID, action: (Bool) -> Void)] = []

    /// `hovered` is the renderer's innermost node, nil for none; `root` the
    /// tree it is in.
    static func update(hovered: NodeID?, in root: (any AnyViewNode)?) {
        // Every hover change comes through here, which is all a tooltip
        // needs to hear about too.
        Tooltips.update(hovered: hovered, in: root)
        var now: [(id: NodeID, action: (Bool) -> Void)] = []
        if let hovered, let root { collect(hovered, in: root, into: &now) }

        let nowIDs = Set(now.map(\.id))
        let wereIDs = Set(inside.map(\.id))
        let left = inside.filter { !nowIDs.contains($0.id) }
        let entered = now.filter { !wereIDs.contains($0.id) }
        inside = now
        // Inner regions first on the way out, outer first on the way in: the
        // order nesting implies, and the one a handler can rely on.
        for region in left.reversed() { region.action(false) }
        for region in entered { region.action(true) }
    }

    /// Whether `id`'s node is in `node`'s subtree; appends every region on the
    /// way down to it, outermost first.
    @discardableResult
    private static func collect(
        _ id: NodeID, in node: any AnyViewNode,
        into path: inout [(id: NodeID, action: (Bool) -> Void)]
    ) -> Bool {
        let region = (node as? YogaBoxNode)?.hoverRegion
        if let region { path.append((node.id, region)) }
        if node.id == id { return true }
        for child in node.childNodes where collect(id, in: child, into: &path) {
            return true
        }
        if region != nil { path.removeLast() }
        return false
    }
}
