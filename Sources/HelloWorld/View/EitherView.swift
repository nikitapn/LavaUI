/// `if` / `else` branches from `@ViewBuilder.buildEither`.
public struct EitherView<First: View, Second: View>: PrimitiveView {
    public enum Storage {
        case first(First)
        case second(Second)
    }

    public var storage: Storage

    public init(first: First) {
        storage = .first(first)
    }

    public init(second: Second) {
        storage = .second(second)
    }

    public func structureLines(indent: Int = 0) -> [String] {
        let pad = String(repeating: "  ", count: indent)
        switch storage {
        case .first(let view):
            var lines = ["\(pad)EitherView.first"]
            lines += view.structureLines(indent: indent + 1)
            return lines
        case .second(let view):
            var lines = ["\(pad)EitherView.second"]
            lines += view.structureLines(indent: indent + 1)
            return lines
        }
    }
}
