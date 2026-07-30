#if canImport(CxxCanvas)
import CYoga
import Foundation

/// A clipped, scrollable container.
///
/// Generalises what `EditorView` already did for itself. The pieces it reuses —
/// scissor clipping, wheel routing, scroll clamping against a viewport measured
/// at emit time — all exist because a code editor needed them first; this is
/// mostly extraction.
///
/// Content is laid out at its **natural** size and allowed to overflow, which
/// is what `YGOverflowScroll` buys: without it Yoga compresses children to fit
/// the container and there is nothing left to scroll.
public struct ScrollView<Content: View>: PrimitiveView {
    public var axis: ScrollAxis
    public var content: Content
    /// Draw a thin position indicator while the content overflows.
    public var showsIndicator: Bool

    public init(
        _ axis: ScrollAxis = .vertical,
        showsIndicator: Bool = true,
        @ViewBuilder content: () -> Content
    ) {
        self.axis = axis
        self.content = content()
        self.showsIndicator = showsIndicator
    }

    public var dumpDetail: String { "\(axis)" }

    public func structureLines(indent: Int = 0) -> [String] {
        Dump.structureLines(
            indent: indent, label: "ScrollView \(axis)",
            childLines: [content.structureLines(indent: indent + 1)]
        )
    }

    public func mountPrimitive() -> any AnyViewNode {
        let node = ScrollNode(axis: axis, content: ViewGraph.mount(content))
        node.showsIndicator = showsIndicator
        node.registerScrolling()
        return node
    }

    public func reconcilePrimitive(_ node: any AnyViewNode) -> any AnyViewNode {
        guard let scroll = node as? ScrollNode, scroll.axis == axis else {
            return mountPrimitive()
        }
        scroll.showsIndicator = showsIndicator
        scroll.updateContent(ViewGraph.reconcile(scroll.contentNode, with: content))
        return scroll
    }
}

public enum ScrollAxis: Equatable, Sendable {
    case vertical
    case horizontal
}

final class ScrollNode: YogaBoxNode {
    let axis: ScrollAxis
    private(set) var contentNode: any AnyViewNode
    var showsIndicator = true

    /// Captured from `Environment.current.theme` at mount/reconcile — the
    /// scroll-indicator paint runs later, as a separate pass with no
    /// environment scope active, so it reads this instead of `Theme.current`.
    var theme: Theme = Theme.current

    var scrollOffset: Float = 0
    /// Box size from the last emit. Clamping has to use what Yoga granted, not
    /// what was asked for — the same lesson the editor's viewport learned.
    var viewportLength: Float = 0
    var contentLength: Float = 0

    private var insertedLeaves: [any AnyViewNode] = []

    init(axis: ScrollAxis, content: any AnyViewNode) {
        self.axis = axis
        self.contentNode = content
        self.theme = Environment.current.theme
        super.init(label: "ScrollView")
        YGNodeStyleSetFlexDirection(
            yogaStorage, axis == .vertical ? YGFlexDirectionColumn : YGFlexDirectionRow
        )
        // Without this Yoga shrinks children to fit and nothing overflows,
        // which would leave a scroll container with nothing to scroll.
        YGNodeStyleSetOverflow(yogaStorage, YGOverflowScroll)
        YGNodeStyleSetAlignItems(yogaStorage, YGAlignStretch)
        // Fill the space the parent offers; the content inside is what exceeds it.
        flexGrow = 1
        flexShrink = 1
        applyStyle()
        relink()
    }

    override var childNodes: [any AnyViewNode] { [contentNode] }

    override var childOffset: (x: Float, y: Float) {
        axis == .horizontal ? (scrollOffset, 0) : (0, scrollOffset)
    }

    func updateContent(_ node: any AnyViewNode) {
        contentNode = node
        theme = Environment.current.theme
        relink()
    }

    func registerScrolling() {
        isScrollable = true
        ScrollRouter.register(id) { [weak self] dx, dy in
            guard let self else { return }
            // A vertical container still responds to a horizontal trackpad
            // gesture, and vice versa, rather than swallowing it silently.
            let delta = self.axis == .vertical ? dy : (dx != 0 ? dx : dy)
            self.scrollBy(-delta * 48)
        }
    }

    func scrollBy(_ delta: Float) {
        let next = min(max(0, scrollOffset + delta), maxOffset)
        if next != scrollOffset {
            scrollOffset = next
            ViewInvalidation.markDirty()
        }
    }

    var maxOffset: Float { max(0, contentLength - viewportLength) }

    /// Natural extent of the content, from the laid-out children rather than a
    /// second measuring pass.
    func measureContentLength() -> Float {
        var extent: Float = 0
        for leaf in insertedLeaves {
            guard let y = leaf.yoga else { continue }
            extent = max(
                extent,
                axis == .vertical
                    ? YGNodeLayoutGetTop(y) + YGNodeLayoutGetHeight(y)
                    : YGNodeLayoutGetLeft(y) + YGNodeLayoutGetWidth(y)
            )
        }
        return extent
    }

    private func relink() {
        YGNodeRemoveAllChildren(yogaStorage)
        insertedLeaves = contentNode.flattenedLayoutNodes()
        for (i, leaf) in insertedLeaves.enumerated() {
            guard let y = leaf.yoga else { continue }
            // Children must keep their natural size; shrinking them to fit is
            // exactly what a scroll container must not do.
            if let box = leaf as? YogaBoxNode {
                box.flexShrink = 0
                box.applyStyle()
            }
            YGNodeInsertChild(yogaStorage, y, i)
        }
    }

    override func collectChildFrames(
        originX: Float, originY: Float, into frames: inout [LayoutFrame]
    ) {
        contentNode.collectFrames(originX: originX, originY: originY, into: &frames)
    }
}

#endif
