public struct DiagramHost: PrimitiveView {
    public var flexGrow: Float

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
