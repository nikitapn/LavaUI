import Foundation

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

/// Media transport symbols — play, pause, previous, next — drawn as filled
/// shapes, for the same reason `Mark` is not a character: "▶" and "⏮" are
/// whatever the fallback font made of them, sat on its baseline, at a size
/// and weight that never match each other, and "❚❚" is two letters.
///
/// Geometry rather than a picture: a few triangles and rectangles cost what
/// a glyph does, need no texture, stay sharp at any scale, and take the
/// theme's colour as it changes. No input of its own, as `Mark`.
public struct TransportMark: View {
    public enum Kind: Sendable {
        case play
        case pause
        /// Back a track: a bar, then a triangle pointing at it.
        case previous
        /// Forward a track.
        case next
    }

    public var kind: Kind
    public var size: Float
    public var color: Color

    public init(_ kind: Kind, size: Float = 16, color: Color = .primary) {
        self.kind = kind
        self.size = size
        self.color = color
    }

    public var body: some View {
        let kind = kind
        let color = color
        return Canvas(label: "TransportMark", width: .pt(size), height: .pt(size)) { list, frame in
            let s = min(frame.w, frame.h)
            let x = frame.x + (frame.w - s) * 0.5
            let y = frame.y + (frame.h - s) * 0.5
            func p(_ u: Float, _ v: Float) -> (x: Float, y: Float) { (x + u * s, y + v * s) }
            switch kind {
            case .play:
                // A triangle's weight sits left of its box's centre; nudged
                // right so it looks centred beside a pause.
                list.polygon([p(0.24, 0.12), p(0.88, 0.5), p(0.24, 0.88)], color: color)
            case .pause:
                let w = s * 0.24
                let h = s * 0.72
                list.roundedRect(x: x + s * 0.2, y: y + s * 0.14, w: w, h: h, color: color,
                                 radius: max(1, s * 0.05))
                list.roundedRect(x: x + s * 0.56, y: y + s * 0.14, w: w, h: h, color: color,
                                 radius: max(1, s * 0.05))
            case .next:
                list.polygon([p(0.14, 0.16), p(0.68, 0.5), p(0.14, 0.84)], color: color)
                list.roundedRect(x: x + s * 0.70, y: y + s * 0.16, w: s * 0.14, h: s * 0.68,
                                 color: color, radius: max(0.75, s * 0.03))
            case .previous:
                list.polygon([p(0.86, 0.16), p(0.32, 0.5), p(0.86, 0.84)], color: color)
                list.roundedRect(x: x + s * 0.16, y: y + s * 0.16, w: s * 0.14, h: s * 0.68,
                                 color: color, radius: max(0.75, s * 0.03))
            }
        }
    }
}

/// A speaker with sound waves that light with the volume, or a cross when
/// muted — for volume buttons, drawn rather than taken from "🔊", for the
/// same reasons as `TransportMark`.
///
/// The body and horn are one polygon and the waves are thin ring segments,
/// so every edge, curved ones included, gets the renderer's antialiased
/// fringe. `paint` is the drawing on its own, for a `Canvas` that needs
/// handlers of its own (the panel's takes the wheel).
public struct SpeakerMark: View {
    /// 0...1. Each of the three waves lights at a quarter more.
    public var level: Float
    public var muted: Bool
    public var size: Float
    public var color: Color
    /// The cross when muted; `nil` uses `color`.
    public var mutedColor: Color?

    public init(
        level: Float, muted: Bool = false, size: Float = 16,
        color: Color = .primary, mutedColor: Color? = nil
    ) {
        self.level = level
        self.muted = muted
        self.size = size
        self.color = color
        self.mutedColor = mutedColor
    }

    public var body: some View {
        let (level, muted, color, mutedColor) = (level, muted, color, mutedColor)
        return Canvas(label: "SpeakerMark", width: .pt(size), height: .pt(size)) { list, frame in
            SpeakerMark.paint(
                list: list, frame: frame, level: level, muted: muted,
                color: color, mutedColor: mutedColor ?? color
            )
        }
    }

    /// Draws the mark centred in the square that fits `frame`. Unlit waves
    /// stay faintly visible, so the speaker reads the same at any volume.
    public static func paint(
        list: DrawList, frame: CanvasFrame, level: Float, muted: Bool,
        color: Color, mutedColor: Color
    ) {
        let s = min(frame.w, frame.h)
        let x = frame.x + (frame.w - s) * 0.5
        let cy = frame.y + frame.h * 0.5

        // Outline from the top of the body–horn joint, clockwise: the joint
        // sees the whole outline, so it is a valid fan pivot (`polygon`).
        let b0 = x + s * 0.08
        let b1 = x + s * 0.27
        let h1 = x + s * 0.46
        let bodyHalf = s * 0.15
        let hornHalf = s * 0.34
        list.polygon([
            (b1, cy - bodyHalf), (h1, cy - hornHalf), (h1, cy + hornHalf),
            (b1, cy + bodyHalf), (b0, cy + bodyHalf), (b0, cy - bodyHalf),
        ], color: color)

        let stroke = max(1.25, s * 0.075)
        if muted {
            let mx = x + s * 0.74
            let arm = s * 0.14
            list.line(x1: mx - arm, y1: cy - arm, x2: mx + arm, y2: cy + arm,
                      color: mutedColor, width: stroke)
            list.line(x1: mx - arm, y1: cy + arm, x2: mx + arm, y2: cy - arm,
                      color: mutedColor, width: stroke)
            return
        }

        let level = min(1, max(0, level))
        let ox = x + s * 0.40
        let spread: Float = .pi * 0.27
        for i in 0..<3 {
            let r = s * (0.20 + Float(i) * 0.14)
            let lit = level + 0.001 >= Float(i + 1) / 4
            var inner: [(x: Float, y: Float)] = []
            var outer: [(x: Float, y: Float)] = []
            let steps = 10
            for k in 0...steps {
                let a = -spread + 2 * spread * Float(k) / Float(steps)
                let (c, sn) = (cos(a), sin(a))
                inner.append((ox + c * (r - stroke * 0.5), cy + sn * (r - stroke * 0.5)))
                outer.append((ox + c * (r + stroke * 0.5), cy + sn * (r + stroke * 0.5)))
            }
            list.ring(inner: inner, outer: outer, color: lit ? color : color.opacity(0.25))
        }
    }
}
