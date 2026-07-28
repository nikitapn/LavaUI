/// Non-exhaustive `if` (no else) from `@ViewBuilder.buildOptional`.
public struct OptionalView<Content: View>: PrimitiveView {
    public var content: Content?

    public init(_ content: Content?) {
        self.content = content
    }

    public func structureLines(indent: Int = 0) -> [String] {
        let pad = String(repeating: "  ", count: indent)
        if let content {
            var lines = ["\(pad)OptionalView.some"]
            lines += content.structureLines(indent: indent + 1)
            return lines
        }
        return ["\(pad)OptionalView.none"]
    }
}
