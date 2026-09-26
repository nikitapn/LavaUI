/// An empty box filled with the theme's `canvas` colour, for a region the app
/// draws into by other means.
///
/// It grows by `flexGrow` and is never narrower than 80 points. A windowed
/// app's layout log on standard error reports its size alongside the window's
/// whenever the window resizes. For a region the app paints through LavaUI
/// itself, use `Canvas`.
public struct DiagramHost: PrimitiveView {
    /// Share of the parent's leftover main-axis space the box takes.
    public var flexGrow: Float

    /// Creates a host that takes a `flexGrow` share of the leftover space.
    public init(flexGrow: Float = 1) {
        self.flexGrow = flexGrow
    }

    public var dumpDetail: String { "flexGrow=\(flexGrow)" }

    public func mountPrimitive() -> any AnyViewNode {
        LeafNode(
            kind: .diagramHost,
            label: "DiagramHost",
            width: .auto,
            height: .auto,
            flexGrow: flexGrow,
            minWidth: 80
        )
    }

    public func reconcilePrimitive(_ node: any AnyViewNode) -> any AnyViewNode {
        if let leaf = node as? LeafNode, leaf.kind == .diagramHost {
            leaf.update(
                label: "DiagramHost",
                width: .auto,
                height: .auto,
                flexGrow: flexGrow,
                minWidth: 80
            )
            return leaf
        }
        return mountPrimitive()
    }
}
