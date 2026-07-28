public struct StackStyle: Equatable, Sendable {
    public var flexGrow: Float
    public var width: Dimension
    public var height: Dimension
    public var padding: Float

    public init(
        flexGrow: Float = 0,
        width: Dimension = .auto,
        height: Dimension = .auto,
        padding: Float = 0
    ) {
        self.flexGrow = flexGrow
        self.width = width
        self.height = height
        self.padding = padding
    }

    var dumpDetail: String {
        "flexGrow=\(flexGrow) w=\(width) h=\(height) pad=\(padding)"
    }
}

public struct HStack<Content: View>: PrimitiveView {
    public var style: StackStyle
    public var content: Content

    public init(
        flexGrow: Float = 0,
        width: Dimension = .auto,
        height: Dimension = .auto,
        padding: Float = 0,
        @ViewBuilder content: () -> Content
    ) {
        self.style = StackStyle(
            flexGrow: flexGrow, width: width, height: height, padding: padding
        )
        self.content = content()
    }

    public var dumpDetail: String { style.dumpDetail }

    public func structureLines(indent: Int = 0) -> [String] {
        Dump.structureLines(
            indent: indent,
            label: "HStack \(dumpDetail)",
            childLines: [content.structureLines(indent: indent + 1)]
        )
    }

    public func mountPrimitive() -> any AnyViewNode {
        StackNode(
            label: "HStack",
            direction: .row,
            style: style,
            content: ViewGraph.mount(content)
        )
    }

    public func reconcilePrimitive(_ node: any AnyViewNode) -> any AnyViewNode {
        if let stack = node as? StackNode, stack.direction == .row {
            stack.update(style: style, contentView: content)
            return stack
        }
        return mountPrimitive()
    }
}

public struct VStack<Content: View>: PrimitiveView {
    public var style: StackStyle
    public var content: Content

    public init(
        flexGrow: Float = 0,
        width: Dimension = .auto,
        height: Dimension = .auto,
        padding: Float = 0,
        @ViewBuilder content: () -> Content
    ) {
        self.style = StackStyle(
            flexGrow: flexGrow, width: width, height: height, padding: padding
        )
        self.content = content()
    }

    public var dumpDetail: String { style.dumpDetail }

    public func structureLines(indent: Int = 0) -> [String] {
        Dump.structureLines(
            indent: indent,
            label: "VStack \(dumpDetail)",
            childLines: [content.structureLines(indent: indent + 1)]
        )
    }

    public func mountPrimitive() -> any AnyViewNode {
        StackNode(
            label: "VStack",
            direction: .column,
            style: style,
            content: ViewGraph.mount(content)
        )
    }

    public func reconcilePrimitive(_ node: any AnyViewNode) -> any AnyViewNode {
        if let stack = node as? StackNode, stack.direction == .column {
            stack.update(style: style, contentView: content)
            return stack
        }
        return mountPrimitive()
    }
}
