import LavaUI
import WeatherCore

/// The sky behind the window, coloured by what the sky is doing.
///
/// Glass is only as interesting as what is behind it: over a flat fill a
/// frosted panel is a slightly different flat fill. So the window gets a
/// gradient keyed to the current conditions, and a few soft pools of light
/// that the panels slide across as the forecast scrolls — which is what makes
/// them read as glass rather than as grey boxes.
struct SkyBackdrop: View {
    let sky: Sky
    let isDay: Bool

    var body: some View {
        let palette = SkyPalette(sky: sky, isDay: isDay)
        return Canvas(
            label: "sky backdrop",
            width: .pct(100),
            height: .pct(100),
            paint: { draw, frame in
                draw.linearGradientRect(
                    x: frame.x, y: frame.y, w: frame.w, h: frame.h,
                    from: palette.top, to: palette.bottom
                )
                // Where the hero's icon sits, so the sun has a halo.
                Self.glow(
                    draw, cx: frame.x + frame.w * 0.2, cy: frame.y + frame.h * 0.14,
                    radius: frame.w * 0.55, color: palette.glow
                )
                // Lower down, for the week list to catch.
                Self.glow(
                    draw, cx: frame.x + frame.w * 0.95, cy: frame.y + frame.h * 0.6,
                    radius: frame.w * 0.5, color: palette.accent
                )
                Self.glow(
                    draw, cx: frame.x + frame.w * 0.1, cy: frame.y + frame.h * 0.95,
                    radius: frame.w * 0.4, color: palette.glow.opacity(0.7)
                )
            }
        )
    }

    /// A soft disc as stacked circles: no radial gradient in the draw list,
    /// and the steps are fine enough that the blur under the glass hides them.
    private static func glow(
        _ draw: DrawList, cx: Float, cy: Float, radius: Float, color: Color
    ) {
        // 48, not fewer: at 24 the steps showed as contour lines on the
        // accent glow wherever no glass was over it to blur them away.
        let rings = 48
        for i in 0..<rings {
            let t = Float(i) / Float(rings)
            // Each ring a little stronger toward the middle: the sum rises
            // smoothly instead of plateauing into a visible disc.
            draw.circle(
                cx: cx, cy: cy, radius: radius * (1 - t),
                color: color.opacity(color.a * 0.011 * (0.5 + t))
            )
        }
    }
}

/// Colours for one kind of sky. sRGB, like everything else here — tuned by
/// eye, not derived.
struct SkyPalette {
    let top: Color
    let bottom: Color
    /// The warm light: the sun's halo by day, a cooler moonlight at night.
    let glow: Color
    /// A second light of another hue, so the panels do not all frost the same.
    let accent: Color

    init(sky: Sky, isDay: Bool) {
        switch (sky, isDay) {
        case (.clear, true):
            top = Color(r: 0.09, g: 0.27, b: 0.60)
            bottom = Color(r: 0.30, g: 0.45, b: 0.74)
            glow = Color(r: 1.00, g: 0.74, b: 0.34)
            accent = Color(r: 0.95, g: 0.45, b: 0.62)
        case (.partlyCloudy, true):
            top = Color(r: 0.13, g: 0.28, b: 0.52)
            bottom = Color(r: 0.38, g: 0.47, b: 0.64)
            glow = Color(r: 1.00, g: 0.80, b: 0.46)
            accent = Color(r: 0.60, g: 0.52, b: 0.90)
        case (.cloudy, true), (.fog, true):
            top = Color(r: 0.20, g: 0.23, b: 0.30)
            bottom = Color(r: 0.36, g: 0.39, b: 0.46)
            glow = Color(r: 0.80, g: 0.82, b: 0.88)
            accent = Color(r: 0.52, g: 0.62, b: 0.78)
        case (.drizzle, true), (.rain, true):
            top = Color(r: 0.09, g: 0.15, b: 0.25)
            bottom = Color(r: 0.20, g: 0.28, b: 0.40)
            glow = Color(r: 0.40, g: 0.66, b: 0.90)
            accent = Color(r: 0.30, g: 0.78, b: 0.74)
        case (.snow, true):
            top = Color(r: 0.26, g: 0.34, b: 0.48)
            bottom = Color(r: 0.48, g: 0.56, b: 0.68)
            glow = Color(r: 0.90, g: 0.94, b: 1.00)
            accent = Color(r: 0.62, g: 0.74, b: 0.96)
        case (.thunder, true):
            top = Color(r: 0.10, g: 0.08, b: 0.18)
            bottom = Color(r: 0.26, g: 0.18, b: 0.34)
            glow = Color(r: 0.70, g: 0.52, b: 1.00)
            accent = Color(r: 1.00, g: 0.78, b: 0.36)
        case (.clear, false), (.partlyCloudy, false):
            top = Color(r: 0.03, g: 0.04, b: 0.12)
            bottom = Color(r: 0.11, g: 0.11, b: 0.28)
            glow = Color(r: 0.56, g: 0.62, b: 0.95)
            accent = Color(r: 0.62, g: 0.34, b: 0.80)
        case (_, false):
            // Weather at night is mostly the dark: keep the day's hue, lose
            // most of its light.
            let day = SkyPalette(sky: sky, isDay: true)
            top = day.top.scaled(0.45)
            bottom = day.bottom.scaled(0.45)
            glow = day.glow.scaled(0.7)
            accent = day.accent.scaled(0.7)
        }
    }
}

/// How the panels on that sky are drawn. One place, so the hero, the strip
/// and the week cannot each grow their own idea of glass.
enum Glass {
    /// A dark tint rather than a white frost: the text on it is light, and a
    /// clear-day sky behind white frost leaves it nothing to stand out from.
    static let fill = Color(r: 0.03, g: 0.04, b: 0.10, a: 0.30)
    static let border = Color(r: 1, g: 1, b: 1, a: 0.14)
    static let blur: Float = 18
    static let radius: Float = 18
    /// Cards and rows inside a panel: a lighter lift, not a second pane of
    /// glass — each backdrop blur is a render-pass break and a blur, and the
    /// strip alone has twenty-four cards.
    static let tile = Color(r: 1, g: 1, b: 1, a: 0.06)
    static let track = Color(r: 1, g: 1, b: 1, a: 0.14)
}

/// Text on the sky and on the glass.
///
/// Not the theme's: the theme is the desktop's, and it changes under the app
/// (`SubscribeTheme`), while this window paints its own sky whatever the
/// desktop wears. A light theme's dark text on a night sky would vanish, and
/// even the dark ones tint their greys for their own fills — nebula's purple
/// dims sank into a blue one. White at an alpha keeps the same ladder of
/// emphasis over whatever the weather has put behind it. The search sheet is
/// drawn on a theme surface and keeps the theme's.
enum Ink {
    static let primary = Color(r: 1, g: 1, b: 1, a: 0.96)
    static let secondary = Color(r: 1, g: 1, b: 1, a: 0.78)
    static let dim = Color(r: 1, g: 1, b: 1, a: 0.58)
    static let hover = Color(r: 1, g: 1, b: 1, a: 0.12)
}

extension View {
    /// A frosted panel over `SkyBackdrop`.
    func glassPanel() -> some View {
        self.background(Glass.fill)
            .border(Glass.border)
            .cornerRadius(Glass.radius)
            .backdropBlur(radius: Glass.blur)
    }
}

private extension Color {
    func scaled(_ k: Float) -> Color {
        Color(r: r * k, g: g * k, b: b * k, a: a)
    }
}
