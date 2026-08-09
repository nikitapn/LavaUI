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
    /// Virtualized containers below this node, which need its offset and
    /// height to decide what to mount. Rebuilt on every relink.
    private(set) var lazyContent: [LazyGridNode] = []

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
    }

    /// Adopts the renderer-owned position. This is read-back, not a second
    /// scrolling implementation: it exists so hit testing and lazy mounting
    /// use the same coordinate space as the pixels already on screen.
    func adoptRendererOffset(x: Float, y: Float) {
        let next = clamped(axis == .horizontal ? x : y)
        guard next != scrollOffset else { return }
        scrollOffset = next
        if !lazyContent.isEmpty {
            ViewInvalidation.markNeedsLayout()
        } else if showsIndicator {
            // The subtree transform is renderer-owned; the indicator is
            // producer-drawn chrome derived from the reported position.
            ViewInvalidation.markNeedsRedraw()
        }
    }

    private func clamped(_ offset: Float) -> Float {
        min(max(0, offset), maxOffset)
    }

    var maxOffset: Float { max(0, contentLength - viewportLength) }

    /// Content emitted beyond the viewport on each side, as a fraction of it.
    ///
    /// This is how far the renderer may travel before it runs out of drawn
    /// content and has to wait for another emit — which is to say, it is the
    /// price of the retained tree's whole promise. A scroll that keeps moving
    /// while the producer is busy can only move across pixels the producer
    /// already handed over, so "keeps moving" reaches exactly this far and no
    /// further. Half a viewport roughly doubles the emitted commands and buys
    /// half a screen of travel against a producer that has stopped dead.
    private static let overscanFraction: Float = 0.5

    /// Floor for the above, in pixels: four wheel notches at the renderer's
    /// 48px step. A fraction alone would leave a 100px pane 50px of slack,
    /// which a single flick outruns.
    private static let minimumOverscan: Float = 192

    /// The span of content this frame is *trying* to cover, in the same
    /// coordinates as `scrollOffset`.
    ///
    /// One budget with two customers, which is the point of stating it here
    /// rather than in either of them: the cull emits this much, and a
    /// virtualized child mounts enough cells to fill it. When they disagreed
    /// the smaller silently won, and a `LazyVGrid` mounting two rows of
    /// overscan capped a half-viewport budget at sixty pixels.
    ///
    /// Takes the viewport rather than reading `viewportLength`, because
    /// layout asks this question before emit has assigned it — and a zero
    /// there would mount an empty window and flash a blank list. For the same
    /// reason it does not bound the far edge by `contentLength`, which is
    /// assigned in the same place: a band that runs past the end costs
    /// nothing, since both callers clamp against something they can see —
    /// rows for a grid, the real extent for `paintedSpan`.
    func desiredSpan(viewport: Float) -> (top: Float, bottom: Float) {
        let overscan = max(
            viewport * Self.overscanFraction, Self.minimumOverscan
        )
        return (
            max(0, scrollOffset - overscan),
            scrollOffset + viewport + overscan
        )
    }

    /// The span this frame will actually paint.
    ///
    /// `desiredSpan` narrowed to what is really there. Feeds both the cull
    /// rect and what `endNode` reports, from one computation, because they
    /// have to be the same band: the renderer clamps the scroll *position* to
    /// the span the producer claims to have drawn, so a claim wider than the
    /// paint is not optimism but a promise of pixels that do not exist. It
    /// cashes out as a panel that goes blank precisely when it is scrolled
    /// fast enough for the renderer to outrun the producer.
    ///
    /// Vertical only. `EndNode` carries one span and the renderer applies it
    /// to Y, so a horizontal container gets its content emitted whole instead
    /// — see `DrawList.emitNodeBody`.
    func paintedSpan() -> (top: Float, bottom: Float) {
        var (top, bottom) = desiredSpan(viewport: viewportLength)
        // Emit-time, so the real extent is known here even though it was not
        // when the band was stated.
        bottom = min(bottom, max(contentLength, viewportLength))

        // A virtualized child can still fall short of the budget — the data
        // ran out, or a remount has not caught up with a jump. Culling decides
        // what is drawn, but a cell that was never mounted has nothing to draw
        // at any cull width, so the honest extent is the tighter of the two.
        for grid in lazyContent {
            guard let mounted = grid.mountedSpan else { continue }
            top = max(top, mounted.top)
            bottom = min(bottom, mounted.bottom)
        }

        // Never claim less than what is on screen right now. A grid's window
        // can be momentarily narrower than the viewport — the first frame, or
        // the frame of a resize — and reporting a span that excludes visible
        // rows would make the renderer clamp the position *backwards* and
        // yank the view. What is on screen is painted by definition; the next
        // emit widens the rest.
        return (
            min(top, scrollOffset),
            max(bottom, scrollOffset + viewportLength)
        )
    }

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
        let leaves = contentNode.flattenedLayoutNodes()
        // Same children means the same adoption and the same flexShrink, so
        // there is nothing below that needs redoing either. See
        // `yogaChildrenChanged`.
        guard yogaChildrenChanged(leaves, insertedLeaves) else { return }
        YGNodeRemoveAllChildren(yogaStorage)
        // Adopt any virtualized container underneath: it cannot work out what
        // is visible without this node's offset and height.
        lazyContent = LazyGrid.nodes(in: contentNode, stopAtScroll: true)
        for grid in lazyContent {
            grid.scrollNode = self
        }
        insertedLeaves = leaves
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
