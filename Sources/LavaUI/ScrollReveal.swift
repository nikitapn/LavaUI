import Foundation

// `.scrollIntoView(when:)` — a view inside a `ScrollView` asking to be shown.
//
// `LazyVStack` has always had this for itself (`scrollTarget:`), because it
// owns the rows and knows where each one is. A view anywhere else in a scroll
// container had no way to ask: the offset is renderer-owned, and an app that
// wanted the active tab in view could neither read where the tab was in the
// content nor say where the viewport should go. Found in LavaExplorer, where a
// new tab opened past the right edge of a strip that had just learned to
// scroll.

#if canImport(CYoga)
import CYoga

enum ScrollReveal {
    /// Whether any box is waiting. Checked by every layout pass; the walk
    /// that finds the boxes runs only when it is set.
    nonisolated(unsafe) static var anyPending = false

    /// An edge, not a level: a box asks once when its condition turns true
    /// — or when it is mounted with it true — and not on every rebuild after.
    /// A level would drag the strip back to the active tab on every layout,
    /// and nobody could wheel away from it.
    static func request(_ box: YogaBoxNode, active: Bool) {
        if active, !box.revealWanted {
            box.revealPending = true
            anyPending = true
        }
        box.revealWanted = active
    }

    /// Hands each waiting box to its nearest scroll container.
    static func resolve(in root: any AnyViewNode) {
        anyPending = false
        walk(root, scroll: nil, x: 0, y: 0)
    }

    /// `x`,`y` accumulate the box's position in its scroll container's content
    /// — which starts again at zero inside every container, because that is
    /// the space the container's offset is measured in.
    private static func walk(
        _ node: any AnyViewNode, scroll: ScrollNode?, x: Float, y: Float
    ) {
        var scroll = scroll
        var x = x
        var y = y
        if let box = node as? YogaBoxNode, let yoga = box.yoga {
            x += YGNodeLayoutGetLeft(yoga)
            y += YGNodeLayoutGetTop(yoga)
            if box.revealPending {
                box.revealPending = false
                if let scroll {
                    let w = YGNodeLayoutGetWidth(yoga)
                    let h = YGNodeLayoutGetHeight(yoga)
                    switch scroll.axis {
                    case .horizontal:
                        scroll.reveal(top: x, bottom: x + w, viewport: scroll.boxWidth)
                    case .vertical:
                        scroll.reveal(top: y, bottom: y + h, viewport: scroll.boxHeight)
                    }
                }
            }
            if let container = box as? ScrollNode {
                scroll = container
                x = 0
                y = 0
            }
        }
        for child in node.childNodes {
            walk(child, scroll: scroll, x: x, y: y)
        }
    }
}

extension View {
    /// Scrolls the nearest enclosing `ScrollView` so this view is in sight,
    /// each time `active` becomes true — the selected tab in a strip that
    /// overflows, say. Only as far as it takes: a view already in sight does
    /// not move anything.
    ///
    /// Asks once per change rather than holding the view in place, so the
    /// container can still be scrolled away from it afterwards.
    public func scrollIntoView(when active: Bool) -> BoxRegistrationView<Self> {
        BoxRegistrationView(
            label: "ScrollIntoView",
            register: { ScrollReveal.request($0, active: active) },
            content: self
        )
    }
}

#else

extension View {
    /// No-op without Yoga (stubs).
    public func scrollIntoView(when active: Bool) -> Self { self }
}

#endif
