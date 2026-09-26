/// Empty space that expands along its stack's main axis.
///
/// Pushes its siblings apart: a `Spacer()` between two views in an `HStack`
/// sends them to opposite edges. Several spacers split the leftover space in
/// proportion to their `flexGrow`.
public struct Spacer: PrimitiveView {
    /// This spacer's share of the leftover main-axis space.
    public var flexGrow: Float

    /// Creates a spacer with a `flexGrow` share of the leftover space.
    public init(flexGrow: Float = 1) {
        self.flexGrow = flexGrow
    }

    public var dumpDetail: String { "flexGrow=\(flexGrow)" }

    public func mountPrimitive() -> any AnyViewNode {
        LeafNode(
            kind: .spacer,
            label: "Spacer",
            width: .auto,
            height: .auto,
            flexGrow: flexGrow
        )
    }

    public func reconcilePrimitive(_ node: any AnyViewNode) -> any AnyViewNode {
        if let leaf = node as? LeafNode, leaf.kind == .spacer {
            leaf.update(label: "Spacer", width: .auto, height: .auto, flexGrow: flexGrow)
            return leaf
        }
        return mountPrimitive()
    }
}
