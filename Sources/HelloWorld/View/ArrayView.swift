/// Homogeneous children from a `for … in` loop in `@ViewBuilder`.
public struct ArrayView<Content: View>: PrimitiveView {
    public var views: [Content]

    public init(views: [Content]) {
        self.views = views
    }

    public var dumpDetail: String { "[\(views.count)]" }

    public func structureLines(indent: Int = 0) -> [String] {
        let pad = String(repeating: "  ", count: indent)
        var lines = ["\(pad)ArrayView[\(views.count)]"]
        for view in views {
            lines += view.structureLines(indent: indent + 1)
        }
        return lines
    }
}
