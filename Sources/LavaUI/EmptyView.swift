/// A view that shows nothing and takes no space.
///
/// What an empty `@ViewBuilder` block or an `if` with no `else` produces. It
/// still occupies a slot in its parent, sized zero.
public struct EmptyView: PrimitiveView {
    /// Creates an empty view.
    public init() {}

    public var dumpDetail: String { "(empty)" }

    public func mountPrimitive() -> any AnyViewNode {
        LeafNode(kind: .empty, label: "EmptyView", width: .point(0), height: .point(0))
    }

    public func reconcilePrimitive(_ node: any AnyViewNode) -> any AnyViewNode {
        if let leaf = node as? LeafNode, leaf.kind == .empty {
            leaf.update(label: "EmptyView", width: .point(0), height: .point(0))
            return leaf
        }
        return mountPrimitive()
    }
}
