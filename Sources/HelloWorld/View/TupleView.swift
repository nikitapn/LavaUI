/// Heterogeneous children from a multi-statement `@ViewBuilder` block.
/// Pack-based — no TupleView1…N codegen (see Phase 0a).
public struct TupleView<each Content: View>: PrimitiveView {
    public var content: (repeat each Content)

    public init(content: (repeat each Content)) {
        self.content = content
    }

    public func structureLines(indent: Int = 0) -> [String] {
        let pad = String(repeating: "  ", count: indent)
        var lines = ["\(pad)TupleView"]
        for child in repeat each content {
            lines += child.structureLines(indent: indent + 1)
        }
        return lines
    }
}
