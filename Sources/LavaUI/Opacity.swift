/// A view whose drawing, including its descendants, has reduced opacity.
public struct OpacityView<Content: View>: PrimitiveView {
    public var content: Content
    /// Opacity from 0 (transparent) to 1 (opaque).
    public var opacity: Float {
        didSet { opacity = Self.clamped(opacity) }
    }

    public init(content: Content, opacity: Float) {
        self.content = content
        self.opacity = Self.clamped(opacity)
    }

    /// NaN passes through `min`/`max` untouched (both compare false), and
    /// would reach every colour of the subtree; `progress / total` with a
    /// zero total is the easy way to get one. Treated as no fade.
    static func clamped(_ value: Float) -> Float {
        value.isNaN ? 1 : min(max(value, 0), 1)
    }

    public var dumpDetail: String { "opacity \(opacity)" }

    public func mountPrimitive() -> any AnyViewNode {
        let node = OpacityNode(content: ViewGraph.mount(content))
        node.opacity = opacity
        return node
    }

    public func reconcilePrimitive(_ node: any AnyViewNode) -> any AnyViewNode {
        guard let box = node as? OpacityNode else { return mountPrimitive() }
        box.updateContent(ViewGraph.reconcile(box.contentNode, with: content))
        box.opacity = opacity
        return box
    }
}

final class OpacityNode: StyleBoxNode {
    var opacity: Float = 1
}

extension View {
    /// Multiplies the alpha of this view's drawing and its descendants.
    /// Values are clamped to 0…1 (NaN is 1); nested modifiers multiply.
    /// Layout and hit testing stay the same, including at zero opacity.
    /// Overlapping primitives blend individually rather than as a flattened
    /// offscreen group. Backdrop blur and glass have no colour to fade: they
    /// stay at full strength until the opacity reaches zero, where the
    /// subtree is not drawn at all.
    public func opacity(_ opacity: Float) -> OpacityView<Self> {
        OpacityView(content: self, opacity: opacity)
    }
}
