import LavaUI
import WeatherCore

/// The weather picture, drawn rather than borrowed from a font.
///
/// The same reasoning as `LavaLauncher`'s magnifier: a glyph depends on which
/// symbol fonts happen to be installed, and the emoji ones vary enough between
/// machines that "partly cloudy" can arrive as a box. These are circles and
/// rounded rectangles, so they stay crisp at any content scale and look the
/// same everywhere.
///
/// Scaled from a nominal 48pt design into whatever box it is given, so one
/// definition serves the 96pt hero and the 28pt row in the daily list.
struct SkyIcon: View {
    let sky: Sky
    /// Night swaps the sun for a moon. Only meaningful for the clear and
    /// partly-cloudy pictures — rain looks the same at midnight.
    var isDay: Bool = true
    var size: Float = 48
    var tint: Color? = nil

    var body: some View {
        Canvas(
            label: "sky \(sky)",
            width: .pt(size),
            height: .pt(size),
            paint: { draw, frame in
                let s = size / 48
                let x = frame.x
                let y = frame.y
                paint(draw, x: x, y: y, s: s)
            }
        )
    }

    private var sunColor: Color {
        tint ?? (isDay
            ? Color(r: 1.0, g: 0.78, b: 0.28)
            : Color(r: 0.86, g: 0.88, b: 0.96))
    }
    private var cloudColor: Color { tint ?? Color(r: 0.80, g: 0.84, b: 0.92) }
    private var rainColor: Color { tint ?? Color(r: 0.45, g: 0.72, b: 0.98) }
    private var snowColor: Color { tint ?? Color(r: 0.88, g: 0.94, b: 1.0) }
    private var boltColor: Color { tint ?? Color(r: 1.0, g: 0.82, b: 0.35) }

    private func paint(_ draw: DrawList, x: Float, y: Float, s: Float) {
        switch sky {
        case .clear:
            sun(draw, cx: x + 24 * s, cy: y + 24 * s, r: 11 * s, rays: true, s: s)
        case .partlyCloudy:
            sun(draw, cx: x + 30 * s, cy: y + 17 * s, r: 8 * s, rays: false, s: s)
            cloud(draw, x: x, y: y + 6 * s, s: s)
        case .cloudy:
            cloud(draw, x: x, y: y + 8 * s, s: s, color: cloudColor.opacity(0.75))
            cloud(draw, x: x, y: y + 2 * s, s: s)
        case .fog:
            cloud(draw, x: x, y: y, s: s)
            for i in 0..<3 {
                let ly = y + (34 + Float(i) * 5) * s
                draw.line(
                    x1: x + (8 + Float(i % 2) * 4) * s, y1: ly,
                    x2: x + (40 - Float(i % 2) * 4) * s, y2: ly,
                    color: cloudColor.opacity(0.7), width: 2 * s
                )
            }
        case .drizzle:
            cloud(draw, x: x, y: y, s: s)
            drops(draw, x: x, y: y, s: s, count: 2, length: 4)
        case .rain:
            cloud(draw, x: x, y: y, s: s)
            drops(draw, x: x, y: y, s: s, count: 3, length: 7)
        case .snow:
            cloud(draw, x: x, y: y, s: s)
            for i in 0..<3 {
                let cx = x + (14 + Float(i) * 10) * s
                let cy = y + (36 + Float(i % 2) * 4) * s
                draw.circle(cx: cx, cy: cy, radius: 2.2 * s, color: snowColor)
            }
        case .thunder:
            cloud(draw, x: x, y: y, s: s)
            // A bolt as two strokes: the SDF pipeline has no polygon here and
            // a zigzag reads at this size from the angles alone.
            draw.line(
                x1: x + 26 * s, y1: y + 30 * s, x2: x + 20 * s, y2: y + 39 * s,
                color: boltColor, width: 2.6 * s
            )
            draw.line(
                x1: x + 20 * s, y1: y + 39 * s, x2: x + 28 * s, y2: y + 45 * s,
                color: boltColor, width: 2.6 * s
            )
        }
    }

    private func sun(
        _ draw: DrawList, cx: Float, cy: Float, r: Float, rays: Bool, s: Float
    ) {
        if rays {
            // Eight spokes, drawn before the disc so their inner ends are
            // covered by it rather than showing as a seam.
            let step: Float = 0.7853982  // π/4
            for i in 0..<8 {
                let a = step * Float(i)
                let (dx, dy) = (cosApprox(a), sinApprox(a))
                draw.line(
                    x1: cx + dx * (r + 3 * s), y1: cy + dy * (r + 3 * s),
                    x2: cx + dx * (r + 8 * s), y2: cy + dy * (r + 8 * s),
                    color: sunColor, width: 2.2 * s
                )
            }
        }
        draw.circle(cx: cx, cy: cy, radius: r, color: sunColor)
        if !isDay {
            // A bite out of the disc turns the sun into a crescent, which is
            // cheaper and clearer at 28pt than drawing a moon outline.
            draw.circle(
                cx: cx + r * 0.55, cy: cy - r * 0.45, radius: r * 0.85,
                color: Color(r: 0.09, g: 0.11, b: 0.18)
            )
        }
    }

    private func cloud(
        _ draw: DrawList, x: Float, y: Float, s: Float, color: Color? = nil
    ) {
        let c = color ?? cloudColor
        draw.circle(cx: x + 18 * s, cy: y + 22 * s, radius: 9 * s, color: c)
        draw.circle(cx: x + 29 * s, cy: y + 21 * s, radius: 7 * s, color: c)
        draw.circle(cx: x + 24 * s, cy: y + 27 * s, radius: 8 * s, color: c)
        draw.roundedRect(
            x: x + 10 * s, y: y + 24 * s, w: 26 * s, h: 8 * s,
            color: c, radius: 4 * s
        )
    }

    private func drops(
        _ draw: DrawList, x: Float, y: Float, s: Float, count: Int, length: Float
    ) {
        for i in 0..<count {
            let dx = x + (16 + Float(i) * 8) * s
            let dy = y + (35 + Float(i % 2) * 3) * s
            draw.line(
                x1: dx, y1: dy, x2: dx - 2 * s, y2: dy + length * s,
                color: rainColor, width: 2 * s
            )
        }
    }

    // Eight fixed angles, so a table beats pulling in Foundation's trig for
    // something the compiler cannot fold anyway.
    private func cosApprox(_ a: Float) -> Float {
        let table: [Float] = [1, 0.7071, 0, -0.7071, -1, -0.7071, 0, 0.7071]
        return table[index(a)]
    }
    private func sinApprox(_ a: Float) -> Float {
        let table: [Float] = [0, 0.7071, 1, 0.7071, 0, -0.7071, -1, -0.7071]
        return table[index(a)]
    }
    private func index(_ a: Float) -> Int {
        max(0, min(7, Int((a / 0.7853982).rounded())))
    }
}
