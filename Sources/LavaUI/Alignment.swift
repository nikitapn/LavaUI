import CYoga

/// Horizontal placement of content inside a box larger than it.
public enum HorizontalAlignment: Equatable, Sendable {
    /// Content hugs the leading (left) edge.
    case leading
    /// Content is centred horizontally.
    case center
    /// Content hugs the trailing (right) edge.
    case trailing

    /// As main-axis justification of a **row** container.
    var justify: YGJustify {
        switch self {
        case .leading: return YGJustifyFlexStart
        case .center: return YGJustifyCenter
        case .trailing: return YGJustifyFlexEnd
        }
    }
}

/// Vertical placement of content inside a box larger than it.
public enum VerticalAlignment: Equatable, Sendable {
    /// Content hugs the top edge.
    case top
    /// Content is centred vertically.
    case center
    /// Content hugs the bottom edge.
    case bottom

    /// As cross-axis alignment of a **row** container.
    var align: YGAlign {
        switch self {
        case .top: return YGAlignFlexStart
        case .center: return YGAlignCenter
        case .bottom: return YGAlignFlexEnd
        }
    }
}

/// A point in a box: one horizontal choice and one vertical one.
///
/// Two axes in a struct rather than nine cases in an enum, which is what
/// SwiftUI settled on and for the reason that shows up immediately here: the
/// nine named corners are *combinations*, and everything that consumes an
/// alignment consumes one axis at a time. A row container justifies its main
/// axis and aligns its cross axis, and asking a nine-case enum for that means
/// two nine-arm switches that have to stay consistent with each other by
/// inspection. `OverlayAnchor` was exactly those two switches, and is now a
/// spelling of this.
///
/// Named corners still read best at a call site, so they stay — as static
/// members, which pattern-match the same way in an `if` and compose the way an
/// enum cannot.
public struct Alignment: Equatable, Sendable {
    /// Placement along the horizontal axis.
    public var horizontal: HorizontalAlignment
    /// Placement along the vertical axis.
    public var vertical: VerticalAlignment

    /// Creates an alignment from one choice per axis.
    public init(horizontal: HorizontalAlignment, vertical: VerticalAlignment) {
        self.horizontal = horizontal
        self.vertical = vertical
    }

    /// The top-left corner.
    public static let topLeading = Alignment(horizontal: .leading, vertical: .top)
    /// Centred along the top edge.
    public static let top = Alignment(horizontal: .center, vertical: .top)
    /// The top-right corner.
    public static let topTrailing = Alignment(horizontal: .trailing, vertical: .top)
    /// Centred along the left edge.
    public static let leading = Alignment(horizontal: .leading, vertical: .center)
    /// Centred on both axes.
    public static let center = Alignment(horizontal: .center, vertical: .center)
    /// Centred along the right edge.
    public static let trailing = Alignment(horizontal: .trailing, vertical: .center)
    /// The bottom-left corner.
    public static let bottomLeading = Alignment(horizontal: .leading, vertical: .bottom)
    /// Centred along the bottom edge.
    public static let bottom = Alignment(horizontal: .center, vertical: .bottom)
    /// The bottom-right corner.
    public static let bottomTrailing = Alignment(
        horizontal: .trailing, vertical: .bottom
    )

    /// Horizontal placement, as main-axis justification of a row container.
    var justify: YGJustify { horizontal.justify }
    /// Vertical placement, as cross-axis alignment of a row container.
    var align: YGAlign { vertical.align }
}
