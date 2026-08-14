import CYoga
import Foundation

/// Where composed overlay content sits inside its base view's box.
public enum OverlayAnchor: Equatable, Sendable {
    case topLeading, top, topTrailing
    case leading, center, trailing
    case bottomLeading, bottom, bottomTrailing

    /// Horizontal placement, as main-axis justification of a row container.
    var justify: YGJustify {
        switch self {
        case .topLeading, .leading, .bottomLeading: return YGJustifyFlexStart
        case .top, .center, .bottom: return YGJustifyCenter
        case .topTrailing, .trailing, .bottomTrailing: return YGJustifyFlexEnd
        }
    }

    /// Vertical placement, as cross-axis alignment of a row container.
    var align: YGAlign {
        switch self {
        case .topLeading, .top, .topTrailing: return YGAlignFlexStart
        case .leading, .center, .trailing: return YGAlignCenter
        case .bottomLeading, .bottom, .bottomTrailing: return YGAlignFlexEnd
        }
    }
}

/// A base view with content drawn over it, taking no layout space.
///
/// Distinct from `overlay(isPresented:)`, which is a *popup*: that one detaches
/// its subtree, emits it after the whole tree walk to escape clipping, takes
/// input priority, and dismisses on an outside click. Those semantics are right
/// for a menu and wrong for anything permanent — an always-present button
/// presented that way makes the window behave like an open menu, swallowing
/// clicks that land anywhere else.
///
/// This is the composition variant: a floating action button, a badge on a
/// corner, a control that belongs *on* a canvas rather than beside it. It is an
/// absolutely positioned Yoga child, which buys all four required behaviours
/// from the layout engine rather than from special cases:
///
/// - **No layout contribution.** An absolute child is not part of its parent's
///   flex flow, so the base view measures exactly as it did without the overlay.
/// - **Painted above.** Emission is in `childNodes` order and the overlay is
///   declared second, so it lands on top of the base.
/// - **Ordinary hit testing.** It is a real node with real geometry; the hit
///   walk visits children in reverse, so the overlay is tested before the base
///   and everything else behaves normally. No priority, no dismissal.
/// - **Anchored.** Yoga edge insets do the placement, so it survives resizes
///   without a re-layout pass of its own.
public struct ComposedOverlayView<Content: View, OverlayContent: View>: PrimitiveView {
    public var content: Content
    public var overlayContent: OverlayContent
    public var anchor: OverlayAnchor
    public var inset: Float
    /// Panel styling for the floating surface, or nil to draw no surface at
    /// all — a bare badge or button that is only its own content.
    ///
    /// Optional here and not in `OverlayView` because the two have different
    /// defaults for good reason. A popup is a *surface* by definition: a menu
    /// with no plate under it is unreadable over whatever it covers. Composed
    /// content is usually already a styled thing of its own, and giving it a
    /// theme-coloured plate it never asked for would put a rectangle behind
    /// every floating button in the codebase.
    public var style: OverlayStyle?

    public init(
        content: Content,
        overlayContent: OverlayContent,
        anchor: OverlayAnchor,
        inset: Float,
        style: OverlayStyle? = nil
    ) {
        self.content = content
        self.overlayContent = overlayContent
        self.anchor = anchor
        self.inset = inset
        self.style = style
    }

    public var dumpDetail: String { "overlay \(anchor)" }

    public func structureLines(indent: Int = 0) -> [String] {
        Dump.structureLines(
            indent: indent, label: "ComposedOverlay \(anchor)",
            childLines: [
                content.structureLines(indent: indent + 1),
                overlayContent.structureLines(indent: indent + 1),
            ]
        )
    }

    public func mountPrimitive() -> any AnyViewNode {
        let overlay = StyleBoxNode(content: ViewGraph.mount(overlayContent))
        let plate = StyleBoxNode(content: overlay)
        let node = ComposedOverlayNode(
            content: ViewGraph.mount(content),
            overlay: overlay,
            plateBox: plate,
            alignmentBox: StyleBoxNode(content: plate)
        )
        node.apply(anchor: anchor, inset: inset, style: style)
        return node
    }

    public func reconcilePrimitive(_ node: any AnyViewNode) -> any AnyViewNode {
        guard let box = node as? ComposedOverlayNode else { return mountPrimitive() }
        box.updateContent(ViewGraph.reconcile(box.contentNode, with: content))
        box.overlayBox.updateContent(
            ViewGraph.reconcile(box.overlayBox.contentNode, with: overlayContent)
        )
        box.apply(anchor: anchor, inset: inset, style: style)
        return box
    }
}

final class ComposedOverlayNode: YogaBoxNode {
    private(set) var contentNode: any AnyViewNode
    /// Sizes to the overlay content, and carries the panel's own fill.
    let overlayBox: StyleBoxNode
    /// Draws the outline, one pixel proud on every side, and carries the
    /// backdrop-blur scope.
    ///
    /// A stroke the SDF pipeline cannot draw, done as a filled box a pixel
    /// larger with the panel's own fill covering its middle — the same trick
    /// `emitTree` plays for a detached overlay, as a node rather than as a
    /// hand-emitted rect, because a composed overlay has no post-walk hook to
    /// emit anything from.
    ///
    /// The blur belongs here rather than on `overlayBox` for a reason worth
    /// stating: a scope frosts what was painted *before* it opens, so opening
    /// it one box out puts both the outline and the panel fill inside the
    /// scope, and they stay sharp on top of the frost. A detached overlay
    /// cannot do this — its outline is emitted before the hoisted scope — which
    /// is why that path drops the border for glass panels and this one keeps it.
    let plateBox: StyleBoxNode
    /// Absolute, pinned to all four edges so it exactly covers the base box,
    /// and holds `overlayBox`.
    ///
    /// The indirection exists because Yoga will not centre an absolutely
    /// positioned node: setting auto margins on one leaves it pinned to the
    /// leading edge — measured, not assumed. Covering the base with a
    /// full-size absolute container and then using *ordinary* flex alignment
    /// inside it places all nine anchors with one well-trodden mechanism.
    let alignmentBox: StyleBoxNode
    private var insertedLeaves: [any AnyViewNode] = []

    init(
        content: any AnyViewNode, overlay: StyleBoxNode,
        plateBox: StyleBoxNode, alignmentBox: StyleBoxNode
    ) {
        self.contentNode = content
        self.overlayBox = overlay
        self.plateBox = plateBox
        self.alignmentBox = alignmentBox
        super.init(label: "Overlay")
        YGNodeStyleSetFlexDirection(yogaStorage, YGFlexDirectionColumn)
        YGNodeStyleSetAlignItems(yogaStorage, YGAlignStretch)
        inheritFlex(from: content)
        applyStyle()
        relink()
    }

    /// Overlay last, so it paints above the base and is hit-tested before it.
    override var childNodes: [any AnyViewNode] { [contentNode, alignmentBox] }

    func updateContent(_ node: any AnyViewNode) {
        contentNode = node
        inheritFlex(from: node)
        relink()
    }

    /// The wrapper must not become more rigid than what it wraps — the same
    /// trap `StyleBoxNode` documents. Measured from the *content* only: the
    /// overlay is out of flow and its flex means nothing here.
    private func inheritFlex(from node: any AnyViewNode) {
        let leaves = node.flattenedLayoutNodes().compactMap { $0 as? YogaBoxNode }
        flexGrow = leaves.map(\.flexGrow).max() ?? 0
        flexShrink = leaves.map(\.effectiveFlexShrink).min()
    }

    func apply(anchor: OverlayAnchor, inset: Float, style: OverlayStyle?) {
        guard let container = alignmentBox.yoga else { return }

        // Out of flow, and stretched across the base box: defining both edges
        // of an axis is what makes an absolute node fill it. This is the whole
        // reason the base view measures the same with an overlay as without.
        YGNodeStyleSetPositionType(container, YGPositionTypeAbsolute)
        for edge in [YGEdgeLeft, YGEdgeRight, YGEdgeTop, YGEdgeBottom] {
            YGNodeStyleSetPosition(container, edge, 0)
        }
        // Inset every side. On a pinned edge it is the gap the caller asked
        // for; on a centred axis it only shrinks the box the content is
        // centred in, which is why a centred axis ignores it.
        //
        // Set through the node, not `YGNodeStyleSetPadding` directly:
        // `applyStyle` below re-asserts padding from this property and would
        // otherwise overwrite a raw call with zero.
        alignmentBox.padding = .all(inset)
        alignmentBox.flexGrow = 0
        alignmentBox.flexShrink = 0
        alignmentBox.applyStyle()
        // `applyStyle` re-asserts the box's own flex direction and alignment,
        // so the anchor has to win afterwards.
        YGNodeStyleSetFlexDirection(container, YGFlexDirectionRow)
        YGNodeStyleSetJustifyContent(container, anchor.justify)
        YGNodeStyleSetAlignItems(container, anchor.align)

        // The outline, or nothing at all: a nil fill paints no rect, so an
        // unstyled overlay pays one Yoga node and no draw command for a box
        // that is exactly its content's size. Kept in the chain either way
        // rather than inserted on demand — a node appearing and vanishing with
        // a style is a reconcile identity problem, and this is one box.
        let border = style?.plateBorder
        plateBox.fillColor = border
        // Even with no drawable plate, this node owns the backdrop scope and
        // therefore has to retain the panel shape that clips the frost.
        plateBox.cornerRadius = border != nil
            ? (style?.cornerRadius ?? 0) + 1
            : (style?.cornerRadius ?? 0)
        plateBox.padding = border != nil ? .all(1) : .zero
        plateBox.backdropBlurRadius = style?.backdropBlurRadius

        // A floating surface sizes to its content. `StyleBoxNode.inheritFlex`
        // copies flex from what it wraps, so this has to be cleared after every
        // update or a wrapped `Spacer` would try to grow inside nothing. Both
        // boxes: only `overlayBox` gets an `updateContent`, but `plateBox`
        // inherited its flex from that box back when it was mounted.
        for box in [plateBox, overlayBox] {
            box.flexGrow = 0
            box.flexShrink = 0
            box.width = .auto
            box.height = .auto
        }
        overlayBox.fillColor = style?.background
        overlayBox.cornerRadius = style?.cornerRadius ?? 0
        overlayBox.padding = .all(style?.padding ?? 0)
        overlayBox.minWidth = style?.minWidth ?? 0
        overlayBox.applyStyle()
        plateBox.applyStyle()
    }

    private func relink() {
        let leaves = contentNode.flattenedLayoutNodes()
        // `alignmentBox` is this node's own and never changes identity, so the
        // content list alone decides. See `yogaChildrenChanged`.
        guard yogaChildrenChanged(leaves, insertedLeaves) else { return }
        YGNodeRemoveAllChildren(yogaStorage)
        insertedLeaves = leaves
        var index = 0
        for leaf in insertedLeaves {
            guard let y = leaf.yoga else { continue }
            YGNodeInsertChild(yogaStorage, y, index)
            index += 1
        }
        // Inserted last so paint order matches declaration order. Being
        // absolute, its position in the child list does not affect the flow.
        if let y = alignmentBox.yoga {
            YGNodeInsertChild(yogaStorage, y, index)
        }
    }

    override func collectChildFrames(
        originX: Float, originY: Float, into frames: inout [LayoutFrame]
    ) {
        contentNode.collectFrames(originX: originX, originY: originY, into: &frames)
        alignmentBox.collectFrames(originX: originX, originY: originY, into: &frames)
    }
}

extension View {
    /// Draws `content` over this view, taking no layout space.
    ///
    /// The composition overlay, as distinct from `overlay(isPresented:)`, which
    /// is a modal popup. Interaction underneath is unaffected: this imposes no
    /// input priority and no outside-click dismissal, so it suits a floating
    /// button, a badge, or an in-canvas control that is simply always there.
    ///
    /// `inset` insets from the anchored edges; a centred axis ignores it.
    ///
    /// `style` draws a panel under the content — fill, outline, corner radius,
    /// padding and frosted backdrop, the same `OverlayStyle` the presented
    /// overlay takes. Omitted, the content floats bare, which is what a badge
    /// or an already-styled button wants; the ordinary modifiers still work on
    /// whatever is inside the closure, so this is convenience rather than the
    /// only way to paint one.
    public func overlay<OverlayContent: View>(
        alignment: OverlayAnchor,
        inset: Float = 0,
        style: OverlayStyle? = nil,
        @ViewBuilder content: () -> OverlayContent
    ) -> ComposedOverlayView<Self, OverlayContent> {
        ComposedOverlayView(
            content: self,
            overlayContent: content(),
            anchor: alignment,
            inset: inset,
            style: style
        )
    }
}
