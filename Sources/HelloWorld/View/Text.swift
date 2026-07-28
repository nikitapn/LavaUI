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
        let leaf = LeafNode(
            kind: .text,
            label: "Text \"\(string)\"",
            width: .point(approxWidth),
            height: .point(24)
        )
        leaf.text = string
        leaf.color = color
        leaf.onClick = onClick
        return leaf
    }

    public func reconcilePrimitive(_ node: any AnyViewNode) -> any AnyViewNode {
        if let leaf = node as? LeafNode, leaf.kind == .text {
            leaf.update(
                label: "Text \"\(string)\"",
                width: .point(approxWidth),
                height: .point(24),
                text: string,
                color: color,
                onClick: onClick
            )
            return leaf
        }
        return mountPrimitive()
    }

    /// Grapheheme-cluster estimate — **not** real glyph bounds.
    /// Hit-testing trusts this box until Phase 4 (`Font::measure`); clicks near
    /// the trailing edge can mismatch what TextRenderer paints.
    private var approxWidth: Float {
        max(8, Float(string.count) * 8 + 8)
    }
}
