import CYoga
import Foundation

/// A base view with a layer drawn behind it (`.underlay { }`) or over it
/// (`.overlayLayer { }`), covering its box and taking no layout space and no
/// input.
///
/// Built the way the composed `overlay(alignment:)` is: the layer is an
/// absolutely positioned Yoga child pinned to all four edges, so the base
/// measures exactly as it did without it. What differs is that the layer is
/// **inert** — every hit walk passes straight through it — and that it can
/// go under the content as well as over it.
///
/// For chrome no single fill describes: a tab whose outline runs along three
/// sides and leaves the fourth open, a highlight over a pane that is about to
/// receive a drop. Give the layer `.pct(100)` in both axes and it is exactly
/// the base's size.
public struct LayeredView<Content: View, Layer: View>: PrimitiveView {
    public var content: Content
    public var layer: Layer
    /// Over the content rather than under it.
    public var above: Bool

    public init(content: Content, layer: Layer, above: Bool) {
        self.content = content
        self.layer = layer
        self.above = above
    }

    public var dumpDetail: String { above ? "overlayLayer" : "underlay" }

    public func structureLines(indent: Int = 0) -> [String] {
        let layerLines = layer.structureLines(indent: indent + 1)
        let contentLines = content.structureLines(indent: indent + 1)
        return Dump.structureLines(
            indent: indent, label: above ? "OverlayLayer" : "Underlay",
            childLines: above ? [contentLines, layerLines] : [layerLines, contentLines]
        )
    }

    public func mountPrimitive() -> any AnyViewNode {
        LayerNode(
            content: ViewGraph.mount(content),
            layer: StyleBoxNode(content: ViewGraph.mount(layer)),
            above: above
        )
    }

    public func reconcilePrimitive(_ node: any AnyViewNode) -> any AnyViewNode {
        guard let box = node as? LayerNode, box.above == above else {
            return mountPrimitive()
        }
        box.updateContent(ViewGraph.reconcile(box.contentNode, with: content))
        box.layerBox.updateContent(
            ViewGraph.reconcile(box.layerBox.contentNode, with: layer)
        )
        box.pin()
        return box
    }
}

final class LayerNode: YogaBoxNode {
    private(set) var contentNode: any AnyViewNode
    /// Absolute, pinned to all four edges so it exactly covers the base, and
    /// holding the layer.
    let layerBox: StyleBoxNode
    let above: Bool
    private var insertedLeaves: [any AnyViewNode] = []
    private var layerLinked = false

    init(content: any AnyViewNode, layer: StyleBoxNode, above: Bool) {
        self.contentNode = content
        self.layerBox = layer
        self.above = above
        super.init(label: above ? "OverlayLayer" : "Underlay")
        YGNodeStyleSetFlexDirection(yogaStorage, YGFlexDirectionColumn)
        YGNodeStyleSetAlignItems(yogaStorage, YGAlignStretch)
        inheritFlex(from: content)
        applyStyle()
        pin()
        relink()
    }

    /// Emission order is paint order: a layer under the content goes first,
    /// one over it goes last. The hit walks do not care — the layer is inert.
    override var childNodes: [any AnyViewNode] {
        above ? [contentNode, layerBox] : [layerBox, contentNode]
    }

    func updateContent(_ node: any AnyViewNode) {
        contentNode = node
        inheritFlex(from: node)
        relink()
    }

    /// The wrapper must not become more rigid than what it wraps — the trap
    /// `StyleBoxNode` documents, and the composed overlay's answer to it. The
    /// layer is out of flow, so only the content counts.
    private func inheritFlex(from node: any AnyViewNode) {
        let leaves = node.flattenedLayoutNodes().compactMap { $0 as? YogaBoxNode }
        flexGrow = leaves.map(\.flexGrow).max() ?? 0
        flexShrink = leaves.map(\.effectiveFlexShrink).min()
    }

    /// Out of flow, stretched across the base, and invisible to input. After
    /// `applyStyle`, which re-asserts the box's own sizing and would otherwise
    /// have the last word.
    func pin() {
        layerBox.flexGrow = 0
        layerBox.flexShrink = 0
        layerBox.width = .auto
        layerBox.height = .auto
        // A layer that took a press would take it from the content: an
        // overlay is on top, and every hit walk tests the top child first.
        layerBox.ignoresInput = true
        layerBox.applyStyle()
        guard let box = layerBox.yoga else { return }
        YGNodeStyleSetPositionType(box, YGPositionTypeAbsolute)
        for edge in [YGEdgeLeft, YGEdgeRight, YGEdgeTop, YGEdgeBottom] {
            YGNodeStyleSetPosition(box, edge, 0)
        }
    }

    private func relink() {
        let leaves = contentNode.flattenedLayoutNodes()
        guard !layerLinked || yogaChildrenChanged(leaves, insertedLeaves) else { return }
        YGNodeRemoveAllChildren(yogaStorage)
        insertedLeaves = leaves
        var index = 0
        for leaf in insertedLeaves {
            guard let y = leaf.yoga else { continue }
            YGNodeInsertChild(yogaStorage, y, index)
            index += 1
        }
        // Absolute, so its place in the child list does not affect the flow.
        if let y = layerBox.yoga {
            YGNodeInsertChild(yogaStorage, y, index)
        }
        layerLinked = true
    }

    override func collectChildFrames(
        originX: Float, originY: Float, into frames: inout [LayoutFrame]
    ) {
        for child in childNodes {
            child.collectFrames(originX: originX, originY: originY, into: &frames)
        }
    }
}

extension View {
    /// Draws `layer` behind this view, covering its box and taking no layout
    /// space or input. See `LayeredView`.
    public func underlay<Layer: View>(
        @ViewBuilder _ layer: () -> Layer
    ) -> LayeredView<Self, Layer> {
        LayeredView(content: self, layer: layer(), above: false)
    }

    /// Draws `layer` over this view, covering its box and taking no layout
    /// space or input — presses go through it to what is underneath. See
    /// `LayeredView`.
    public func overlayLayer<Layer: View>(
        @ViewBuilder _ layer: () -> Layer
    ) -> LayeredView<Self, Layer> {
        LayeredView(content: self, layer: layer(), above: true)
    }
}
