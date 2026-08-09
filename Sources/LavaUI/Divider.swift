import Foundation

/// A hairline rule separating content.
///
/// Orientation is inferred from the container: horizontal inside a `VStack`,
/// vertical inside an `HStack`. That inference has to happen late — a view is
/// built before it is inserted anywhere, so at construction time there is
/// nothing to ask. The node reads its Yoga owner instead, which is set by the
/// time layout and emit run. Pass an axis explicitly to override it.
public struct Divider: PrimitiveView {
    public var axis: DividerAxis?
    public var style: DividerStyle

    public init(_ axis: DividerAxis? = nil, style: DividerStyle = DividerStyle()) {
        self.axis = axis
        self.style = style
    }

    public var dumpDetail: String { axis.map { "\($0)" } ?? "inferred" }

    public func mountPrimitive() -> any AnyViewNode {
        let leaf = LeafNode(kind: .divider, label: "Divider", width: .auto, height: .auto)
        configure(leaf)
        leaf.installTextMeasure()
        return leaf
    }

    public func reconcilePrimitive(_ node: any AnyViewNode) -> any AnyViewNode {
        guard let leaf = node as? LeafNode, leaf.kind == .divider else {
            return mountPrimitive()
        }
        configure(leaf)
        if !leaf.usesTextMeasure { leaf.installTextMeasure() }
        leaf.markMeasureDirty()
        return leaf
    }

    private func configure(_ leaf: LeafNode) {
        leaf.theme = Environment.current.theme
        leaf.dividerStyle = style
        leaf.dividerAxis = axis
        // A rule that shrank would vanish, which is worse than overflowing.
        leaf.flexShrink = 0
        leaf.applyStyle()
    }
}

public enum DividerAxis: Equatable, Sendable {
    case horizontal
    case vertical
}

/// Colour and metrics for a `Divider`.
public struct DividerStyle {
    public var thickness: Float
    /// Clear space on each side of the rule, along the container's axis.
    public var spacing: Float
    public var color: Color

    public init(thickness: Float? = nil, spacing: Float = 4, color: Color? = nil) {
        let theme = Environment.current.theme
        self.thickness = thickness ?? theme.borderWidth
        self.spacing = spacing
        self.color = color ?? theme.border
    }
}
