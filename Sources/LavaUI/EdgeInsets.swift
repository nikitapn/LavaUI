/// Which sides of a box a layout inset applies to.
///
/// Matches SwiftUI's `Edge.Set` shape so call sites can write
/// `.padding(.horizontal, 8)` without inventing a Lava-only vocabulary.
/// Layout is LTR today: `leading` maps to the left edge and `trailing` to
/// the right; a future layout-direction environment would remap at the Yoga
/// boundary rather than renaming these cases.
public struct Edge: OptionSet, Equatable, Sendable, Hashable {
    /// The edge bits.
    public let rawValue: UInt8

    /// Creates an edge set from its bits.
    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    /// The top edge.
    public static let top = Edge(rawValue: 1 << 0)
    /// The leading edge: left, since layout is left to right.
    public static let leading = Edge(rawValue: 1 << 1)
    /// The bottom edge.
    public static let bottom = Edge(rawValue: 1 << 2)
    /// The trailing edge: right, since layout is left to right.
    public static let trailing = Edge(rawValue: 1 << 3)

    /// The leading and trailing edges.
    public static let horizontal: Edge = [.leading, .trailing]
    /// The top and bottom edges.
    public static let vertical: Edge = [.top, .bottom]
    /// All four edges.
    public static let all: Edge = [.top, .leading, .bottom, .trailing]
}

/// Per-edge inset around a view's content.
///
/// Used by `.padding` and stored on Yoga boxes as the source of truth for
/// `YGNodeStyleSetPadding` on each edge. Prefer the static constructors over
/// spelling four zeros by hand.
public struct EdgeInsets: Equatable, Sendable, Hashable {
    /// Inset from the top edge, in points.
    public var top: Float
    /// Inset from the leading (left) edge, in points.
    public var leading: Float
    /// Inset from the bottom edge, in points.
    public var bottom: Float
    /// Inset from the trailing (right) edge, in points.
    public var trailing: Float

    /// Creates insets from one value per edge, zero by default.
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

    /// No inset on any edge.
    public static let zero = EdgeInsets()

    /// The same inset on all four edges.
    public static func all(_ value: Float) -> EdgeInsets {
        EdgeInsets(top: value, leading: value, bottom: value, trailing: value)
    }

    /// The same inset on the leading and trailing edges; top and bottom stay zero.
    public static func horizontal(_ value: Float) -> EdgeInsets {
        EdgeInsets(leading: value, trailing: value)
    }

    /// The same inset on the top and bottom edges; leading and trailing stay zero.
    public static func vertical(_ value: Float) -> EdgeInsets {
        EdgeInsets(top: value, bottom: value)
    }

    /// Sum of leading and trailing — useful for width arithmetic.
    public var horizontalTotal: Float { leading + trailing }

    /// Sum of top and bottom — useful for height arithmetic.
    public var verticalTotal: Float { top + bottom }
}
