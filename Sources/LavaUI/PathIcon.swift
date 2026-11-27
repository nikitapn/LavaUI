import Foundation

/// A stroked icon from SVG path data, in the 24×24 box Lucide and most
/// stroke icon sets are drawn in.
///
/// `Mark` and `TransportMark` are a handful of shapes written out by hand.
/// A design hands over path strings instead — `M5 12.55a11 11 0 0 1 14 0…`
/// is the Wi-Fi glyph — and translating each into hand-placed lines is how a
/// glyph drifts from the one in the mock-up. So the string is the source:
/// parsed and flattened once per distinct path, then drawn as one
/// `DrawList.polyline` per subpath — capsules cut apart at each joint, which
/// gives the round caps and round joins these sets specify without a stroker.
///
/// Opaque colours only, in practice: where a path crosses itself (or turns
/// back on itself) the overlap is drawn twice, and a translucent stroke
/// shows it darker. The icons this is for are drawn in solid theme colours.
public struct Icon: View {
    public var shapes: [IconShape]
    public var size: Float
    public var color: Color
    /// In the 24-unit box, as SVG's `stroke-width`, scaled with the icon.
    public var strokeWidth: Float
    /// Parts of the glyph drawn under `shapes` in `faintColor` — the arcs
    /// of a Wi-Fi fan the signal does not reach. Opaque, for the same
    /// reason `color` is.
    public var faint: [IconShape]
    public var faintColor: Color
    /// Centre the ink rather than the 24-unit box. Icon sets draw some
    /// glyphs off-centre in their box — a Wi-Fi fan sits low, a speaker
    /// with no waves leans left — which shows as soon as one sits on a
    /// disc. Measured over `shapes` and `faint` together, so a glyph whose
    /// faint part changes does not move.
    public var centersInk: Bool
    /// The square the view takes, with the glyph drawn at its exact centre;
    /// `nil` for the glyph's own `size`.
    ///
    /// For a glyph centred on something whose size differs from it by an
    /// odd number of points — a 15pt glyph on a 26pt disc. Centred between
    /// spacers instead, its box starts at 5.5, layout rounds that to 6, and
    /// the glyph sits half a pixel off. Drawn from the box, the strokes land
    /// where they belong; they are antialiased and need no whole pixel.
    public var box: Float?

    public init(_ shapes: [IconShape], size: Float = 16, color: Color = .primary,
                strokeWidth: Float = 2, faint: [IconShape] = [],
                faintColor: Color = .clear, centersInk: Bool = true, box: Float? = nil) {
        self.shapes = shapes
        self.size = size
        self.color = color
        self.strokeWidth = strokeWidth
        self.faint = faint
        self.faintColor = faintColor
        self.centersInk = centersInk
        self.box = box
    }

    /// One path, the common case: `Icon("M18 6 6 18M6 6l12 12", size: 12)`.
    public init(_ d: String, size: Float = 16, color: Color = .primary,
                strokeWidth: Float = 2) {
        self.init([.path(d)], size: size, color: color, strokeWidth: strokeWidth)
    }

    public var body: some View {
        let shapes = shapes, color = color, strokeWidth = strokeWidth, size = size
        let faint = faint, faintColor = faintColor
        let shift = centersInk ? IconPathCache.inkOffset(shapes + faint, strokeWidth: strokeWidth)
                               : (x: Float(0), y: Float(0))
        let side = box ?? size
        return Canvas(label: "icon", width: .pt(side), height: .pt(side)) { list, frame in
            let scale = size / 24
            let inset = (side - size) / 2
            let x = frame.x + inset + shift.x * scale, y = frame.y + inset + shift.y * scale
            if !faint.isEmpty {
                list.strokeIcon(faint, x: x, y: y, size: size,
                                color: faintColor, strokeWidth: strokeWidth)
            }
            list.strokeIcon(shapes, x: x, y: y, size: size,
                            color: color, strokeWidth: strokeWidth)
        }
    }
}

/// One element of an icon, as the SVG elements stroke icon sets use.
public enum IconShape: Hashable, Sendable {
    /// SVG path data.
    case path(String)
    case circle(cx: Float, cy: Float, r: Float)
    case rect(x: Float, y: Float, width: Float, height: Float, rx: Float = 0)
    /// A filled shape rather than a stroked one. Fanned from its first point,
    /// so it must be convex — or star-shaped from that point — as
    /// `DrawList.polygon` requires. Each subpath is filled on its own.
    case fill(String)

    /// The same element as path data, so there is one flattener.
    var pathData: String {
        switch self {
        case .path(let d), .fill(let d):
            return d
        case let .circle(cx, cy, r):
            return "M\(cx - r) \(cy)a\(r) \(r) 0 1 0 \(2 * r) 0a\(r) \(r) 0 1 0 \(-2 * r) 0Z"
        case let .rect(x, y, w, h, rx):
            let r = min(rx, w / 2, h / 2)
            guard r > 0 else { return "M\(x) \(y)h\(w)v\(h)h\(-w)Z" }
            return "M\(x + r) \(y)h\(w - 2 * r)a\(r) \(r) 0 0 1 \(r) \(r)v\(h - 2 * r)"
                + "a\(r) \(r) 0 0 1 \(-r) \(r)h\(-(w - 2 * r))a\(r) \(r) 0 0 1 \(-r) \(-r)"
                + "v\(-(h - 2 * r))a\(r) \(r) 0 0 1 \(r) \(-r)Z"
        }
    }

    var isFill: Bool {
        if case .fill = self { return true }
        return false
    }
}

extension DrawList {
    /// Draws `shapes`, authored in a 24-unit box, into the `size`-pixel square
    /// at `x`,`y`. See `Icon`.
    public func strokeIcon(
        _ shapes: [IconShape], x: Float, y: Float, size: Float,
        color: Color, strokeWidth: Float = 2
    ) {
        let scale = size / 24
        let width = strokeWidth * scale
        for shape in shapes {
            for subpath in IconPathCache.flattened(shape.pathData) {
                if shape.isFill {
                    guard subpath.count >= 3 else { continue }
                    polygon(subpath.map { (x + $0.x * scale, y + $0.y * scale) }, color: color)
                    continue
                }
                if subpath.count < 2 {
                    // A bare moveto draws nothing in SVG; `h.01` after it is
                    // how these sets draw a dot, and arrives as two points.
                    continue
                }
                // One polyline, not a `line` per segment: the renderer cuts
                // neighbouring capsules apart at each joint, where separate
                // lines would blend their antialiased edges over each other.
                polyline(subpath.map { (x + $0.x * scale, y + $0.y * scale) },
                         color: color, width: width)
            }
        }
    }
}

/// Parsed and flattened paths, by their source string. Icons are drawn every
/// frame they are visible, and parsing an arc is trigonometry; a desktop has
/// a few dozen distinct paths, so nothing is ever evicted.
enum IconPathCache {
    nonisolated(unsafe) private static var cache: [String: [[IconPoint]]] = [:]
    private static let lock = NSLock()

    /// How far to move `shapes`, in path units, so their ink — the stroke's
    /// half-width included — is centred in the 24-unit box.
    static func inkOffset(_ shapes: [IconShape], strokeWidth: Float) -> (x: Float, y: Float) {
        var minX = Float.infinity, minY = Float.infinity
        var maxX = -Float.infinity, maxY = -Float.infinity
        for shape in shapes {
            let pad = shape.isFill ? 0 : strokeWidth / 2
            for subpath in flattened(shape.pathData) where subpath.count > 1 || shape.isFill {
                for p in subpath {
                    minX = min(minX, p.x - pad); maxX = max(maxX, p.x + pad)
                    minY = min(minY, p.y - pad); maxY = max(maxY, p.y + pad)
                }
            }
        }
        guard minX.isFinite, maxX.isFinite else { return (0, 0) }
        return (12 - (minX + maxX) / 2, 12 - (minY + maxY) / 2)
    }

    static func flattened(_ d: String) -> [[IconPoint]] {
        lock.lock()
        defer { lock.unlock() }
        if let hit = cache[d] { return hit }
        let result = IconPathParser.flatten(d)
        cache[d] = result
        return result
    }
}

struct IconPoint: Equatable {
    var x: Float
    var y: Float
}

/// SVG path data → polylines, one per subpath, in the path's own units.
///
/// All of `M L H V C S Q T A Z`, absolute and relative, with implicit
/// repeats (`M1 2 3 4` is a move and a line). Subdivision follows curvature:
/// long, nearly straight spans need few chords, and tight bends need more.
enum IconPathParser {
    /// Maximum distance from a curve to its chord in the 24-unit icon box.
    /// A 30-point icon can deviate by at most 1/16 of a layout pixel.
    static let tolerance: Float = 0.05
    private static let maxSubdivisionDepth = 10

    static func flatten(_ d: String) -> [[IconPoint]] {
        var scanner = Tokens(d)
        var subpaths: [[IconPoint]] = []
        var current: [IconPoint] = []
        var pen = IconPoint(x: 0, y: 0)
        var start = pen
        // The reflected control point for S and T: the previous curve's last
        // control point, or nil when the previous command was not one.
        var lastCubic: IconPoint?
        var lastQuad: IconPoint?
        var command: Character = "M"

        func finish() {
            if !current.isEmpty { subpaths.append(current) }
            current = []
        }
        func lineTo(_ p: IconPoint) {
            if current.isEmpty { current.append(pen) }
            current.append(p)
            pen = p
        }

        while true {
            let next: Character
            if let explicit = scanner.peekCommand() {
                scanner.advance()
                next = explicit
            } else if scanner.hasNumber, command != "Z", command != "z" {
                // An implicit repeat of the last command.
                next = command
            } else {
                break
            }
            command = next
            let relative = next.isLowercase
            let base = relative ? pen : IconPoint(x: 0, y: 0)
            func point() -> IconPoint? {
                guard let x = scanner.number(), let y = scanner.number() else { return nil }
                return IconPoint(x: base.x + x, y: base.y + y)
            }
            var cubic: IconPoint?
            var quad: IconPoint?
            switch next.uppercased().first! {
            case "M":
                guard let p = point() else { return closing(subpaths, current) }
                finish()
                pen = p
                start = p
                current = [p]
                command = relative ? "l" : "L"
            case "L":
                guard let p = point() else { return closing(subpaths, current) }
                lineTo(p)
            case "H":
                guard let v = scanner.number() else { return closing(subpaths, current) }
                lineTo(IconPoint(x: relative ? pen.x + v : v, y: pen.y))
            case "V":
                guard let v = scanner.number() else { return closing(subpaths, current) }
                lineTo(IconPoint(x: pen.x, y: relative ? pen.y + v : v))
            case "C":
                guard let c1 = point(), let c2 = point(), let p = point() else {
                    return closing(subpaths, current)
                }
                cubicTo(c1, c2, p, pen: &pen, into: &current)
                cubic = c2
            case "S":
                guard let c2 = point(), let p = point() else { return closing(subpaths, current) }
                let c1 = lastCubic.map { IconPoint(x: 2 * pen.x - $0.x, y: 2 * pen.y - $0.y) } ?? pen
                cubicTo(c1, c2, p, pen: &pen, into: &current)
                cubic = c2
            case "Q":
                guard let c = point(), let p = point() else { return closing(subpaths, current) }
                quadTo(c, p, pen: &pen, into: &current)
                quad = c
            case "T":
                guard let p = point() else { return closing(subpaths, current) }
                let c = lastQuad.map { IconPoint(x: 2 * pen.x - $0.x, y: 2 * pen.y - $0.y) } ?? pen
                quadTo(c, p, pen: &pen, into: &current)
                quad = c
            case "A":
                guard let rx = scanner.number(), let ry = scanner.number(),
                      let rotation = scanner.number(),
                      let large = scanner.flag(), let sweep = scanner.flag(),
                      let p = point()
                else { return closing(subpaths, current) }
                arcTo(rx: rx, ry: ry, rotation: rotation, large: large, sweep: sweep,
                      to: p, pen: &pen, into: &current)
            case "Z":
                if !current.isEmpty, current.last != start { current.append(start) }
                finish()
                pen = start
                current = []
            default:
                return closing(subpaths, current)
            }
            lastCubic = cubic
            lastQuad = quad
        }
        finish()
        return subpaths
    }

    /// The subpaths so far, on a parse error: what parsed is drawn.
    private static func closing(_ subpaths: [[IconPoint]], _ current: [IconPoint]) -> [[IconPoint]] {
        current.isEmpty ? subpaths : subpaths + [current]
    }

    private static func midpoint(_ a: IconPoint, _ b: IconPoint) -> IconPoint {
        IconPoint(x: (a.x + b.x) * 0.5, y: (a.y + b.y) * 0.5)
    }

    private static func nearChord(_ point: IconPoint, _ start: IconPoint, _ end: IconPoint) -> Bool {
        let dx = end.x - start.x, dy = end.y - start.y
        let x = point.x - start.x, y = point.y - start.y
        let lengthSquared = dx * dx + dy * dy
        // Measure against the finite segment so a collinear loop or an
        // overshooting control point cannot collapse onto a shorter line.
        let t = lengthSquared > 0 ? min(1, max(0, (x * dx + y * dy) / lengthSquared)) : 0
        let ex = x - t * dx, ey = y - t * dy
        return ex * ex + ey * ey <= tolerance * tolerance
    }

    private static func cubicTo(
        _ c1: IconPoint, _ c2: IconPoint, _ p: IconPoint,
        pen: inout IconPoint, into current: inout [IconPoint]
    ) {
        if current.isEmpty { current.append(pen) }
        flattenCubic(pen, c1, c2, p, depth: 0, into: &current)
        pen = p
    }

    private static func flattenCubic(
        _ start: IconPoint, _ c1: IconPoint, _ c2: IconPoint, _ end: IconPoint,
        depth: Int, into points: inout [IconPoint]
    ) {
        if depth == maxSubdivisionDepth || (nearChord(c1, start, end) && nearChord(c2, start, end)) {
            points.append(end)
            return
        }
        let a = midpoint(start, c1), b = midpoint(c1, c2), c = midpoint(c2, end)
        let left = midpoint(a, b), right = midpoint(b, c)
        let middle = midpoint(left, right)
        flattenCubic(start, a, left, middle, depth: depth + 1, into: &points)
        flattenCubic(middle, right, c, end, depth: depth + 1, into: &points)
    }

    private static func quadTo(
        _ c: IconPoint, _ p: IconPoint, pen: inout IconPoint, into current: inout [IconPoint]
    ) {
        if current.isEmpty { current.append(pen) }
        flattenQuad(pen, c, p, depth: 0, into: &current)
        pen = p
    }

    private static func flattenQuad(
        _ start: IconPoint, _ control: IconPoint, _ end: IconPoint,
        depth: Int, into points: inout [IconPoint]
    ) {
        if depth == maxSubdivisionDepth || nearChord(control, start, end) {
            points.append(end)
            return
        }
        let left = midpoint(start, control), right = midpoint(control, end)
        let middle = midpoint(left, right)
        flattenQuad(start, left, middle, depth: depth + 1, into: &points)
        flattenQuad(middle, right, end, depth: depth + 1, into: &points)
    }

    /// SVG's endpoint arc, converted to centre form (SVG 1.1, F.6.5–F.6.6).
    private static func arcTo(
        rx rxIn: Float, ry ryIn: Float, rotation: Float, large: Bool, sweep: Bool,
        to p: IconPoint, pen: inout IconPoint, into current: inout [IconPoint]
    ) {
        let p0 = pen
        if current.isEmpty { current.append(p0) }
        var rx = abs(rxIn), ry = abs(ryIn)
        guard rx > 0, ry > 0, p0 != p else {
            current.append(p)
            pen = p
            return
        }
        let phi = rotation * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)
        let dx = (p0.x - p.x) / 2, dy = (p0.y - p.y) / 2
        let x1 = cosPhi * dx + sinPhi * dy
        let y1 = -sinPhi * dx + cosPhi * dy
        // Radii too small to reach are scaled up until they just do.
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 {
            rx *= lambda.squareRoot()
            ry *= lambda.squareRoot()
        }
        let numerator = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let denominator = rx * rx * y1 * y1 + ry * ry * x1 * x1
        var coefficient = (max(0, numerator) / denominator).squareRoot()
        if large == sweep { coefficient = -coefficient }
        let cx1 = coefficient * rx * y1 / ry
        let cy1 = -coefficient * ry * x1 / rx
        let cx = cosPhi * cx1 - sinPhi * cy1 + (p0.x + p.x) / 2
        let cy = sinPhi * cx1 + cosPhi * cy1 + (p0.y + p.y) / 2

        func angle(_ ux: Float, _ uy: Float, _ vx: Float, _ vy: Float) -> Float {
            let a = atan2(ux * vy - uy * vx, ux * vx + uy * vy)
            return a
        }
        let theta1 = angle(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry)
        var delta = angle((x1 - cx1) / rx, (y1 - cy1) / ry, (-x1 - cx1) / rx, (-y1 - cy1) / ry)
        if !sweep, delta > 0 { delta -= 2 * .pi }
        if sweep, delta < 0 { delta += 2 * .pi }

        // Bound the sagitta using the larger radius: mapping a unit circle
        // to this ellipse can stretch a chord's error by at most that radius.
        let step = min(Float.pi / 2, 4 * asin(min(1, (tolerance / max(rx, ry) / 2).squareRoot())))
        let n = Int(min(256, max(1, (abs(delta) / step).rounded(.up))))
        for i in 1...n {
            let t = theta1 + delta * Float(i) / Float(n)
            let ex = rx * cos(t), ey = ry * sin(t)
            current.append(IconPoint(x: cosPhi * ex - sinPhi * ey + cx,
                                     y: sinPhi * ex + cosPhi * ey + cy))
        }
        // Land exactly on the endpoint the path named, not on cos/sin's idea
        // of it, so a following segment joins without a sliver.
        current[current.count - 1] = p
        pen = p
    }

    /// The path string as commands, numbers and arc flags.
    struct Tokens {
        private let chars: [Character]
        private var index = 0

        init(_ text: String) { chars = Array(text) }

        private mutating func skipSeparators() {
            while index < chars.count, chars[index] == " " || chars[index] == ","
                    || chars[index] == "\n" || chars[index] == "\t" || chars[index] == "\r" {
                index += 1
            }
        }

        mutating func peekCommand() -> Character? {
            skipSeparators()
            guard index < chars.count else { return nil }
            let c = chars[index]
            return "MmLlHhVvCcSsQqTtAaZz".contains(c) ? c : nil
        }

        mutating func advance() { index += 1 }

        var hasNumber: Bool {
            mutating get {
                skipSeparators()
                guard index < chars.count else { return false }
                let c = chars[index]
                return c.isNumber || c == "-" || c == "+" || c == "."
            }
        }

        /// An arc flag: one character, `0` or `1`, which SVG lets run into
        /// the next number with no separator (`a9 9 0 1 1-6.2-8.56`).
        mutating func flag() -> Bool? {
            skipSeparators()
            guard index < chars.count else { return nil }
            switch chars[index] {
            case "0": index += 1; return false
            case "1": index += 1; return true
            default: return nil
            }
        }

        mutating func number() -> Float? {
            skipSeparators()
            var text = ""
            if index < chars.count, chars[index] == "-" || chars[index] == "+" {
                text.append(chars[index])
                index += 1
            }
            var seenDot = false, seenDigit = false, seenExponent = false
            while index < chars.count {
                let c = chars[index]
                if c.isNumber {
                    seenDigit = true
                } else if c == ".", !seenDot, !seenExponent {
                    seenDot = true
                } else if c == "e" || c == "E", seenDigit, !seenExponent {
                    seenExponent = true
                    text.append(c)
                    index += 1
                    if index < chars.count, chars[index] == "-" || chars[index] == "+" {
                        text.append(chars[index])
                        index += 1
                    }
                    continue
                } else {
                    break
                }
                text.append(c)
                index += 1
            }
            return seenDigit ? Float(text) : nil
        }
    }
}
