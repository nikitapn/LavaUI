#if canImport(CxxCanvas)
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

    public init() {}

    /// `self` wins where both define a field.
    func merged(over base: ViewStyle) -> ViewStyle {
        var out = ViewStyle()
        out.padding = padding ?? base.padding
        out.fill = fill ?? base.fill
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
        if let box = node as? StyleBoxNode {
            // Previously wrapped. Reconcile inside; if the content collapsed to
            // a single box we could unwrap, but keeping the box is stable and
            // avoids churning Yoga's tree on every frame.
            box.updateContent(ViewGraph.reconcile(box.contentNode, with: content))
            box.applyViewStyle(style)
            return box
        }
        return attach(style, to: ViewGraph.reconcile(node, with: content))
    }

    /// Style the node if it is a single box; otherwise wrap it once.
    private func attach(_ style: ViewStyle, to node: any AnyViewNode) -> any AnyViewNode {
        if !forceWrapper, let box = node as? YogaBoxNode {
            box.applyViewStyle(style)
            return box
        }
        let wrapper = StyleBoxNode(content: node)
        wrapper.applyViewStyle(style)
        return wrapper
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

        if let leaf = self as? LeafNode {
            if let fill = style.fill { leaf.fillColor = fill }
            if let hover = style.hoverFill { leaf.hoverFill = hover }
            if let radius = style.cornerRadius { leaf.cornerRadius = radius }
        } else if let stack = self as? StackNode {
            if let fill = style.fill { stack.fillColor = fill }
            if let hover = style.hoverFill { stack.hoverFill = hover }
            if let radius = style.cornerRadius { stack.cornerRadius = radius }
        } else if let box = self as? StyleBoxNode {
            if let fill = style.fill { box.fillColor = fill }
            if let radius = style.cornerRadius { box.cornerRadius = radius }
        }
        applyStyle()
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
    var fillColor: Color?
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
    /// Yoga still sizes children freely; only drawing is clipped. Use on fixed
    /// chrome such as a menubar so hover fills cannot spill into content.
    public func clipped() -> ModifiedView<Self> {
        styled { $0.clipsContent = true }
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

    public func hoverBackground(_ color: Color) -> ModifiedView<Content> {
        adding { $0.hoverFill = color }
    }

    public func cornerRadius(_ radius: Float) -> ModifiedView<Content> {
        adding { $0.cornerRadius = radius }
    }

    public func clipped() -> ModifiedView<Content> {
        adding { $0.clipsContent = true }
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

#endif
