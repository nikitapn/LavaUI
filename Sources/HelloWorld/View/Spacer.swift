public struct Spacer: PrimitiveView {
    public var flexGrow: Float

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
