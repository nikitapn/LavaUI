/// Cross-axis placement of children in an `HStack` or `VStack`.
public enum StackAlignment: String, Equatable, Sendable {
    /// Children hug the top (in an `HStack`) or the left (in a `VStack`).
    case start
    /// Children are centred across the stack.
    case center
    /// Children hug the bottom (in an `HStack`) or the right (in a `VStack`).
    case end
    /// Expand children across the stack's cross axis when their size is auto.
    case stretch
}

/// Layout settings shared by `HStack` and `VStack`.
public struct StackStyle: Equatable, Sendable {
    /// Share of the parent's leftover main-axis space the stack takes.
    public var flexGrow: Float
    /// Width of the stack. `.auto` sizes it to its children.
    ///
    /// A `VStack` given a `.point` or `.percent` width is painted with the
    /// theme's `panel` colour, so it reads as a sidebar. Use `.frame(width:)`
    /// instead when that is not wanted.
    public var width: Dimension
    /// Height of the stack. `.auto` sizes it to its children.
    public var height: Dimension
    /// Space between the stack's edge and its children, on every side, in points.
    public var padding: Float
    /// How children are placed across the stack.
    public var alignment: StackAlignment
    /// Distance between adjacent children. `nil` uses the theme default.
    public var spacing: Float?
    /// Continue children onto additional flex lines when the main axis fills.
    public var wraps: Bool

    /// Creates a style. Every parameter matches the property of the same name.
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

/// Lays its children out left to right.
public struct HStack<Content: View>: PrimitiveView {
    /// Size, padding, spacing and alignment.
    public var style: StackStyle
    /// The children.
    public var content: Content
    /// Called when the stack, or a child with no click handler of its own, is clicked.
    public var onClick: (() -> Void)?
    /// Button-aware press (`PointerButton.left` / `.right` / …). When set,
    /// takes priority over `onClick`.
    public var onPointer: ((_ mods: Int32, _ button: Int32) -> Void)?
    /// Called with `true` when the pointer enters the stack and `false` when it leaves.
    public var onHover: ((Bool) -> Void)?
    /// Called with the deltas, in notches, when the wheel turns over the stack.
    /// Setting it keeps the wheel from reaching a `ScrollView` around the stack.
    public var onWheel: ((Float, Float) -> Void)?

    /// Creates a row. Every parameter matches the property of the same name.
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
        onWheel: ((Float, Float) -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.style = StackStyle(
            flexGrow: flexGrow, width: width, height: height, padding: padding,
            alignment: alignment, spacing: spacing, wraps: wraps
        )
        self.onClick = onClick
        self.onPointer = onPointer
        self.onHover = onHover
        self.onWheel = onWheel
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
            onHover: onHover,
            onWheel: onWheel
        )
    }

    public func reconcilePrimitive(_ node: any AnyViewNode) -> any AnyViewNode {
        if let stack = node as? StackNode, stack.direction == .row {
            stack.update(
                style: style, contentView: content,
                onClick: onClick, onPointer: onPointer, onHover: onHover,
                onWheel: onWheel
            )
            return stack
        }
        return mountPrimitive()
    }
}

/// Lays its children out top to bottom.
///
/// Given a `.point` or `.percent` width, it is also painted with the theme's
/// `panel` colour. See `StackStyle.width`.
public struct VStack<Content: View>: PrimitiveView {
    /// Size, padding, spacing and alignment.
    public var style: StackStyle
    /// The children.
    public var content: Content
    /// Called when the stack, or a child with no click handler of its own, is clicked.
    public var onClick: (() -> Void)?
    /// Button-aware press (`PointerButton.left` / `.right` / …). When set,
    /// takes priority over `onClick`.
    public var onPointer: ((_ mods: Int32, _ button: Int32) -> Void)?
    /// Called with `true` when the pointer enters the stack and `false` when it leaves.
    public var onHover: ((Bool) -> Void)?
    /// Called with the deltas, in notches, when the wheel turns over the stack.
    /// Setting it keeps the wheel from reaching a `ScrollView` around the stack.
    public var onWheel: ((Float, Float) -> Void)?

    /// Creates a column. Every parameter matches the property of the same name.
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
        onWheel: ((Float, Float) -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.style = StackStyle(
            flexGrow: flexGrow, width: width, height: height, padding: padding,
            alignment: alignment, spacing: spacing, wraps: wraps
        )
        self.onClick = onClick
        self.onPointer = onPointer
        self.onHover = onHover
        self.onWheel = onWheel
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
            onHover: onHover,
            onWheel: onWheel
        )
    }

    public func reconcilePrimitive(_ node: any AnyViewNode) -> any AnyViewNode {
        if let stack = node as? StackNode, stack.direction == .column {
            stack.update(
                style: style, contentView: content,
                onClick: onClick, onPointer: onPointer, onHover: onHover,
                onWheel: onWheel
            )
            return stack
        }
        return mountPrimitive()
    }
}
