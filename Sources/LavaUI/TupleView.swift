/// Heterogeneous children from a multi-statement `@ViewBuilder` block.
/// Fragment: expands into the parent flex container (not a Yoga box).
public struct TupleView<each Content: View>: PrimitiveView {
    public var content: (repeat each Content)

    public init(content: (repeat each Content)) {
        self.content = content
    }

    public func structureLines(indent: Int = 0) -> [String] {
        var childChunks: [[String]] = []
        for child in repeat each content {
            childChunks.append(child.structureLines(indent: indent + 1))
        }
        return Dump.structureLines(indent: indent, label: "TupleView", childLines: childChunks)
    }

    public func mountPrimitive() -> any AnyViewNode {
        var children: [any AnyViewNode] = []
        for child in repeat each content {
            children.append(ViewGraph.mount(child))
        }
        return TupleFragmentNode(children: children)
    }

    public func reconcilePrimitive(_ node: any AnyViewNode) -> any AnyViewNode {
        guard let tuple = node as? TupleFragmentNode else {
            return mountPrimitive()
        }
        // Fixed arity: zip pack with existing children by index.
        var next: [any AnyViewNode] = []
        var index = 0
        let old = tuple.childNodes
        for child in repeat each content {
            if index < old.count {
                next.append(ViewGraph.reconcile(old[index], with: child))
            } else {
                next.append(ViewGraph.mount(child))
            }
            index += 1
        }
        tuple.setChildren(next)
        return tuple
    }
}
