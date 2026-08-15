import CYoga
import Foundation

/// Two stacked panes with a draggable divider between them.
///
/// The split is stored as a *fraction* of the space the two panes share, not as
/// a height, so a window resize keeps the proportion the user chose instead of
/// growing one pane and pinning the other. `minTop` / `minBottom` are point
/// floors, which is what stops a pane being dragged away entirely.
///
/// ```swift
/// VSplitView(fraction: $session.logSplit, minTop: 160, minBottom: 90) {
///     timeline
///     legend
/// } bottom: {
///     EditorView(text: $session.log).flexGrow(1)
/// }
/// ```
///
/// Each pane is a column, like a `VStack` — several statements stack with the
/// theme's spacing. A pane's content is laid out inside a box whose height the
/// divider decides, so content that should *fill* its pane has to say so
/// (`.flexGrow(1)`); content that states its own height keeps it and is clipped
/// when the pane gets smaller than that.
///
/// **The drag does not run bodies.** A pointer move writes the new flex factors
/// straight onto the panes' Yoga nodes and asks for layout — for the same reason
/// `Slider` maintains its knob itself, a body pass per pointer pixel is
/// milliseconds of work between the hand and the pixels. The binding is written
/// once, on release. A view that *displays* the fraction therefore updates when
/// the drag ends, not during it.
///
/// `HSplitView` is the same thing on the other axis.
public struct VSplitView<Top: View, Bottom: View>: PrimitiveView {
    /// Where the app keeps the split, when it wants to keep it. `nil` leaves
    /// the value on the node, which lives as long as the view does.
    public var fraction: Binding<Float>?
    /// Used only at mount, when there is no binding to read.
    public var initialFraction: Float
    public var minTop: Float
    public var minBottom: Float
    public var style: SplitStyle
    public var top: Top
    public var bottom: Bottom

    /// Split driven by app state, so it can be persisted or set from elsewhere.
    public init(
        fraction: Binding<Float>,
        minTop: Float = 60,
        minBottom: Float = 60,
        style: SplitStyle = SplitStyle(),
        @ViewBuilder top: () -> Top,
        @ViewBuilder bottom: () -> Bottom
    ) {
        self.fraction = fraction
        self.initialFraction = fraction.wrappedValue
        self.minTop = minTop
        self.minBottom = minBottom
        self.style = style
        self.top = top()
        self.bottom = bottom()
    }

    /// Split owned by the view itself. It survives rebuilds — the node holds it
    /// — but nothing outside can read or restore it.
    public init(
        initialFraction: Float = 0.5,
        minTop: Float = 60,
        minBottom: Float = 60,
        style: SplitStyle = SplitStyle(),
        @ViewBuilder top: () -> Top,
        @ViewBuilder bottom: () -> Bottom
    ) {
        self.fraction = nil
        self.initialFraction = initialFraction
        self.minTop = minTop
        self.minBottom = minBottom
        self.style = style
        self.top = top()
        self.bottom = bottom()
    }

    public var dumpDetail: String {
        "fraction=\(fraction?.wrappedValue ?? initialFraction)"
    }

    public func structureLines(indent: Int = 0) -> [String] {
        Dump.structureLines(
            indent: indent, label: "VSplitView \(dumpDetail)",
            childLines: [
                top.structureLines(indent: indent + 1),
                bottom.structureLines(indent: indent + 1),
            ]
        )
    }

    public func mountPrimitive() -> any AnyViewNode {
        SplitNode.mount(
            axis: .vertical, fraction: fraction, initialFraction: initialFraction,
            minFirst: minTop, minSecond: minBottom, style: style,
            first: top, second: bottom
        )
    }

    public func reconcilePrimitive(_ node: any AnyViewNode) -> any AnyViewNode {
        SplitNode.reconcile(
            node, axis: .vertical, fraction: fraction,
            initialFraction: initialFraction,
            minFirst: minTop, minSecond: minBottom, style: style,
            first: top, second: bottom
        )
    }
}

/// Two side-by-side panes with a draggable divider between them.
///
/// `VSplitView` on the other axis, and everything documented there holds here
/// with widths in place of heights: the split is a fraction of the shared
/// width, `minLeading` / `minTrailing` are where the drag stops, and a pane
/// that should fill its width needs to say so.
///
/// ```swift
/// HSplitView(fraction: $sidebarSplit, minLeading: 180, minTrailing: 320) {
///     fileList
/// } trailing: {
///     EditorView(text: $text).flexGrow(1)
/// }
/// ```
public struct HSplitView<Leading: View, Trailing: View>: PrimitiveView {
    public var fraction: Binding<Float>?
    public var initialFraction: Float
    public var minLeading: Float
    public var minTrailing: Float
    public var style: SplitStyle
    public var leading: Leading
    public var trailing: Trailing

    public init(
        fraction: Binding<Float>,
        minLeading: Float = 80,
        minTrailing: Float = 80,
        style: SplitStyle = SplitStyle(),
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.fraction = fraction
        self.initialFraction = fraction.wrappedValue
        self.minLeading = minLeading
        self.minTrailing = minTrailing
        self.style = style
        self.leading = leading()
        self.trailing = trailing()
    }

    public init(
        initialFraction: Float = 0.5,
        minLeading: Float = 80,
        minTrailing: Float = 80,
        style: SplitStyle = SplitStyle(),
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.fraction = nil
        self.initialFraction = initialFraction
        self.minLeading = minLeading
        self.minTrailing = minTrailing
        self.style = style
        self.leading = leading()
        self.trailing = trailing()
    }

    public var dumpDetail: String {
        "fraction=\(fraction?.wrappedValue ?? initialFraction)"
    }

    public func structureLines(indent: Int = 0) -> [String] {
        Dump.structureLines(
            indent: indent, label: "HSplitView \(dumpDetail)",
            childLines: [
                leading.structureLines(indent: indent + 1),
                trailing.structureLines(indent: indent + 1),
            ]
        )
    }

    public func mountPrimitive() -> any AnyViewNode {
        SplitNode.mount(
            axis: .horizontal, fraction: fraction,
            initialFraction: initialFraction,
            minFirst: minLeading, minSecond: minTrailing, style: style,
            first: leading, second: trailing
        )
    }

    public func reconcilePrimitive(_ node: any AnyViewNode) -> any AnyViewNode {
        SplitNode.reconcile(
            node, axis: .horizontal, fraction: fraction,
            initialFraction: initialFraction,
            minFirst: minLeading, minSecond: minTrailing, style: style,
            first: leading, second: trailing
        )
    }
}

/// Colours and metrics for a split divider.
public struct SplitStyle {
    /// Thickness of the whole divider — the strip the pointer has to hit.
    /// Bigger than the rule it draws, because a 1px grab target is a 1px grab
    /// target.
    public var thickness: Float
    /// The rule drawn down the middle of that strip.
    public var lineThickness: Float
    public var color: Color
    /// Hover tint target. The renderer paints this one (see `hoverFill`), so
    /// pointing at the divider costs no round trip.
    public var hover: Color
    /// Fill while the divider is being dragged. Unlike the hover tint this is
    /// producer-drawn: a fast drag leaves the pointer behind, and renderer
    /// hover would drop out exactly when the feedback matters most.
    public var active: Color

    public init(
        thickness: Float = 9,
        lineThickness: Float? = nil,
        color: Color? = nil,
        hover: Color? = nil,
        active: Color? = nil
    ) {
        let theme = Environment.current.theme
        self.thickness = thickness
        self.lineThickness = lineThickness ?? theme.borderWidth
        self.color = color ?? theme.border
        self.hover = hover ?? theme.hover
        self.active = active ?? theme.accent.opacity(0.35)
    }
}

// MARK: - Node

/// Which way the panes are stacked (**not** the divider's own direction: a
/// `.vertical` split is dragged up and down and draws a horizontal rule).
enum SplitAxis: Equatable {
    case vertical
    case horizontal
}

/// Container whose two children divide its main axis by flex factor.
///
/// Not a `StackNode` with a `Divider` in it: the drag has to convert pointer
/// pixels into a fraction of the pane span and write the result somewhere that
/// survives to the next layout — and both of those are questions only the box
/// that owns both panes can answer.
final class SplitNode: YogaBoxNode {
    let axis: SplitAxis
    private(set) var firstNode: any AnyViewNode
    private(set) var secondNode: any AnyViewNode
    /// Built here rather than mounted from a view: it has no content, and
    /// owning it outright means the drag handler is installed once.
    let handle: LeafNode

    private(set) var fraction: Float
    var minFirst: Float
    var minSecond: Float
    var style: SplitStyle {
        didSet { applyHandleStyle() }
    }
    /// Writes the fraction back to the app's binding, on release only.
    var onCommit: ((Float) -> Void)?

    private(set) var isDragging = false
    private var insertedLeaves: [any AnyViewNode] = []

    init(
        axis: SplitAxis,
        fraction: Float,
        minFirst: Float,
        minSecond: Float,
        style: SplitStyle,
        first: any AnyViewNode,
        second: any AnyViewNode
    ) {
        self.axis = axis
        self.fraction = min(max(0, fraction), 1)
        self.minFirst = minFirst
        self.minSecond = minSecond
        self.style = style
        self.firstNode = first
        self.secondNode = second
        self.handle = LeafNode(
            kind: .divider, label: "SplitHandle",
            width: axis == .vertical ? .auto : .point(style.thickness),
            height: axis == .vertical ? .point(style.thickness) : .auto
        )
        super.init(label: axis == .vertical ? "VSplitView" : "HSplitView")
        YGNodeStyleSetFlexDirection(
            yogaStorage,
            axis == .vertical ? YGFlexDirectionColumn : YGFlexDirectionRow
        )
        YGNodeStyleSetAlignItems(yogaStorage, YGAlignStretch)
        // The split fills whatever it is given: a divider that can be dragged
        // needs a definite span to be a fraction *of*.
        flexGrow = 1
        applyStyle()
        applyHandleStyle()
        installDrag()
        relink()
        applyPaneFlex()
    }

    override var childNodes: [any AnyViewNode] { [firstNode, handle, secondNode] }

    func updatePanes(first: any AnyViewNode, second: any AnyViewNode) {
        firstNode = first
        secondNode = second
        applyHandleStyle()
        relink()
        applyPaneFlex()
    }

    /// Takes a value the app set. Ignored mid-drag: the hand is the source of
    /// truth until it lets go, and a body running for an unrelated reason
    /// would otherwise snap the divider back to the last committed value.
    func adopt(fraction value: Float) {
        guard !isDragging else { return }
        let next = min(max(0, value), 1)
        guard next != fraction else { return }
        fraction = next
        applyPaneFlex()
    }

    // MARK: geometry

    private func mainExtent(_ node: YGNodeRef) -> Float {
        axis == .vertical
            ? YGNodeLayoutGetHeight(node)
            : YGNodeLayoutGetWidth(node)
    }

    /// Points the two panes divide between them.
    ///
    /// Read from what Yoga granted the panes, not from this node's own box, so
    /// padding and the divider itself are already accounted for. Falls back to
    /// the box minus the divider before the first layout, when a press can
    /// still arrive (via the agent, or a synthesized event).
    private var paneSpan: Float {
        let laidOut = paneBoxes.reduce(Float(0)) { total, box in
            total + (box.yoga.map { mainExtent($0) } ?? 0)
        }
        if laidOut > 0 { return laidOut }
        return max(1, mainExtent(yogaStorage) - style.thickness)
    }

    private var paneBoxes: [YogaBoxNode] {
        [firstNode, secondNode].compactMap {
            $0.flattenedLayoutNodes().first as? YogaBoxNode
        }
    }

    /// Clamps a requested fraction against both floors.
    ///
    /// When the panes cannot both have their minimum — a window smaller than
    /// `minFirst + minSecond` — the floors are dropped rather than applied,
    /// since applying them there inverts the range and would pin the divider
    /// to whichever end the arithmetic happened to produce.
    private func clamp(_ requested: Float) -> Float {
        let span = paneSpan
        guard span > minFirst + minSecond else {
            return min(max(0, requested), 1)
        }
        return min(max(requested, minFirst / span), 1 - minSecond / span)
    }

    /// The drag's write path: flex factors onto the panes, layout requested,
    /// no body. See `VSplitView`'s doc comment.
    func setFraction(_ requested: Float) {
        let next = clamp(requested)
        guard next != fraction else { return }
        fraction = next
        applyPaneFlex()
        ViewInvalidation.markNeedsLayout()
    }

    private func applyPaneFlex() {
        let boxes = paneBoxes
        guard boxes.count == 2 else { return }
        let names = axis == .vertical
            ? ("SplitTop", "SplitBottom")
            : ("SplitLeading", "SplitTrailing")
        apply(grow: fraction, to: boxes[0], label: names.0)
        apply(grow: 1 - fraction, to: boxes[1], label: names.1)
    }

    /// The minimums are deliberately *not* Yoga `minHeight`s. A floor at that
    /// level is part of flex resolution — it becomes each pane's base size and
    /// only the leftover is divided — so a 25% split of 400pt with two 60pt
    /// floors lays out at 130/270 rather than 100/300. Here the fraction means
    /// the fraction, and the floors are what the *drag* stops at.
    private func apply(grow: Float, to box: YogaBoxNode, label: String) {
        box.label = label
        box.flexGrow = grow
        // Nothing of the pane's own content contributes to its size: the two
        // factors are meant to divide the *whole* span, and a basis taken from
        // content would divide only what content left over.
        if let y = box.yoga { YGNodeStyleSetFlexBasis(y, 0) }
        // A pane that has been dragged smaller than its content clips it,
        // rather than painting over its neighbour.
        box.clipsContent = true
        box.applyStyle()
    }

    private func applyHandleStyle() {
        handle.theme = Environment.current.theme
        handle.width = axis == .vertical ? .auto : .point(style.thickness)
        handle.height = axis == .vertical ? .point(style.thickness) : .auto
        handle.dividerStyle = DividerStyle(
            thickness: style.lineThickness, spacing: 0, color: style.color
        )
        // Stated rather than inferred from the owner: the rule runs across the
        // split, so it is perpendicular to the axis the panes stack on.
        handle.dividerAxis = axis == .vertical ? .horizontal : .vertical
        // A divider that shrank would vanish, and this one is also the control.
        handle.flexShrink = 0
        handle.fillColor = isDragging ? style.active : nil
        handle.hoverFill = style.hover
        handle.cursor = axis == .vertical ? .resizeUpDown : .resizeLeftRight
        handle.applyStyle()
    }

    // MARK: drag

    private func installDrag() {
        handle.onClickLocal = { [weak self] localX, localY, originX, originY, _, _ in
            guard let self else { return }
            // Where the pointer took hold, in the same space `PointerCapture`
            // reports moves in — a delta from here cancels any constant offset
            // between the hit test and the capture, which is why the press
            // point is carried in the closure rather than re-derived.
            let press = self.axis == .vertical ? originY + localY : originX + localX
            let startFraction = self.fraction
            let span = self.paneSpan
            self.isDragging = true
            self.applyHandleStyle()
            PointerCapture.capture(
                self.handle.id,
                onMove: { [weak self] windowX, windowY in
                    guard let self else { return }
                    let now = self.axis == .vertical ? windowY : windowX
                    self.setFraction(startFraction + (now - press) / span)
                },
                onUp: { [weak self] in
                    guard let self else { return }
                    self.isDragging = false
                    self.applyHandleStyle()
                    // The one write to app state per drag. Everything before
                    // this lived on the node.
                    self.onCommit?(self.fraction)
                    ViewInvalidation.markNeedsRedraw()
                }
            )
        }
    }

    // MARK: tree

    private func relink() {
        var leaves = firstNode.flattenedLayoutNodes()
        leaves.append(handle)
        leaves.append(contentsOf: secondNode.flattenedLayoutNodes())
        guard yogaChildrenChanged(leaves, insertedLeaves) else { return }
        YGNodeRemoveAllChildren(yogaStorage)
        insertedLeaves = leaves
        for (i, leaf) in leaves.enumerated() {
            guard let y = leaf.yoga else { continue }
            YGNodeInsertChild(yogaStorage, y, i)
        }
    }

    override func collectChildFrames(
        originX: Float, originY: Float, into frames: inout [LayoutFrame]
    ) {
        firstNode.collectFrames(originX: originX, originY: originY, into: &frames)
        handle.collectFrames(originX: originX, originY: originY, into: &frames)
        secondNode.collectFrames(originX: originX, originY: originY, into: &frames)
    }
}

// MARK: - Mount / reconcile shared by both axes

extension SplitNode {
    /// A pane is a column so that a multi-statement builder stacks the way the
    /// same statements would in a `VStack` — on either axis: the panes of a
    /// horizontal split are side-by-side *columns*. `flexGrow` carries the
    /// split; with a flex basis of 0 the two factors divide the space left
    /// over after the divider, exactly.
    private static func pane<Content: View>(
        _ content: Content, grow: Float
    ) -> VStack<Content> {
        VStack(flexGrow: grow) { content }
    }

    static func mount<First: View, Second: View>(
        axis: SplitAxis,
        fraction: Binding<Float>?,
        initialFraction: Float,
        minFirst: Float,
        minSecond: Float,
        style: SplitStyle,
        first: First,
        second: Second
    ) -> any AnyViewNode {
        let node = SplitNode(
            axis: axis,
            fraction: initialFraction,
            minFirst: minFirst,
            minSecond: minSecond,
            style: style,
            first: ViewGraph.mount(pane(first, grow: initialFraction)),
            second: ViewGraph.mount(pane(second, grow: 1 - initialFraction))
        )
        node.onCommit = commit(fraction)
        return node
    }

    static func reconcile<First: View, Second: View>(
        _ node: any AnyViewNode,
        axis: SplitAxis,
        fraction: Binding<Float>?,
        initialFraction: Float,
        minFirst: Float,
        minSecond: Float,
        style: SplitStyle,
        first: First,
        second: Second
    ) -> any AnyViewNode {
        // An axis change is a different container, not a reconfigured one.
        guard let split = node as? SplitNode, split.axis == axis else {
            return mount(
                axis: axis, fraction: fraction, initialFraction: initialFraction,
                minFirst: minFirst, minSecond: minSecond, style: style,
                first: first, second: second
            )
        }
        // The node is the live value while a drag is in flight; an external
        // write is adopted only when it is not fighting the hand.
        if let fraction {
            split.adopt(fraction: fraction.wrappedValue)
        }
        split.onCommit = commit(fraction)
        split.minFirst = minFirst
        split.minSecond = minSecond
        split.style = style
        let f = split.fraction
        split.updatePanes(
            first: ViewGraph.reconcile(split.firstNode, with: pane(first, grow: f)),
            second: ViewGraph.reconcile(
                split.secondNode, with: pane(second, grow: 1 - f)
            )
        )
        return split
    }

    private static func commit(_ fraction: Binding<Float>?) -> ((Float) -> Void)? {
        guard let fraction else { return nil }
        return { fraction.wrappedValue = $0 }
    }
}
