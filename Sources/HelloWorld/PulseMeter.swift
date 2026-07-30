import Foundation
import LavaUI

/// Demo neon equalizer built on LavaUI `Canvas` (app-owned paint, not a library widget).
///
/// Yoga sizes a fixed box; every frame the paint closure emits rects/text into
/// the shared draw list. Continuous redraw is requested while playing.
struct PulseMeter: View {
    @Binding var isPlaying: Bool
    var barCount: Int
    var style: Style

    struct Style {
        var height: Float = 72
        var width: Float = 280
        var barWidth: Float = 10
        var barGap: Float = 4
        var padding: Float = 10
        var cornerRadius: Float = 10
        var background: Color = Color(r: 0.06, g: 0.07, b: 0.12).opacity(0.92)
        var labelColor: Color = Environment.current.theme.textSecondary
        var colorA: Color = Color(r: 0.20, g: 0.95, b: 0.85)
        var colorB: Color = Color(r: 0.45, g: 0.55, b: 1.0)
        var colorC: Color = Color(r: 0.95, g: 0.35, b: 0.85)
    }

    init(
        isPlaying: Binding<Bool>,
        barCount: Int = 16,
        style: Style = Style()
    ) {
        self._isPlaying = isPlaying
        self.barCount = max(4, min(32, barCount))
        self.style = style
    }

    var body: some View {
        let playing = isPlaying
        let bars = barCount
        let s = style
        Canvas(
            label: "PulseMeter",
            width: .pt(s.width),
            height: .pt(s.height),
            continuousRedraw: playing,
            onTap: {
                isPlaying.toggle()
            }
        ) { list, frame in
            Self.paint(list: list, frame: frame, playing: playing, barCount: bars, style: s)
        }
        .agentId("pulse-meter")
    }

    private static func paint(
        list: DrawList,
        frame: CanvasFrame,
        playing: Bool,
        barCount: Int,
        style: Style
    ) {
        let pad = style.padding
        let x = frame.x
        let y = frame.y
        let w = frame.w
        let h = frame.h

        list.roundedRect(
            x: x, y: y, w: w, h: h,
            color: style.background, radius: style.cornerRadius
        )

        let bars = max(4, barCount)
        let gap = style.barGap
        let usableW = max(0, w - pad * 2)
        let usableH = max(0, h - pad * 2 - 16)
        let barW = max(
            2,
            min(style.barWidth, (usableW - gap * Float(bars - 1)) / Float(bars))
        )
        let totalBarsW = Float(bars) * barW + Float(bars - 1) * gap
        let startX = x + pad + max(0, (usableW - totalBarsW) / 2)
        let baseY = y + pad + usableH

        let t = playing ? Float(FrameScheduler.now()) : 0
        for i in 0..<bars {
            let fi = Float(i)
            let wave =
                0.55 + 0.45 * sin(t * 3.1 + fi * 0.55)
                * (0.65 + 0.35 * sin(t * 1.7 + fi * 0.21))
            let idle: Float = 0.12 + 0.04 * sin(fi * 1.3)
            let level = playing ? max(0.08, min(1, wave)) : idle
            let barH = max(3, usableH * level)
            let bx = startX + fi * (barW + gap)
            let by = baseY - barH

            let u = fi / Float(max(1, bars - 1))
            let c: Color
            if u < 0.5 {
                c = Color.interpolate(style.colorA, style.colorB, u * 2)
            } else {
                c = Color.interpolate(style.colorB, style.colorC, (u - 0.5) * 2)
            }
            list.roundedRect(x: bx, y: by, w: barW, h: barH, color: c, radius: barW / 2)
            if playing, barH > 8 {
                list.roundedRect(
                    x: bx, y: by, w: barW, h: min(6, barH * 0.25),
                    color: c.lightened(0.35), radius: barW / 2
                )
            }
        }

        // Symbols face has ▶/⏸ but no Latin — draw icon + word with two faces.
        let icon = playing ? "▶" : "⏸"
        let word = " pulse"
        let iconFont = FontStore.symbols
        let textFont = FontStore.default
        let lineH = max(iconFont?.lineHeight ?? 0, textFont?.lineHeight ?? 16)
        let labelY = y + h - pad - lineH + 2
        var penX = x + pad - 4
        if let iconFont {
            let iw = iconFont.measure(icon).width
            list.text(
                icon, x: penX, y: labelY, w: iw + 4, h: lineH,
                color: style.labelColor, font: iconFont
            )
            penX += iw + 4
        }
        if let textFont {
            list.text(
                word, x: penX, y: labelY, w: w - (penX - x), h: lineH,
                color: style.labelColor, font: textFont
            )
        }
    }
}
