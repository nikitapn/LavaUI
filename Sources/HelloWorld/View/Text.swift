public struct Text: PrimitiveView {
    public var string: String
    public var color: Color
    /// Closures break value equality (SwiftUI wart) — fine until Phase 5 skip-recompute.
    public var onClick: (() -> Void)?

    public init(
        _ string: String,
        color: Color = .primary,
        onClick: (() -> Void)? = nil
    ) {
        self.string = string
        self.color = color
        self.onClick = onClick
    }

    public var dumpDetail: String {
        let click = onClick == nil ? "" : " onClick"
        return "\"\(string)\"\(click)"
    }

    public func mountPrimitive() -> any AnyViewNode {
        LeafNode(
            kind: .text,
            label: "Text \"\(string)\"",
            width: .point(approxWidth),
            height: .point(24)
        )
    }

    public func reconcilePrimitive(_ node: any AnyViewNode) -> any AnyViewNode {
        if let leaf = node as? LeafNode, leaf.kind == .text {
            leaf.update(
                label: "Text \"\(string)\"",
                width: .point(approxWidth),
                height: .point(24)
            )
            return leaf
        }
        return mountPrimitive()
    }

    /// Grapheheme-cluster count (Phase 4 replaces with Font::measure).
    private var approxWidth: Float {
        max(8, Float(string.count) * 8 + 8)
    }
}
