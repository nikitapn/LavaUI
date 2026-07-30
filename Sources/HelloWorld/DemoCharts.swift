import Foundation
import LavaUI

// App-owned charts on LavaUI `Canvas` — not framework widgets.

// MARK: - Pie

struct PieSlice: Identifiable, Equatable {
    let id: Int
    var label: String
    var value: Float
    var color: Color
}

/// Donut/pie chart with optional selected wedge (tap cycles).
struct PieChart: View {
    var slices: [PieSlice]
    @Binding var selectedId: Int?
    var size: Float
    var innerRatio: Float
    var title: String

    init(
        slices: [PieSlice],
        selectedId: Binding<Int?> = .constant(nil),
        size: Float = 160,
        innerRatio: Float = 0.55,
        title: String = "Share"
    ) {
        self.slices = slices
        self._selectedId = selectedId
        self.size = size
        self.innerRatio = min(0.85, max(0, innerRatio))
        self.title = title
    }

    var body: some View {
        let data = slices
        let sel = selectedId
        let ir = innerRatio
        let t = title
        Canvas(
            label: "PieChart",
            width: .pt(size),
            height: .pt(size + 28),
            continuousRedraw: false,
            onTap: {
                cycleSelection()
            }
        ) { list, frame in
            Self.paint(
                list: list, frame: frame, slices: data,
                selectedId: sel, innerRatio: ir, title: t
            )
        }
        .agentId("pie-chart")
    }

    private func cycleSelection() {
        let ids = slices.map(\.id)
        guard !ids.isEmpty else { return }
        if let cur = selectedId, let i = ids.firstIndex(of: cur) {
            selectedId = ids[(i + 1) % ids.count]
        } else {
            selectedId = ids[0]
        }
    }

    private static func paint(
        list: DrawList,
        frame: CanvasFrame,
        slices: [PieSlice],
        selectedId: Int?,
        innerRatio: Float,
        title: String
    ) {
        let total = max(0.0001, slices.reduce(Float(0)) { $0 + max(0, $1.value) })
        let chartH = frame.h - 24
        let cx = frame.x + frame.w / 2
        let cy = frame.y + chartH / 2
        let r = min(frame.w, chartH) * 0.42
        let inner = r * innerRatio

        // Soft plate
        list.circle(cx: cx, cy: cy, radius: r + 6,
                    color: Color(r: 0.08, g: 0.09, b: 0.14).opacity(0.9))

        var angle: Float = -.pi / 2  // start at top
        for slice in slices {
            let span = max(0, slice.value) / total * (.pi * 2)
            let selected = slice.id == selectedId
            let rr = selected ? r + 5 : r
            list.pieSlice(
                cx: cx, cy: cy,
                innerRadius: inner, outerRadius: rr,
                startAngle: angle, endAngle: angle + span,
                color: slice.color
            )
            if selected {
                // Highlight rim: a thin ring segment flush with the wedge's
                // own edge, not a stroke — a capsule stroke's round caps
                // overshoot past a0/a1 by about half the stroke width,
                // bleeding a pale sliver into the neighbouring wedge. A
                // filled ring shares the wedge's own hard-cut angular
                // boundary instead, so there's nothing to overshoot with.
                list.pieSlice(
                    cx: cx, cy: cy,
                    innerRadius: rr, outerRadius: rr + 2.5,
                    startAngle: angle, endAngle: angle + span,
                    color: slice.color.lightened(0.35)
                )
            }
            angle += span
        }

        // Hole / center label
        list.circle(cx: cx, cy: cy, radius: max(1, inner - 1),
                    color: Color(r: 0.07, g: 0.08, b: 0.12))
        if let id = selectedId, let s = slices.first(where: { $0.id == id }) {
            let pct = Int((s.value / total * 100).rounded())
            drawCenteredText(
                list, s.label, cx: cx, cy: cy - 8,
                color: Environment.current.theme.textPrimary, font: FontStore.default
            )
            drawCenteredText(
                list, "\(pct)%", cx: cx, cy: cy + 10,
                color: s.color, font: FontStore.default
            )
        } else {
            drawCenteredText(
                list, title, cx: cx, cy: cy,
                color: Environment.current.theme.textSecondary, font: FontStore.default
            )
        }

        // Caption
        if let font = FontStore.default {
            list.text(
                "tap · cycle slice",
                x: frame.x, y: frame.y + frame.h - font.lineHeight,
                w: frame.w, h: font.lineHeight,
                color: Environment.current.theme.textSecondary, font: font
            )
        }
    }

    private static func drawCenteredText(
        _ list: DrawList, _ string: String,
        cx: Float, cy: Float, color: Color, font: UIFont?
    ) {
        guard let font else { return }
        let m = font.measure(string)
        list.text(
            string,
            x: cx - m.width / 2 - 4,
            y: cy - font.lineHeight / 2,
            w: m.width + 8, h: font.lineHeight,
            color: color, font: font
        )
    }
}

// MARK: - Line chart

struct LineSeries: Equatable {
    var name: String
    var color: Color
    /// Evenly spaced samples (y), left → right.
    var samples: [Float]
}

/// Multi-series line chart with grid, optional live secondary wave.
struct LineChart: View {
    var series: [LineSeries]
    var width: Float
    var height: Float
    /// When true, a synthetic “live” series is layered on top.
    var live: Bool
    var title: String

    init(
        series: [LineSeries],
        width: Float = 320,
        height: Float = 160,
        live: Bool = true,
        title: String = "Telemetry"
    ) {
        self.series = series
        self.width = width
        self.height = height
        self.live = live
        self.title = title
    }

    var body: some View {
        let s = series
        let liveOn = live
        let t = title
        Canvas(
            label: "LineChart",
            width: .pt(width),
            height: .pt(height),
            continuousRedraw: liveOn
        ) { list, frame in
            Self.paint(list: list, frame: frame, series: s, live: liveOn, title: t)
        }
        .agentId("line-chart")
    }

    private static func paint(
        list: DrawList,
        frame: CanvasFrame,
        series: [LineSeries],
        live: Bool,
        title: String
    ) {
        let padL: Float = 36
        let padR: Float = 12
        let padT: Float = 22
        let padB: Float = 22
        let plot = CanvasFrame(
            x: frame.x + padL,
            y: frame.y + padT,
            w: max(1, frame.w - padL - padR),
            h: max(1, frame.h - padT - padB)
        )

        // Card
        list.roundedRect(
            x: frame.x, y: frame.y, w: frame.w, h: frame.h,
            color: Color(r: 0.06, g: 0.07, b: 0.12).opacity(0.92),
            radius: 10
        )

        // Title
        if let font = FontStore.default {
            list.text(
                title,
                x: frame.x + 10, y: frame.y + 4,
                w: frame.w - 20, h: font.lineHeight,
                color: Environment.current.theme.accent, font: font
            )
        }

        // Build sample set for scale
        var all = series.flatMap(\.samples)
        if live {
            all += liveSamples(count: 48)
        }
        let yMin = min(all.min() ?? 0, 0)
        let yMax = max(all.max() ?? 1, yMin + 0.01)

        // Grid
        let gridColor = Color(r: 0.25, g: 0.28, b: 0.36).opacity(0.55)
        let axisColor = Color(r: 0.45, g: 0.48, b: 0.55)
        for i in 0...4 {
            let t = Float(i) / 4
            let gy = plot.y + plot.h * (1 - t)
            list.line(
                x1: plot.x, y1: gy, x2: plot.x + plot.w, y2: gy,
                color: gridColor, width: 1
            )
            if let font = FontStore.default {
                let v = yMin + (yMax - yMin) * t
                let label = String(format: "%.1f", v)
                list.text(
                    label,
                    x: frame.x + 2, y: gy - font.lineHeight / 2,
                    w: padL - 4, h: font.lineHeight,
                    color: Environment.current.theme.textSecondary, font: font
                )
            }
        }
        list.line(
            x1: plot.x, y1: plot.y, x2: plot.x, y2: plot.y + plot.h,
            color: axisColor, width: 1.5
        )
        list.line(
            x1: plot.x, y1: plot.y + plot.h, x2: plot.x + plot.w, y2: plot.y + plot.h,
            color: axisColor, width: 1.5
        )

        for s in series {
            strokeSeries(list: list, plot: plot, samples: s.samples,
                         yMin: yMin, yMax: yMax, color: s.color, width: 2.2)
        }
        if live {
            let liveColor = Color(r: 0.3, g: 0.95, b: 0.75)
            strokeSeries(
                list: list, plot: plot, samples: liveSamples(count: 48),
                yMin: yMin, yMax: yMax, color: liveColor, width: 2.0
            )
            // Moving head
            if let last = liveSamples(count: 48).last {
                let n = 48
                let px = plot.x + plot.w * Float(n - 1) / Float(max(1, n - 1))
                let py = plot.y + plot.h * (1 - (last - yMin) / (yMax - yMin))
                list.circle(cx: px, cy: py, radius: 4, color: liveColor)
                list.circle(cx: px, cy: py, radius: 2,
                            color: Color(r: 0.05, g: 0.08, b: 0.1))
            }
        }

        // Legend
        if let font = FontStore.default {
            var lx = plot.x
            let ly = frame.y + frame.h - font.lineHeight - 2
            for s in series {
                list.roundedRect(x: lx, y: ly + 4, w: 10, h: 10, color: s.color, radius: 2)
                list.text(
                    " " + s.name, x: lx + 10, y: ly,
                    w: 80, h: font.lineHeight,
                    color: Environment.current.theme.textSecondary, font: font
                )
                lx += 70
            }
            if live {
                list.roundedRect(
                    x: lx, y: ly + 4, w: 10, h: 10,
                    color: Color(r: 0.3, g: 0.95, b: 0.75), radius: 2
                )
                list.text(
                    " live", x: lx + 10, y: ly,
                    w: 50, h: font.lineHeight,
                    color: Environment.current.theme.textSecondary, font: font
                )
            }
        }
    }

    private static func liveSamples(count: Int) -> [Float] {
        let t = Float(FrameScheduler.now())
        return (0..<count).map { i in
            let x = Float(i) / Float(max(1, count - 1))
            return 0.45
                + 0.25 * sin(t * 1.8 + x * 6.5)
                + 0.12 * sin(t * 3.3 + x * 14)
                + 0.08 * sin(t * 0.7 + x * 2)
        }
    }

    private static func strokeSeries(
        list: DrawList, plot: CanvasFrame, samples: [Float],
        yMin: Float, yMax: Float, color: Color, width: Float
    ) {
        guard samples.count >= 2 else { return }
        let n = samples.count
        let range = yMax - yMin
        func pt(_ i: Int) -> (Float, Float) {
            let x = plot.x + plot.w * Float(i) / Float(n - 1)
            let y = plot.y + plot.h * (1 - (samples[i] - yMin) / range)
            return (x, y)
        }
        var (px, py) = pt(0)
        for i in 1..<n {
            let (nx, ny) = pt(i)
            list.line(x1: px, y1: py, x2: nx, y2: ny, color: color, width: width)
            px = nx
            py = ny
        }
        // Vertices
        for i in 0..<n {
            let (x, y) = pt(i)
            list.circle(cx: x, cy: y, radius: 2.5, color: color)
        }
    }
}
