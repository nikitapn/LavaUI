/// Cross-axis placement of children in an `HStack` or `VStack`.
public enum StackAlignment: String, Equatable, Sendable {
    case start
    case center
    case end
    /// Expand children across the stack's cross axis when their size is auto.
    case stretch
}

public struct StackStyle: Equatable, Sendable {
    public var flexGrow: Float
    public var width: Dimension
    public var height: Dimension
    public var padding: Float
    public var alignment: StackAlignment
    /// Distance between adjacent children. `nil` uses the theme default.
    public var spacing: Float?
    /// Continue children onto additional flex lines when the main axis fills.
    public var wraps: Bool

    public init(
        flexGrow: Float = 0,
        width: Dimension = .auto,
        height: Dimension = .auto,
        padding: Float = 0,
        alignment: StackAlignment = .stretch,
        spacing: Float? = nil,
        wraps: Bool = false
    ) {
        self.flexGrow = flexGrow
        self.width = width
        self.height = height
        self.padding = padding
        self.alignment = alignment
        self.spacing = spacing
        self.wraps = wraps
    }

    var dumpDetail: String {
        let spacingDetail = spacing.map { String($0) } ?? "default"
        return "flexGrow=\(flexGrow) w=\(width) h=\(height) pad=\(padding) "
            + "align=\(alignment.rawValue) spacing=\(spacingDetail)"
            + "\(wraps ? " wrap" : "")"
    }
}

public struct HStack<Content: View>: PrimitiveView {
    public var style: StackStyle
    public var content: Content
    public var onClick: (() -> Void)?
    /// Button-aware press (`PointerButton.left` / `.right` / …). When set,
    /// takes priority over `onClick`.
    public var onPointer: ((_ mods: Int32, _ button: Int32) -> Void)?
    public var onHover: ((Bool) -> Void)?

    public init(
        flexGrow: Float = 0,
        width: Dimension = .auto,
        height: Dimension = .auto,
        padding: Float = 0,
        alignment: StackAlignment = .stretch,
        spacing: Float? = nil,
        wraps: Bool = false,
        onClick: (() -> Void)? = nil,
        onPointer: ((_ mods: Int32, _ button: Int32) -> Void)? = nil,
        onHover: ((Bool) -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.style = StackStyle(
            flexGrow: flexGrow, width: width, height: height, padding: padding,
            alignment: alignment, spacing: spacing, wraps: wraps
        )
        self.onClick = onClick
        self.onPointer = onPointer
        self.onHover = onHover
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
            content: ViewGraph.mount(content),
            onClick: onClick,
            onPointer: onPointer,
            onHover: onHover
        )
    }

    public func reconcilePrimitive(_ node: any AnyViewNode) -> any AnyViewNode {
        if let stack = node as? StackNode, stack.direction == .row {
            stack.update(
                style: style, contentView: content,
                onClick: onClick, onPointer: onPointer, onHover: onHover
            )
            return stack
        }
        return mountPrimitive()
    }
}

public struct VStack<Content: View>: PrimitiveView {
    public var style: StackStyle
    public var content: Content
    public var onClick: (() -> Void)?
    public var onPointer: ((_ mods: Int32, _ button: Int32) -> Void)?
    public var onHover: ((Bool) -> Void)?

    public init(
        flexGrow: Float = 0,
        width: Dimension = .auto,
        height: Dimension = .auto,
        padding: Float = 0,
        alignment: StackAlignment = .stretch,
        spacing: Float? = nil,
        wraps: Bool = false,
        onClick: (() -> Void)? = nil,
        onPointer: ((_ mods: Int32, _ button: Int32) -> Void)? = nil,
        onHover: ((Bool) -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.style = StackStyle(
            flexGrow: flexGrow, width: width, height: height, padding: padding,
            alignment: alignment, spacing: spacing, wraps: wraps
        )
        self.onClick = onClick
        self.onPointer = onPointer
        self.onHover = onHover
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
            content: ViewGraph.mount(content),
            onClick: onClick,
            onPointer: onPointer,
            onHover: onHover
        )
    }

    public func reconcilePrimitive(_ node: any AnyViewNode) -> any AnyViewNode {
        if let stack = node as? StackNode, stack.direction == .column {
            stack.update(
                style: style, contentView: content,
                onClick: onClick, onPointer: onPointer, onHover: onHover
            )
            return stack
        }
        return mountPrimitive()
    }
}
