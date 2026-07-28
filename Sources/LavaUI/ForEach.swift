/// Variable-length children with **explicit** key identity.
/// Fragment: children splice into the parent (inherits row/column).
/// No `buildArray` — plain `for` in builders is intentionally unsupported.
public struct ForEach<
    Data: RandomAccessCollection,
    ID: Hashable,
    Content: View
>: PrimitiveView {
    public var data: Data
    public var id: KeyPath<Data.Element, ID>
    public var content: (Data.Element) -> Content

    public init(
        _ data: Data,
        id: KeyPath<Data.Element, ID>,
        @ViewBuilder content: @escaping (Data.Element) -> Content
    ) {
        self.data = data
        self.id = id
        self.content = content
    }

    public var dumpDetail: String { "[\(data.count) keyed]" }

    public func structureLines(indent: Int = 0) -> [String] {
        var chunks: [[String]] = []
        for element in data {
            chunks.append(content(element).structureLines(indent: indent + 1))
        }
        return Dump.structureLines(
            indent: indent,
            label: "ForEach[\(data.count)]",
            childLines: chunks
        )
    }

    public func mountPrimitive() -> any AnyViewNode {
        let node = ForEachFragmentNode<ID>()
        node.update(data: data, idKeyPath: id, content: content)
        return node
    }

    public func reconcilePrimitive(_ node: any AnyViewNode) -> any AnyViewNode {
        guard let fe = node as? ForEachFragmentNode<ID> else {
            return mountPrimitive()
        }
        fe.update(data: data, idKeyPath: id, content: content)
        return fe
    }
}

extension ForEach where Data.Element: Identifiable, ID == Data.Element.ID {
    public init(
        _ data: Data,
        @ViewBuilder content: @escaping (Data.Element) -> Content
    ) {
        self.init(data, id: \.id, content: content)
    }
}
