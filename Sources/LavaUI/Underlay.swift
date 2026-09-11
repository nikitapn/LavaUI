import CYoga
import Foundation

/// A base view with a layer drawn *behind* it, covering its box and taking no
/// layout space.
///
/// The mirror of the composed `overlay(alignment:)`, built the same way: the
/// layer is an absolutely positioned Yoga child pinned to all four edges, so
/// the base measures exactly as it did without it. What differs is the order
/// — the layer is emitted first, so it paints under the content, and since
/// the hit walk visits children in reverse it is tested last and never takes
/// a click meant for what sits on top of it.
///
/// For chrome that no single fill describes: a tab whose outline runs along
/// three sides and leaves the fourth open, a rule along one edge, any shape a
/// `Canvas` draws against the box it is handed. Give the layer `.pct(100)` in
/// both axes and it is exactly the base's size.
public struct UnderlayView<Content: View, Layer: View>: PrimitiveView {
    public var content: Content
    public var layer: Layer

    public init(content: Content, layer: Layer) {
        self.content = content
        self.layer = layer
    }

    public var dumpDetail: String { "underlay" }

    public func structureLines(indent: Int = 0) -> [String] {
        Dump.structureLines(
            indent: indent, label: "Underlay",
            childLines: [
                layer.structureLines(indent: indent + 1),
                content.structureLines(indent: indent + 1),
            ]
        )
    }

    public func mountPrimitive() -> any AnyViewNode {
        UnderlayNode(
            content: ViewGraph.mount(content),
            layer: StyleBoxNode(content: ViewGraph.mount(layer))
        )
    }

    public func reconcilePrimitive(_ node: any AnyViewNode) -> any AnyViewNode {
        guard let box = node as? UnderlayNode else { return mountPrimitive() }
        box.updateContent(ViewGraph.reconcile(box.contentNode, with: content))
        box.layerBox.updateContent(
            ViewGraph.reconcile(box.layerBox.contentNode, with: layer)
        )
        box.pin()
        return box
    }
}

final class UnderlayNode: YogaBoxNode {
    private(set) var contentNode: any AnyViewNode
    /// Absolute, pinned to all four edges so it exactly covers the base, and
    /// holding the layer.
    let layerBox: StyleBoxNode
    private var insertedLeaves: [any AnyViewNode] = []
    private var layerLinked = false

    init(content: any AnyViewNode, layer: StyleBoxNode) {
        self.contentNode = content
        self.layerBox = layer
        super.init(label: "Underlay")
        YGNodeStyleSetFlexDirection(yogaStorage, YGFlexDirectionColumn)
        YGNodeStyleSetAlignItems(yogaStorage, YGAlignStretch)
        inheritFlex(from: content)
        applyStyle()
        pin()
        relink()
    }

    /// Layer first: painted under the content, hit-tested after it.
    override var childNodes: [any AnyViewNode] { [layerBox, contentNode] }

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

    /// Out of flow and stretched across the base box. After `applyStyle`,
    /// which re-asserts the box's own sizing and would otherwise have the
    /// last word.
    func pin() {
        layerBox.flexGrow = 0
        layerBox.flexShrink = 0
        layerBox.width = .auto
        layerBox.height = .auto
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
        // Absolute, so its place in the child list does not affect the flow;
        // first only so the Yoga order reads the way the paint order does.
        if let y = layerBox.yoga {
            YGNodeInsertChild(yogaStorage, y, index)
            index += 1
        }
        layerLinked = true
        for leaf in insertedLeaves {
            guard let y = leaf.yoga else { continue }
            YGNodeInsertChild(yogaStorage, y, index)
            index += 1
        }
    }

    override func collectChildFrames(
        originX: Float, originY: Float, into frames: inout [LayoutFrame]
    ) {
        layerBox.collectFrames(originX: originX, originY: originY, into: &frames)
        contentNode.collectFrames(originX: originX, originY: originY, into: &frames)
    }
}

extension View {
    /// Draws `layer` behind this view, covering its box and taking no layout
    /// space. See `UnderlayView`.
    public func underlay<Layer: View>(
        @ViewBuilder _ layer: () -> Layer
    ) -> UnderlayView<Self, Layer> {
        UnderlayView(content: self, layer: layer())
    }
}
