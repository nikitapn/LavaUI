/// A small stroked symbol — a close cross, a plus — drawn as lines.
///
/// Not a character: a `Text("×")` is a box the height of the font's line
/// with the mark sat on the baseline, so it is never centred in anything and
/// its hover fill is a tall strip. Two capsule strokes are centred by
/// construction, the size the caller says, and cost what one glyph does.
///
/// No input of its own. Put it inside the stack that is the button, so the
/// click target and the hover fill are the button's padded box:
///
/// ```swift
/// HStack(padding: 0, alignment: .center, onClick: close) {
///     Mark(.cross, size: 10, color: theme.textDim)
/// }
/// .padding(4)
/// .hoverBackground(theme.hover)
/// ```
public struct Mark: View {
    /// Which symbol.
    public enum Kind: Sendable {
        /// Close: two diagonals.
        case cross
        /// Add: a horizontal and a vertical.
        case plus
    }

    /// Which symbol is drawn.
    public var kind: Kind
    /// Side of the square the mark is drawn in, in points.
    public var size: Float
    /// Colour of the strokes.
    public var color: Color
    /// Stroke width, in points.
    public var lineWidth: Float

    /// Creates a mark `size` points square.
    public init(_ kind: Kind, size: Float = 10, color: Color = .primary, lineWidth: Float = 1.5) {
        self.kind = kind
        self.size = size
        self.color = color
        self.lineWidth = lineWidth
    }

    public var body: some View {
        let kind = kind
        let color = color
        let lineWidth = lineWidth
        return Canvas(label: "Mark", width: .pt(size), height: .pt(size)) { list, frame in
            // Inset by half a stroke so the caps stay inside the box.
            let arm = min(frame.w, frame.h) * 0.5 - lineWidth * 0.5
            let cx = frame.x + frame.w * 0.5
            let cy = frame.y + frame.h * 0.5
            switch kind {
            case .cross:
                list.line(x1: cx - arm, y1: cy - arm, x2: cx + arm, y2: cy + arm,
                          color: color, width: lineWidth)
                list.line(x1: cx - arm, y1: cy + arm, x2: cx + arm, y2: cy - arm,
                          color: color, width: lineWidth)
            case .plus:
                list.line(x1: cx - arm, y1: cy, x2: cx + arm, y2: cy,
                          color: color, width: lineWidth)
                list.line(x1: cx, y1: cy - arm, x2: cx, y2: cy + arm,
                          color: color, width: lineWidth)
            }
        }
    }
}
