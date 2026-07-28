/// Non-exhaustive `if` — fragment (no flex wrapper).
public struct OptionalView<Content: View>: PrimitiveView {
    public var content: Content?

    public init(_ content: Content?) {
        self.content = content
    }

    public func structureLines(indent: Int = 0) -> [String] {
        if let content {
            return Dump.structureLines(
                indent: indent,
                label: "OptionalView.some",
                childLines: [content.structureLines(indent: indent + 1)]
            )
        }
        return [Dump.line(indent, "OptionalView.none")]
    }

    public func mountPrimitive() -> any AnyViewNode {
        let node = OptionalFragmentNode()
        if let content {
            node.updateSome(content)
        } else {
            node.updateNone()
        }
        return node
    }

    public func reconcilePrimitive(_ node: any AnyViewNode) -> any AnyViewNode {
        guard let opt = node as? OptionalFragmentNode else {
            return mountPrimitive()
        }
        if let content {
            opt.updateSome(content)
        } else {
            opt.updateNone()
        }
        return opt
    }
}
