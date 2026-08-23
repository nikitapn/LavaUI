import CYoga
import Foundation

/// Style a modifier pushes onto a node.
///
/// Every field is optional and merging is **per field**: whole-struct
/// replacement would let the last modifier in a chain silently clear the
/// others, which the spike caught before it could become a bug report.
public struct ViewStyle: Equatable {
    /// Per-edge inset. `nil` means "leave the node's baseline alone".
    public var padding: EdgeInsets?
    public var fill: Color?
    /// A two-stop linear fill, which wins over `fill` when both are set.
    ///
    /// Separate rather than making `fill` an enum: `fill` is read in a dozen
    /// places that only ever want a flat colour, and widening it would make
    /// every one of them handle a case it has no use for.
    public var fillGradient: Gradient?
    public var hoverFill: Color?
    public var cornerRadius: Float?
    public var width: Dimension?
    public var height: Dimension?
    public var minWidth: Float?
    public var minHeight: Float?
    public var flexGrow: Float?
    public var flexShrink: Float?
    /// Backdrop blur radius in pixels under this node's rect. `nil` = off.
    /// Emits `BeginBackdropBlur` / `EndBackdropBlur` around the node's paint
    /// so earlier UI is frosted and this node's fill + children stay sharp.
    public var backdropBlurRadius: Float?
    /// Content blur radius in pixels. `nil` = off. Blurs this node's own paint,
    /// the way SwiftUI's `.blur()` does, rather than what is behind it.
    public var contentBlurRadius: Float?
    /// Scissor paint to this node's layout rect (SwiftUI `.clipped()`).
    public var clipsContent: Bool?
    /// Take this subtree out of layout and drawing without unmounting it.
    /// `nil` = visible. See `View.hidden(_:)`.
    public var isHidden: Bool?
    /// Pointer image over this view. `nil` inherits. See `View.cursor(_:)`.
    public var cursor: CursorShape?

    public init() {}

    /// `self` wins where both define a field.
    ///
    /// **Every field has to be listed here.** `out` starts empty, so a field
    /// left out is not merged conservatively — it is dropped, from both sides,
    /// silently. `.frame().background(gradient)` is two styles that merge, and
    /// omitting `fillGradient` here meant the gradient vanished while the flat
    /// `fill` beside it survived: a box that should have been a red-to-black
    /// ramp drew solid red, with nothing wrong anywhere else to point at.
    func merged(over base: ViewStyle) -> ViewStyle {
        var out = ViewStyle()
        out.padding = padding ?? base.padding
        out.fill = fill ?? base.fill
        out.fillGradient = fillGradient ?? base.fillGradient
        out.hoverFill = hoverFill ?? base.hoverFill
        out.cornerRadius = cornerRadius ?? base.cornerRadius
        out.width = width ?? base.width
        out.height = height ?? base.height
        out.minWidth = minWidth ?? base.minWidth
        out.minHeight = minHeight ?? base.minHeight
        out.flexGrow = flexGrow ?? base.flexGrow
        out.flexShrink = flexShrink ?? base.flexShrink
        out.backdropBlurRadius = backdropBlurRadius ?? base.backdropBlurRadius
        out.contentBlurRadius = contentBlurRadius ?? base.contentBlurRadius
        out.clipsContent = clipsContent ?? base.clipsContent
        out.isHidden = isHidden ?? base.isHidden
        out.cursor = cursor ?? base.cursor
        return out
    }
}

/// A view wearing a style.
///
/// The style lands on the content's *existing* node whenever that content is a
/// single box, so `.padding().background().cornerRadius()` costs no extra Yoga
/// nodes. Only a fragment — a `TupleView`, `ForEach` or conditional, which has
/// no single node to style — materialises a wrapper.
///
/// Modifier order is preserved where it changes layout: padding applied after
/// an existing modifier materialises one outer box. Paint-only modifiers on
/// the same side of that boundary still collapse, avoiding SwiftUI's cost of a
/// wrapper for every modifier.
public struct ModifiedView<Content: View>: PrimitiveView {
    public var content: Content
    public var style: ViewStyle
    /// Some modifier boundaries are layout-significant. In particular,
    /// `.frame(...).padding(...)` needs an outer Yoga box: putting both values
    /// on one node makes the fixed frame consume the padding instead of
    /// surrounding it.
    var forceWrapper: Bool

    public init(content: Content, style: ViewStyle, forceWrapper: Bool = false) {
        self.content = content
        self.style = style
        self.forceWrapper = forceWrapper
    }

    public var dumpDetail: String { "styled" }

    public func structureLines(indent: Int = 0) -> [String] {
        Dump.structureLines(
            indent: indent, label: "Modified",
            childLines: [content.structureLines(indent: indent + 1)]
        )
    }

    public func mountPrimitive() -> any AnyViewNode {
        attach(style, to: ViewGraph.mount(content))
    }

    public func reconcilePrimitive(_ node: any AnyViewNode) -> any AnyViewNode {
        if let box = node as? StyleBoxNode, ownsWrapper(box) {
            // This wrapper is ours. Reconcile inside; if the content
            // collapsed to a single box we could unwrap, but keeping the
            // box is stable and avoids churning Yoga's tree on every frame.
            box.updateContent(ViewGraph.reconcile(box.contentNode, with: content))
            box.applyViewStyle(style)
            return box
        }
        return attach(style, to: ViewGraph.reconcile(node, with: content))
    }

    /// Whether `box` was created by *this* modifier, not an inner one.
    ///
    /// `.hidden()` / `.frame()` apply in-place to any Yoga box, including a
    /// `StyleBox` an inner `.background()` just made. The next reconcile
    /// used to treat that box as this modifier's wrapper, then wrap the
    /// still-parented content again — Yoga fatal on `YGNodeInsertChild`.
    /// A box is ours only if we would have had to create one.
    private func ownsWrapper(_ box: StyleBoxNode) -> Bool {
        box.modifierOwner == ObjectIdentifier(Content.self)
    }

    /// Style the node if it is a single box that can show the style; otherwise
    /// wrap it once.
    private func attach(_ style: ViewStyle, to node: any AnyViewNode) -> any AnyViewNode {
        if !forceWrapper, let box = node as? YogaBoxNode, Self.canPaint(style, on: box) {
            box.applyViewStyle(style)
            return box
        }
        let wrapper = StyleBoxNode(content: node)
        // Ownership is a retained fact, not something reconcile can infer
        // from today's content. A paint-less modifier around a composite has
        // to wrap on mount because the composite has no Yoga node, but once
        // that wrapper exists `canPaint` sees a StyleBox and says no wrapper
        // is needed. Treating that answer as ownership remounts the content
        // on the next body pass and strands focus on its discarded node.
        //
        // Static content types distinguish adjacent modifier boundaries:
        // `.background().hidden()` has a different `Content` at each layer,
        // so the outer modifier cannot steal the inner one's box.
        wrapper.modifierOwner = ObjectIdentifier(Content.self)
        wrapper.applyViewStyle(style)
        return wrapper
    }

    /// Whether `node` can actually show the paint `style` is asking for.
    ///
    /// Not every `YogaBoxNode` can. A fill and a corner radius are declared by
    /// `LeafNode`, `StackNode` and `StyleBoxNode` separately — `applyViewStyle`
    /// has one branch each — so a box that is none of those (`ScrollNode`, and
    /// the wrappers overlays and transitions build) accepted the style and
    /// silently dropped the half of it that paints. The failure looked like a
    /// missing background with nothing wrong anywhere: no warning, no crash,
    /// and the padding from the same modifier chain arrived normally.
    ///
    /// Wrapping in that case costs one box, and only in the case that used to
    /// lose the fill. Layout is unchanged because `StyleBoxNode` inherits flex
    /// from what it wraps.
    private static func canPaint(_ style: ViewStyle, on node: any AnyViewNode) -> Bool {
        if style.fill == nil, style.fillGradient == nil, style.hoverFill == nil,
           style.cornerRadius == nil {
            return true
        }
        return node is LeafNode || node is StackNode || node is StyleBoxNode
    }
}

// MARK: - Applying a style to a node

extension YogaBoxNode {
    /// Applies `style` over the node's own settings.
    ///
    /// The first application records a baseline, and every later one re-applies
    /// `style` over that baseline rather than over the previous result. Without
    /// it, removing a modifier would leave its effect behind for any field the
    /// content does not set for itself each reconcile — `padding` being the
    /// obvious one.
    func applyViewStyle(_ style: ViewStyle) {
        if styleBaseline == nil {
            var base = ViewStyle()
            base.padding = padding
            base.width = width
            base.height = height
            base.minWidth = minWidth
            base.minHeight = minHeight
            base.flexGrow = flexGrow
            base.flexShrink = flexShrink
            base.backdropBlurRadius = backdropBlurRadius
            base.contentBlurRadius = contentBlurRadius
            base.clipsContent = clipsContent
            base.isHidden = isHidden
            base.cursor = cursor
            styleBaseline = base
        }
        let base = styleBaseline ?? ViewStyle()

        padding = style.padding ?? base.padding ?? .zero
        width = style.width ?? base.width ?? .auto
        height = style.height ?? base.height ?? .auto
        minWidth = style.minWidth ?? base.minWidth ?? 0
        minHeight = style.minHeight ?? base.minHeight ?? 0
        flexGrow = style.flexGrow ?? base.flexGrow ?? 0
        flexShrink = style.flexShrink ?? base.flexShrink
        // Unlike fill (set-if-present), blur clears when the modifier is gone:
        // fall back through the baseline so removing `.blur()` actually turns it off.
        backdropBlurRadius = style.backdropBlurRadius ?? base.backdropBlurRadius
        contentBlurRadius = style.contentBlurRadius ?? base.contentBlurRadius
        clipsContent = style.clipsContent ?? base.clipsContent ?? false
        isHidden = style.isHidden ?? base.isHidden ?? false
        // Through the baseline like blur, not set-if-present like fill:
        // removing `.cursor()` has to give the pointer back to whatever the
        // view is sitting in.
        cursor = style.cursor ?? base.cursor

        if let leaf = self as? LeafNode {
            if let fill = style.fill { leaf.fillColor = fill }
            if let g = style.fillGradient { leaf.fillGradient = g }
            if let hover = style.hoverFill { leaf.hoverFill = hover }
            if let radius = style.cornerRadius { leaf.cornerRadius = radius }
        } else if let stack = self as? StackNode {
            if let fill = style.fill { stack.fillColor = fill }
            if let g = style.fillGradient { stack.fillGradient = g }
            if let hover = style.hoverFill { stack.hoverFill = hover }
            if let radius = style.cornerRadius { stack.cornerRadius = radius }
        } else if let box = self as? StyleBoxNode {
            if let fill = style.fill { box.fillColor = fill }
            if let g = style.fillGradient { box.fillGradient = g }
            if let hover = style.hoverFill { box.hoverFill = hover }
            if let radius = style.cornerRadius { box.cornerRadius = radius }
        }
        applyStyle()
    }

    /// A primitive that changes its own size on reconcile has to write that
    /// size into the baseline *before* any modifier re-applies.
    ///
    /// `applyViewStyle` replays over the first snapshot, not over the node as
    /// it is now — that is what lets removing `.frame()` restore the original
    /// rather than leave a stale width. A canvas that grows with its content
    /// updates `width` every pass; without this, `.flexShrink(1)` (or
    /// `.clipped()`, `.cursor()`) writes the *first* width back and the box
    /// never grows. The tab strip stayed one-tab wide after `+` for that
    /// reason.
    func syncLayoutBaseline() {
        guard var base = styleBaseline else { return }
        base.width = width
        base.height = height
        base.minWidth = minWidth
        base.minHeight = minHeight
        base.flexGrow = flexGrow
        styleBaseline = base
    }
}

/// The one box a modifier ever creates: for fragments, which have no single
/// node of their own to carry style.
///
/// Not `final` so `OverlayBoxNode` can inherit it — an overlay presenter needs
/// exactly this (one box wrapping content, relinked on update) plus a detached
/// subtree, and the emitter's `as? StyleBoxNode` branch then covers both.
class StyleBoxNode: YogaBoxNode {
    private(set) var contentNode: any AnyViewNode
    /// Static content type of the `ModifiedView` that created this wrapper.
    /// Nil for style boxes owned by overlays or other framework components.
    var modifierOwner: ObjectIdentifier?
    var fillColor: Color?
    /// Two-stop linear fill; wins over `fillColor` when set.
    var fillGradient: Gradient?
    /// Renderer-side hover chip. Applied here so `.background().hoverBackground()`
    /// still lights up after the first modifier wraps.
    var hoverFill: Color?
    var cornerRadius: Float = 0
    private var insertedLeaves: [any AnyViewNode] = []

    init(content: any AnyViewNode) {
        self.contentNode = content
        super.init(label: "Modified")
        YGNodeStyleSetFlexDirection(yogaStorage, YGFlexDirectionColumn)
        YGNodeStyleSetAlignItems(yogaStorage, YGAlignStretch)
        inheritFlex(from: content)
        applyStyle()
        relink()
    }

    override var childNodes: [any AnyViewNode] { [contentNode] }

    func updateContent(_ node: any AnyViewNode) {
        contentNode = node
        inheritFlex(from: node)
        relink()
    }

    /// Forwards flex from what is wrapped.
    ///
    /// This is the Phase 2 regression in miniature: an interposed box defaults
    /// to `flexGrow = 0`, so a wrapped `Spacer` would stop expanding and the
    /// layout would quietly collapse. Any wrapper added later needs this too.
    private func inheritFlex(from node: any AnyViewNode) {
        let leaves = node.flattenedLayoutNodes().compactMap { $0 as? YogaBoxNode }
        flexGrow = leaves.map(\.flexGrow).max() ?? 0
        // Effective, not raw: an unset child still reports the value Yoga
        // would have seen, so the wrapper does not become more rigid than
        // what it wraps.
        flexShrink = leaves.map(\.effectiveFlexShrink).min()
    }

    private func relink() {
        let leaves = contentNode.flattenedLayoutNodes()
        guard yogaChildrenChanged(leaves, insertedLeaves) else { return }
        YGNodeRemoveAllChildren(yogaStorage)
        insertedLeaves = leaves
        for (i, leaf) in insertedLeaves.enumerated() {
            guard let y = leaf.yoga else { continue }
            // A modifier that claimed the wrong wrapper can still hand us a
            // child that already sits under someone else. Yoga fatal if we
            // insert it anyway; steal it first.
            if let owner = YGNodeGetOwner(y), owner != yogaStorage {
                YGNodeRemoveChild(owner, y)
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

// MARK: - The modifiers themselves

extension View {
    private func styled(_ mutate: (inout ViewStyle) -> Void) -> ModifiedView<Self> {
        var s = ViewStyle()
        mutate(&s)
        return ModifiedView(content: self, style: s)
    }

    /// Uniform inset on every edge.
    public func padding(_ amount: Float) -> ModifiedView<Self> {
        styled { $0.padding = .all(amount) }
    }

    /// Inset only the listed edges by `amount`.
    ///
    /// ```swift
    /// content.padding(.horizontal, 12)
    /// content.padding([.top, .leading], 4)
    /// ```
    public func padding(_ edges: Edge, _ amount: Float) -> ModifiedView<Self> {
        styled { $0.padding = EdgeInsets(edges, amount) }
    }

    /// Fully specified per-edge inset.
    public func padding(_ insets: EdgeInsets) -> ModifiedView<Self> {
        styled { $0.padding = insets }
    }

    public func background(_ color: Color) -> ModifiedView<Self> {
        styled { $0.fill = color }
    }

    /// Fills the box with a two-stop linear ramp instead of a flat colour.
    ///
    /// The start colour is also recorded as the flat `fill`, so anything that
    /// reads a background as one colour — and a renderer too old to know about
    /// gradients — still has an answer.
    public func background(_ gradient: Gradient) -> ModifiedView<Self> {
        styled { $0.fillGradient = gradient; $0.fill = gradient.from }
    }

    public func hoverBackground(_ color: Color) -> ModifiedView<Self> {
        styled { $0.hoverFill = color }
    }

    public func cornerRadius(_ radius: Float) -> ModifiedView<Self> {
        styled { $0.cornerRadius = radius }
    }

    public func frame(
        width: Dimension? = nil, height: Dimension? = nil,
        minWidth: Float? = nil, minHeight: Float? = nil
    ) -> ModifiedView<Self> {
        styled {
            $0.width = width
            $0.height = height
            $0.minWidth = minWidth
            $0.minHeight = minHeight
        }
    }

    public func flexGrow(_ value: Float = 1) -> ModifiedView<Self> {
        styled { $0.flexGrow = value }
    }

    public func flexShrink(_ value: Float) -> ModifiedView<Self> {
        styled { $0.flexShrink = value }
    }

    /// Softens this view and its children.
    ///
    /// The subtree is drawn into an offscreen target of its own, blurred, and
    /// composited back with its own alpha — so a blurred view has a genuinely
    /// soft edge and whatever sits behind it shows through unchanged. This is
    /// the SwiftUI meaning of `.blur()`; for frosted glass, where what is
    /// *behind* the view is what should soften, use `backdropBlur(radius:)`.
    public func blur(radius: Float = 8) -> ModifiedView<Self> {
        styled { $0.contentBlurRadius = max(0.5, radius) }
    }

    /// Frosted-glass backdrop under this view's layout rect.
    ///
    /// Captures UI already painted behind the rect, blurs it, composites the
    /// result, then draws this view's fill and children sharp on top. Typical
    /// use: `.background(Color(...).opacity(0.15)).backdropBlur(radius: 6)` on
    /// a panel or overlay so chrome reads as glass.
    public func backdropBlur(radius: Float = 8) -> ModifiedView<Self> {
        styled { $0.backdropBlurRadius = max(0.5, radius) }
    }

    /// Scissor this view's paint (and its children's) to its layout rect.
    ///
    /// Yoga still sizes children freely; only drawing is clipped. That is
    /// what makes `.frame(width:).clipped()` on a `Text` work: the glyphs
    /// keep their intrinsic width, and the extra ink is cut off rather than
    /// drawn over the next view. Use on fixed chrome such as a menubar so
    /// hover fills cannot spill into content.
    public func clipped() -> ModifiedView<Self> {
        styled { $0.clipsContent = true }
    }

    /// Takes this view out of layout and drawing, without unmounting it.
    ///
    /// The difference from `if condition { view }` is identity. An `if` that
    /// goes false destroys the subtree, and everything keyed to it goes with it
    /// — most visibly the scroll position, which the renderer holds against a
    /// node id that no longer exists when the view comes back. A hidden view
    /// keeps its nodes, so it comes back where it was.
    ///
    /// That is what this is for: alternating panes that should each remember
    /// their own place. It is not a cheaper `if` — the subtree stays mounted,
    /// its state stays alive, and its body still recomputes when what it reads
    /// changes. Yoga skips it (`display: none`, so it occupies nothing rather
    /// than occupying nothing *visibly*) and the draw walk steps over it.
    ///
    /// Long enough away and the renderer forgets anyway: it drops a node's
    /// state after `SceneNodeIdentity.retentionPasses` emit passes without
    /// seeing it, which is what stops a hidden pane pinning that state forever.
    public func hidden(_ isHidden: Bool = true) -> ModifiedView<Self> {
        styled { $0.isHidden = isHidden }
    }
}

// MARK: - Collapsing a chain

/// Chained modifiers merge into **one** `ModifiedView` when they describe the
/// same visual box. Padding applied after another modifier is the exception:
/// it creates an outer layout boundary so modifier order remains meaningful.
///
/// Nesting looks harmless but is not: each `ModifiedView` applies its own style
/// to the node independently, and a style with `padding == nil` resets padding
/// to the node's baseline. So `.padding(6).background(c)` would apply the
/// padding and then immediately clear it. These overloads are more specific
/// than the `View` ones, so a chain collapses as it is built and the node sees
/// a single merged style.
extension ModifiedView {
    private func adding(_ mutate: (inout ViewStyle) -> Void) -> ModifiedView<Content> {
        var next = ViewStyle()
        mutate(&next)
        return ModifiedView(
            content: content,
            style: next.merged(over: style),
            forceWrapper: forceWrapper
        )
    }

    /// Padding after an existing modifier belongs to a distinct outer box.
    /// This preserves the SwiftUI distinction between
    /// `.padding().frame(...)` and `.frame(...).padding()`.
    public func padding(_ amount: Float) -> ModifiedView<ModifiedView<Content>> {
        padding(.all(amount))
    }

    public func padding(_ edges: Edge, _ amount: Float) -> ModifiedView<ModifiedView<Content>> {
        padding(EdgeInsets(edges, amount))
    }

    public func padding(_ insets: EdgeInsets) -> ModifiedView<ModifiedView<Content>> {
        var outer = ViewStyle()
        outer.padding = insets
        return ModifiedView<ModifiedView<Content>>(
            content: self, style: outer, forceWrapper: true
        )
    }

    public func background(_ color: Color) -> ModifiedView<Content> {
        adding { $0.fill = color }
    }

    public func background(_ gradient: Gradient) -> ModifiedView<Content> {
        adding { $0.fillGradient = gradient; $0.fill = gradient.from }
    }

    public func hoverBackground(_ color: Color) -> ModifiedView<Content> {
        adding { $0.hoverFill = color }
    }

    public func cornerRadius(_ radius: Float) -> ModifiedView<Content> {
        adding { $0.cornerRadius = radius }
    }

    public func clipped() -> ModifiedView<Content> {
        adding { $0.clipsContent = true }
    }

    /// See `View.hidden(_:)`.
    public func hidden(_ isHidden: Bool = true) -> ModifiedView<Content> {
        adding { $0.isHidden = isHidden }
    }

    /// See `View.cursor(_:)`.
    public func cursor(_ shape: CursorShape?) -> ModifiedView<Content> {
        adding { $0.cursor = shape }
    }

    public func frame(
        width: Dimension? = nil, height: Dimension? = nil,
        minWidth: Float? = nil, minHeight: Float? = nil
    ) -> ModifiedView<Content> {
        adding {
            $0.width = width
            $0.height = height
            $0.minWidth = minWidth
            $0.minHeight = minHeight
        }
    }

    public func flexGrow(_ value: Float = 1) -> ModifiedView<Content> {
        adding { $0.flexGrow = value }
    }

    public func flexShrink(_ value: Float) -> ModifiedView<Content> {
        adding { $0.flexShrink = value }
    }

    public func blur(radius: Float = 8) -> ModifiedView<Content> {
        adding { $0.contentBlurRadius = max(0.5, radius) }
    }

    public func backdropBlur(radius: Float = 8) -> ModifiedView<Content> {
        adding { $0.backdropBlurRadius = max(0.5, radius) }
    }
}
