/// Which sides of a box a layout inset applies to.
///
/// Matches SwiftUI's `Edge.Set` shape so call sites can write
/// `.padding(.horizontal, 8)` without inventing a Lava-only vocabulary.
/// Layout is LTR today: `leading` maps to the left edge and `trailing` to
/// the right; a future layout-direction environment would remap at the Yoga
/// boundary rather than renaming these cases.
public struct Edge: OptionSet, Equatable, Sendable, Hashable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let top = Edge(rawValue: 1 << 0)
    public static let leading = Edge(rawValue: 1 << 1)
    public static let bottom = Edge(rawValue: 1 << 2)
    public static let trailing = Edge(rawValue: 1 << 3)

    public static let horizontal: Edge = [.leading, .trailing]
    public static let vertical: Edge = [.top, .bottom]
    public static let all: Edge = [.top, .leading, .bottom, .trailing]
}

/// Per-edge inset around a view's content.
///
/// Used by `.padding` and stored on Yoga boxes as the source of truth for
/// `YGNodeStyleSetPadding` on each edge. Prefer the static constructors over
/// spelling four zeros by hand.
public struct EdgeInsets: Equatable, Sendable, Hashable {
    public var top: Float
    public var leading: Float
    public var bottom: Float
    public var trailing: Float

    public init(
        top: Float = 0,
        leading: Float = 0,
        bottom: Float = 0,
        trailing: Float = 0
    ) {
        self.top = top
        self.leading = leading
        self.bottom = bottom
        self.trailing = trailing
    }

    /// Insets only the sides listed in `edges`; the rest stay zero.
    public init(_ edges: Edge, _ amount: Float) {
        self.init(
            top: edges.contains(.top) ? amount : 0,
            leading: edges.contains(.leading) ? amount : 0,
            bottom: edges.contains(.bottom) ? amount : 0,
            trailing: edges.contains(.trailing) ? amount : 0
        )
    }

    public static let zero = EdgeInsets()

    public static func all(_ value: Float) -> EdgeInsets {
        EdgeInsets(top: value, leading: value, bottom: value, trailing: value)
    }

    public static func horizontal(_ value: Float) -> EdgeInsets {
        EdgeInsets(leading: value, trailing: value)
    }

    public static func vertical(_ value: Float) -> EdgeInsets {
        EdgeInsets(top: value, bottom: value)
    }

    /// Sum of leading and trailing — useful for width arithmetic.
    public var horizontalTotal: Float { leading + trailing }

    /// Sum of top and bottom — useful for height arithmetic.
    public var verticalTotal: Float { top + bottom }
}
