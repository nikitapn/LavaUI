import Foundation

/// The pointer image over a view.
///
/// A small set on purpose. Every shape here exists in GLFW's standard cursors
/// *and* in every X11 cursor theme the compositor can load, which is the whole
/// bar a shape has to clear: one of the two run modes drawing an arrow where
/// the other draws a resize handle would be worse than not offering it.
///
/// The raw values cross a process boundary (`SetCursor` in the IDL) and are
/// mapped to names by the compositor, so they are stable — append, never
/// renumber.
public enum CursorShape: UInt32, Equatable, Sendable, CaseIterable {
    /// The default pointer. What every view has until something says otherwise.
    case arrow = 0
    /// I-beam, over editable or selectable text.
    case text = 1
    /// The "this activates something" hand.
    case pointer = 2
    /// A thin cross, for picking a point or a pixel.
    case crosshair = 3
    /// Horizontal drag: a vertical divider, a column edge.
    case resizeLeftRight = 4
    /// Vertical drag: a horizontal divider, a row edge.
    case resizeUpDown = 5
    /// No pointer at all, while it is over this view — a video in fullscreen
    /// once its controls have faded. Any movement that should bring it back
    /// has to be answered by the view, which changes its cursor again: the
    /// renderer hides the image, it does not stop delivering motion.
    case hidden = 6
}

extension View {
    /// The pointer image while the pointer is inside this view.
    ///
    /// ```swift
    /// grabBar.cursor(.resizeUpDown)
    /// ```
    ///
    /// The innermost view under the pointer that states one wins; ancestors
    /// answer for the gaps, so a whole panel can ask for `.text` and a button
    /// inside it ask for `.pointer` without either knowing about the other.
    ///
    /// Stating a cursor makes the view **hit-testable** — the renderer has to
    /// report the pointer entering it before anything can act on this, which
    /// is the same node a hover fill needs. That is a scene node per such view,
    /// so it is not free; it is the same cost `.hoverBackground` already pays.
    public func cursor(_ shape: CursorShape?) -> ModifiedView<Self> {
        var style = ViewStyle()
        style.cursor = shape
        return ModifiedView(content: self, style: style)
    }
}

/// Where the pointer image is actually set.
///
/// The same shape as `WindowBridge` and `ScrollBridge`: `LavaUI` must not know
/// what a compositor is. A windowed app sets the cursor on its own GLFW
/// window; a client has no pointer of its own and asks the compositor, which
/// fills `request` at connect. Unfilled, the windowed path is used, which is
/// the right default for a window and a no-op in a test.
public enum CursorBridge {
    /// Filled by `LavaClient`. The shape, then the engine window it was
    /// resolved in (`WindowID.rawValue`), so a second surface sets the
    /// pointer for itself and not for the window the app started with.
    /// The raw shape keeps the framework's enum out of the IDL layer.
    nonisolated(unsafe) public static var request: (@Sendable (UInt32, UInt32) -> Void)?

    /// What the pointer is showing right now, so that hovering across a
    /// hundred nodes that all want an arrow costs one call, not a hundred.
    ///
    /// One value rather than one per window: there is one pointer, and it is
    /// in one window at a time.
    nonisolated(unsafe) private static var current: CursorShape = .arrow

    /// Called by the window that owns the pointer, on every hover change.
    static func apply(_ shape: CursorShape, window: WindowID, editor: Editor) {
        guard shape != current else { return }
        current = shape
        if let request {
            request(shape.rawValue, window.raw)
            return
        }
        editor.setCursor(shape, window: window)
    }

    /// Forgets what was applied, without setting anything.
    ///
    /// For a window that has just been handed the pointer: the last shape was
    /// set on a *different* window (or, in client mode, taken back by the
    /// compositor when the pointer crossed to another surface), so the next
    /// `apply` has to be believed even if it names the same shape.
    static func invalidate() {
        current = .arrow
    }

    /// Resolves what the pointer should show over `id`, and applies it.
    ///
    /// An empty hover report or a live node with no stated cursor uses the arrow.
    /// A report for a removed node can arrive while the renderer is still
    /// showing the previous draw list. Keep the cursor until its next report.
    ///
    /// While a node holds `PointerCapture` its cursor wins over whatever is
    /// under the pointer. A drag carries the pointer away from the node that
    /// started it — a split's divider lags the hand by a frame, a selection
    /// runs off the end of its field — and the renderer goes on reporting
    /// the nodes it crosses, so without this the resize arrow turned into an
    /// I-beam or a hand over every pane it passed. The window resolves the
    /// node under the pointer again on release.
    static func hover(
        _ hovered: NodeID?, in root: (any AnyViewNode)?,
        window: WindowID, editor: Editor
    ) {
        if let holder = PointerCapture.holder, let root, holds(holder, in: root) {
            hover(resolving: holder, in: root, window: window, editor: editor)
            return
        }
        hover(resolving: hovered, in: root, window: window, editor: editor)
    }

    /// Whether `id` is in `root` or one of its presented overlays.
    private static func holds(_ id: NodeID, in root: any AnyViewNode) -> Bool {
        if resolve(id, in: root) != nil { return true }
        return OverlayScan.presented(in: root).contains { attachment in
            attachment.root.map { resolve(id, in: $0) != nil } ?? false
        }
    }

    private static func hover(
        resolving id: NodeID?, in root: (any AnyViewNode)?,
        window: WindowID, editor: Editor
    ) {
        guard let id else {
            apply(.arrow, window: window, editor: editor)
            return
        }
        guard let root else { return }
        if let shape = resolve(id, in: root) {
            apply(shape ?? .arrow, window: window, editor: editor)
            return
        }
        for attachment in OverlayScan.presented(in: root) {
            guard let overlay = attachment.root, let shape = resolve(id, in: overlay) else {
                continue
            }
            apply(shape ?? .arrow, window: window, editor: editor)
            return
        }
    }

    /// Innermost stated cursor on the path from `node` to `id`, or nil when
    /// `id` is not in this subtree.
    ///
    /// Returning "not here" and "here, wearing nothing" as different answers is
    /// what lets an ancestor's cursor apply to a child that states none — the
    /// walk unwinds through the ancestors and the first one with an opinion
    /// takes it.
    static func resolve(
        _ id: NodeID, in node: any AnyViewNode
    ) -> CursorShape?? {
        var own = (node as? YogaBoxNode)?.cursor
        if let leaf = node as? LeafNode, let asked = leaf.pointerCursor { own = asked }
        if node.id == id { return .some(own) }
        for child in node.childNodes {
            guard let inner = resolve(id, in: child) else { continue }
            return .some(inner ?? own)
        }
        return nil
    }
}
