/// `if` / `else` — fragment (no flex wrapper). Identity is on the branch node.
public struct EitherView<First: View, Second: View>: PrimitiveView {
    public enum Storage {
        case first(First)
        case second(Second)
    }

    public var storage: Storage

    public init(first: First) { storage = .first(first) }
    public init(second: Second) { storage = .second(second) }

    public func structureLines(indent: Int = 0) -> [String] {
        switch storage {
        case .first(let view):
            return Dump.structureLines(
                indent: indent,
                label: "EitherView.first",
                childLines: [view.structureLines(indent: indent + 1)]
            )
        case .second(let view):
            return Dump.structureLines(
                indent: indent,
                label: "EitherView.second",
                childLines: [view.structureLines(indent: indent + 1)]
            )
        }
    }

    public func mountPrimitive() -> any AnyViewNode {
        let node = EitherFragmentNode()
        switch storage {
        case .first(let v): node.updateFirst(v)
        case .second(let v): node.updateSecond(v)
        }
        return node
    }

    public func reconcilePrimitive(_ node: any AnyViewNode) -> any AnyViewNode {
        guard let either = node as? EitherFragmentNode else {
            return mountPrimitive()
        }
        switch storage {
        case .first(let v): either.updateFirst(v)
        case .second(let v): either.updateSecond(v)
        }
        return either
    }
}
