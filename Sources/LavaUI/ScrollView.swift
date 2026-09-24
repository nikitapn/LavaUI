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
    /// Where the view is, kept up to date as it scrolls, and a way to put it
    /// somewhere. See `ScrollPosition`.
    public var position: ScrollPosition?

    public init(
        _ axis: ScrollAxis = .vertical,
        showsIndicator: Bool = true,
        position: ScrollPosition? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.axis = axis
        self.content = content()
        self.showsIndicator = showsIndicator
        self.position = position
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
        node.bind(position)
        return node
    }

    public func reconcilePrimitive(_ node: any AnyViewNode) -> any AnyViewNode {
        guard let scroll = node as? ScrollNode, scroll.axis == axis else {
            return mountPrimitive()
        }
        scroll.showsIndicator = showsIndicator
        scroll.updateContent(ViewGraph.reconcile(scroll.contentNode, with: content))
        scroll.bind(position)
        return scroll
    }
}

/// Where a `ScrollView` is — for an app that has to remember it and put it
/// back: a folder list returning to the row it was opened from, or a tab
/// whose list should not come back scrolled to where another tab left it.
///
/// A reference the app keeps, one per place it wants remembered, and not a
/// binding: the offset is the renderer's and changes every frame of a scroll,
/// and an observed value would rebuild the app's body on each of them.
/// `offset` follows the renderer without anyone being told. `scroll(to:)`
/// puts the view there after the next layout — once the content's new length
/// is known, so an offset saved in a long folder is not clamped against the
/// short one being left — and before a lazy list decides which rows to mount,
/// so the first frame there is already full. It jumps rather than eases: the
/// point is to be where you were, not to be seen travelling there.
///
/// Handing a `ScrollView` a different position puts it where that one was.
public final class ScrollPosition: @unchecked Sendable {
    /// Where the view last was, in points from the top (or leading edge).
    public internal(set) var offset: Float
    var pending: Float?

    public init(offset: Float = 0) {
        self.offset = offset
    }

    public func scroll(to offset: Float) {
        pending = max(0, offset)
        ScrollPositions.anyPending = true
        ViewInvalidation.markNeedsLayout()
    }

    public func scrollToTop() { scroll(to: 0) }
}

enum ScrollPositions {
    nonisolated(unsafe) static var anyPending = false

    /// Puts every scroll container with a pending position there. True when
    /// one of them holds lazy content, which then has rows to mount for
    /// where it now is.
    static func resolve(in root: any AnyViewNode) -> Bool {
        anyPending = false
        return walk(root)
    }

    private static func walk(_ node: any AnyViewNode) -> Bool {
        var remount = false
        if let scroll = node as? ScrollNode, scroll.applyPendingPosition() {
            remount = true
        }
        for child in node.childNodes where walk(child) {
            remount = true
        }
        return remount
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
    /// Latest programmatic reveal. Kept after emission: the renderer uses the
    /// serial to distinguish a repeated frame from a new request.
    private(set) var revealRequest:
        (offset: Float, serial: UInt32, immediate: Bool)?
    private var nextRevealSerial: UInt32 = 1

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

    private(set) var position: ScrollPosition?

    /// A different position object is a different place — another tab's list
    /// in this same box — so the view goes to where that one was.
    func bind(_ next: ScrollPosition?) {
        guard next !== position else { return }
        position = next
        guard let next else { return }
        if next.pending == nil { next.scroll(to: next.offset) }
        ScrollPositions.anyPending = true
    }

    /// Jumps to the position's pending offset, measured against the layout
    /// just computed. True when lazy content has to settle again for it.
    func applyPendingPosition() -> Bool {
        guard let position, let wanted = position.pending else { return false }
        position.pending = nil
        let vertical = axis == .vertical
        viewportLength = vertical
            ? YGNodeLayoutGetHeight(yogaStorage) : YGNodeLayoutGetWidth(yogaStorage)
        var extent: Float = 0
        for index in 0..<YGNodeGetChildCount(yogaStorage) {
            guard let child = YGNodeGetChild(yogaStorage, index) else { continue }
            extent = max(extent, vertical
                ? YGNodeLayoutGetTop(child) + YGNodeLayoutGetHeight(child)
                : YGNodeLayoutGetLeft(child) + YGNodeLayoutGetWidth(child))
        }
        contentLength = extent
        let target = clamped(wanted)
        // Assigned here as well as requested — unlike `requestOffset` — so
        // that lazy rows are mounted for where the view is going on the very
        // frame that takes it there. The request is immediate, so the
        // renderer is there on that frame too, and the two cannot disagree.
        scrollOffset = target
        position.offset = target
        let serial = nextRevealSerial
        nextRevealSerial &+= 1
        if nextRevealSerial == 0 { nextRevealSerial = 1 }
        revealRequest = (target, serial, true)
        ViewInvalidation.markNeedsRedraw()
        return !lazyContent.isEmpty
    }

    func registerScrolling() {
        isScrollable = true
        // The bar is painted after the subtree and sits on the box's edge, so
        // the pointer has to be offered it before the content — see
        // `YogaBoxNode.onOverlayPress`.
        onOverlayPress = { [weak self] localX, localY, originX, originY in
            self?.scrollbarPress(
                localX: localX, localY: localY, originX: originX, originY: originY
            )
        }
    }

    /// Adopts the renderer-owned position. This is read-back, not a second
    /// scrolling implementation: it exists so hit testing and lazy mounting
    /// use the same coordinate space as the pixels already on screen.
    func adoptRendererOffset(x: Float, y: Float) {
        let next = clamped(axis == .horizontal ? x : y)
        guard next != scrollOffset else { return }
        scrollOffset = next
        position?.offset = next
        if !lazyContent.isEmpty {
            ViewInvalidation.markNeedsLayout()
        } else if showsIndicator {
            // The subtree transform is renderer-owned; the indicator is
            // producer-drawn chrome derived from the reported position.
            ViewInvalidation.markNeedsRedraw()
        }
    }

    /// Where this node will be when the frame now being emitted reaches the
    /// screen.
    ///
    /// Not `scrollOffset`, which is where the renderer last *reported* being.
    /// A drag in flight has an immediate request outstanding, and the renderer
    /// applies that while replaying this very frame — so everything derived
    /// from a position (the band this frame culls to, the span it claims to
    /// have drawn, whether a further request says anything new) has to be
    /// derived from here instead. Deriving it from `scrollOffset` means
    /// spending the drag drawing the place the view is leaving, and then
    /// telling the renderer that is all there is: a scrollbar amplifies
    /// pointer motion by `contentLength / track`, so the target is routinely
    /// further away than one band of overscan and the view crawls after the
    /// thumb a band per frame.
    ///
    /// Bounded by the drag rather than by the request's own lifetime.
    /// `revealRequest` is kept after emission so that a repeated frame carries
    /// a repeated serial, and a request outliving the finger that made it must
    /// not go on standing in for a position the wheel has since moved.
    var effectiveOffset: Float {
        guard ScrollbarDrag.isDragging(id), let request = revealRequest,
              request.immediate
        else { return scrollOffset }
        return request.offset
    }

    private func clamped(_ offset: Float) -> Float {
        min(max(0, offset), maxOffset)
    }

    var maxOffset: Float { max(0, contentLength - viewportLength) }

    /// Asks the renderer to put the viewport at `offset`.
    ///
    /// Not an assignment to `scrollOffset`: the offset is renderer-owned —
    /// the subtree transform lives there, and this side only learns where it
    /// ended up, through `adoptRendererOffset`. Writing the field directly
    /// would move the indicator and leave the content where it was.
    ///
    /// `immediate` says the caller is naming a position rather than a
    /// destination — a finger holding the thumb, not a wheel notch — so the
    /// renderer should be there on the frame that carries the request instead
    /// of easing toward it. See `kSceneScrollImmediate`.
    func requestOffset(_ offset: Float, immediate: Bool = false) {
        let target = clamped(offset)
        // Against where the next frame puts us, not where the last one
        // reported: mid-drag those differ by the whole remaining journey, and
        // comparing against the position would drop a pointer move that
        // happens to name where the content already is while a stale target is
        // still outstanding.
        guard abs(target - effectiveOffset) > 0.01 else { return }
        let serial = nextRevealSerial
        nextRevealSerial &+= 1
        if nextRevealSerial == 0 { nextRevealSerial = 1 }
        revealRequest = (target, serial, immediate)
        // A virtualized child works out what to mount from `desiredSpan`,
        // which an immediate request has just moved — so it needs the chance
        // to act on it, the same chance `adoptRendererOffset` gives it when a
        // position arrives the other way round. Without this the drag culls to
        // a band the grid has mounted no cells for, `paintedSpan` honestly
        // narrows to what was mounted, and the view crawls after the thumb
        // again for want of a layout pass.
        if immediate && !lazyContent.isEmpty {
            ViewInvalidation.markNeedsLayout()
        } else {
            ViewInvalidation.markNeedsRedraw()
        }
    }

    /// Takes a press that landed on this container's scrollbar, or declines.
    ///
    /// Same feel as the editor's, from the same geometry: grabbing the thumb
    /// keeps the grab offset so the content does not jump, and pressing bare
    /// track jumps there and drags from the middle. See `Scrollbar`.
    func scrollbarPress(
        localX: Float, localY: Float, originX: Float, originY: Float
    ) -> (() -> Void)? {
        guard showsIndicator, maxOffset > 0 else { return nil }
        let onBar = axis == .vertical
            ? Scrollbar.hitsVertical(localX: localX, boxWidth: boxWidth)
            : Scrollbar.hitsHorizontal(localY: localY, boxHeight: boxHeight)
        guard onBar, let m = Scrollbar.metrics(
            track: viewportLength, content: contentLength,
            offset: scrollOffset, maxOffset: maxOffset
        ) else { return nil }

        let along = axis == .vertical ? localY : localX
        let grab = along >= m.along && along < m.along + m.thumb
            ? along - m.along : m.thumb / 2
        let origin = axis == .vertical ? originY : originX
        let maximum = maxOffset
        return { [weak self] in
            guard let self else { return }
            ScrollbarDrag.begin(self.id, axis: self.axis)
            let apply = { [weak self] (window: Float) in
                guard let self else { return }
                self.requestOffset(
                    Scrollbar.offset(
                        forAlong: window - origin - grab,
                        travel: m.travel, maxOffset: maximum
                    ),
                    immediate: true
                )
            }
            apply(origin + along)
            PointerCapture.capture(
                self.id,
                onMove: { wx, wy in apply(self.axis == .vertical ? wy : wx) },
                onUp: { ScrollbarDrag.end() }
            )
        }
    }

    func reveal(top: Float, bottom: Float, viewport: Float) {
        guard viewport > 0 else { return }
        let target: Float
        if top < scrollOffset {
            target = top
        } else if bottom > scrollOffset + viewport {
            target = bottom - viewport
        } else {
            return
        }
        let serial = nextRevealSerial
        nextRevealSerial &+= 1
        if nextRevealSerial == 0 { nextRevealSerial = 1 }
        revealRequest = (max(0, target), serial, false)
        ViewInvalidation.markNeedsRedraw()
    }

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

    /// Floor for the above, in pixels: four wheel detents at the renderer's
    /// 72px step. A fraction alone would leave a 100px pane 50px of slack,
    /// which a single flick outruns.
    private static let minimumOverscan: Float = 288

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
    ///
    /// Centred on `effectiveOffset` rather than on `scrollOffset`, so a drag
    /// draws where it is going rather than where it has been.
    func desiredSpan(viewport: Float) -> (top: Float, bottom: Float) {
        let overscan = max(
            viewport * Self.overscanFraction, Self.minimumOverscan
        )
        let position = effectiveOffset
        return (
            max(0, position - overscan),
            position + viewport + overscan
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
        //
        // "On screen" meaning once this frame lands, which during a drag is
        // the outstanding request and not the last reported position — see
        // `effectiveOffset`.
        return (
            min(top, effectiveOffset),
            max(bottom, effectiveOffset + viewportLength)
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
