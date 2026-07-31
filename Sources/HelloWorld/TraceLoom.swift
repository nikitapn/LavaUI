import Foundation
import LavaUI
import TraceLoomCore

private struct DisplaySeries: Identifiable {
    let id: Int
    let series: TraceSeries
    let color: Color
}

public struct TraceLoom: View {
    @State private var rules = TraceLoom.sampleRules
    @State private var log = TraceLoom.sampleLog

    public init() {}

    private var result: TraceParseResult {
        TraceParser.parse(log: log, rulesSource: rules)
    }

    private var displayed: [DisplaySeries] {
        let colors = TraceLoom.palette
        return result.series.enumerated().map {
            DisplaySeries(id: $0.offset, series: $0.element, color: colors[$0.offset % colors.count])
        }
    }

    private var ruleHighlighting: [HighlightRule] {
        [
            HighlightRule(pattern: #"^\s*#.*$"#, styleIndex: 0, priority: 100),
            HighlightRule(pattern: #"^\s*(line|step|event)\b"#, styleIndex: 1, priority: 80),
            HighlightRule(pattern: #"\|\s*\d+\s*(?=\|)"#, styleIndex: 2, priority: 50),
            HighlightRule(pattern: #"\|\s*-\s*(?=\|)"#, styleIndex: 2, priority: 50),
            HighlightRule(pattern: #"\\[dDsSwW]|[\^$+*?]"#, styleIndex: 3, priority: 40),
        ]
    }

    private var ruleStyle: CodeStyle {
        CodeStyle(palette: [
            Color(r: 0.42, g: 0.55, b: 0.47),
            Color(r: 0.75, g: 0.58, b: 0.95),
            Color(r: 0.95, g: 0.72, b: 0.38),
            Color(r: 0.38, g: 0.72, b: 0.92),
        ])
    }

    public var body: some View {
        let parsed = result
        let traces = displayed
        VStack(flexGrow: 1) {
            header(parsed)
            Divider()
            HStack(flexGrow: 1, padding: 8) {
                VStack(width: .pt(440), padding: 6) {
                    sectionTitle("PARSING RULES", detail: "type | name | regex | time | value | group")
                    EditorView(
                        text: $rules,
                        rules: ruleHighlighting,
                        style: ruleStyle,
                        visibleLines: 13
                    )
                    .agentId("rules-editor")
                    Text("LOG INPUT", color: .secondary).padding(2)
                    EditorView(text: $log, visibleLines: 15)
                        .agentId("log-editor")
                }
                .background(Environment.current.theme.panel)
                .cornerRadius(7)

                VStack(flexGrow: 1, padding: 6) {
                    HStack {
                        sectionTitle("UNIFIED TIMELINE", detail: timelineDetail(traces))
                        Spacer()
                        Text("live parse", color: .muted)
                    }
                    timeline(traces)
                        .agentId("unified-timeline")
                    legend(traces)
                    diagnostics(parsed)
                }
            }
        }
    }

    private func header(_ parsed: TraceParseResult) -> some View {
        HStack(padding: 10) {
            VStack {
                Text("TRACELOOM", color: .accent)
                Text("Pattern-driven log timelines", color: .secondary)
            }
            Spacer()
            Text("\(parsed.series.count) rules", color: .secondary)
            Text("\(parsed.matchedLineCount) matched lines", color: .secondary)
            Text("\(parsed.series.reduce(0) { $0 + $1.points.count }) points", color: .selected)
        }
        .background(Environment.current.theme.panel)
    }

    private func sectionTitle(_ title: String, detail: String) -> some View {
        VStack {
            Text(title, color: .accent)
            Text(detail, color: .dim)
        }
        .padding(2)
    }

    private func timelineDetail(_ traces: [DisplaySeries]) -> String {
        let points = traces.flatMap(\.series.points)
        guard let lo = points.map(\.time).min(), let hi = points.map(\.time).max() else {
            return "waiting for matching log lines"
        }
        return "\(formatTime(lo)) — \(formatTime(hi)) · shared X axis"
    }

    private func timeline(_ traces: [DisplaySeries]) -> some View {
        let theme = Environment.current.theme
        let allPoints = traces.flatMap(\.series.points)
        let tMin = allPoints.map(\.time).min() ?? 0
        let rawMax = allPoints.map(\.time).max() ?? 1
        let tMax = rawMax > tMin ? rawMax : tMin + 1
        let groupedRanges = yRanges(traces)

        return Canvas(
            label: "UnifiedTimeline",
            height: .auto,
            flexGrow: 1,
            minHeight: 300
        ) { draw, frame in
            let left: Float = 116
            let right: Float = 18
            let top: Float = 16
            let bottom: Float = 30
            let plotW = max(1, frame.w - left - right)
            let lanes = max(1, traces.count)
            let laneH = max(42, (frame.h - top - bottom) / Float(lanes))
            let plotBottom = top + laneH * Float(lanes)

            draw.roundedRect(x: frame.x, y: frame.y, w: frame.w, h: frame.h, color: theme.canvas, radius: 6)
            for tick in 0...5 {
                let ratio = Float(tick) / 5
                let x = frame.x + left + ratio * plotW
                draw.line(x1: x, y1: frame.y + top, x2: x, y2: frame.y + min(plotBottom, frame.h - bottom), color: theme.border.opacity(0.55), width: 1)
                let value = tMin + Double(ratio) * (tMax - tMin)
                draw.text(formatTime(value), x: x - 29, y: frame.y + frame.h - bottom + 5, w: 70, h: 18, color: theme.textDim)
            }

            for item in traces {
                let lane = item.id
                let yTop = frame.y + top + Float(lane) * laneH
                let yBottom = min(frame.y + frame.h - bottom, yTop + laneH)
                draw.line(x1: frame.x + left, y1: yBottom, x2: frame.x + left + plotW, y2: yBottom, color: theme.border.opacity(0.65), width: 1)
                draw.text(item.series.rule.name, x: frame.x + 8, y: yTop + 8, w: left - 12, h: 18, color: item.color)
                let group = item.series.rule.scaleGroup ?? "@\(item.id)"
                let range = groupedRanges[group] ?? (0, 1)
                let ySpan = range.max > range.min ? range.max - range.min : 1
                func px(_ time: Double) -> Float {
                    frame.x + left + Float((time - tMin) / (tMax - tMin)) * plotW
                }
                func py(_ value: Double) -> Float {
                    yBottom - 7 - Float((value - range.min) / ySpan) * max(1, laneH - 18)
                }

                let points = item.series.points
                switch item.series.rule.kind {
                case .line:
                    for index in 1..<points.count {
                        draw.line(x1: px(points[index - 1].time), y1: py(points[index - 1].value), x2: px(points[index].time), y2: py(points[index].value), color: item.color, width: 2)
                    }
                    for point in points { draw.circle(cx: px(point.time), cy: py(point.value), radius: 2.5, color: item.color) }
                case .step:
                    for index in 1..<points.count {
                        let previous = points[index - 1]
                        let current = points[index]
                        draw.line(x1: px(previous.time), y1: py(previous.value), x2: px(current.time), y2: py(previous.value), color: item.color, width: 2)
                        draw.line(x1: px(current.time), y1: py(previous.value), x2: px(current.time), y2: py(current.value), color: item.color, width: 2)
                    }
                case .event:
                    for point in points {
                        let x = px(point.time)
                        draw.line(x1: x, y1: yTop + 7, x2: x, y2: yBottom - 7, color: item.color, width: 3)
                        draw.circle(cx: x, cy: yTop + 9, radius: 3.5, color: item.color)
                    }
                }
            }
        }
    }

    private func legend(_ traces: [DisplaySeries]) -> some View {
        HStack(padding: 4) {
            ForEach(traces) { item in
                Text("● \(item.series.rule.name) · \(item.series.rule.kind.rawValue) · \(item.series.points.count)", color: item.color)
                    .padding(3)
            }
        }
    }

    private func diagnostics(_ parsed: TraceParseResult) -> some View {
        VStack {
            if parsed.diagnostics.isEmpty {
                Text("Rules valid · edit either pane to reparse", color: .muted)
                    .agentId("parse-status")
            } else {
                ForEach(Array(parsed.diagnostics.prefix(3).enumerated()).map { Diagnostic(id: $0.offset, text: $0.element) }) { diagnostic in
                    Text(diagnostic.text, color: Color(r: 0.95, g: 0.48, b: 0.42))
                }
            }
        }
        .padding(5)
        .background(Environment.current.theme.inset)
        .cornerRadius(5)
    }

    private struct Diagnostic: Identifiable {
        let id: Int
        let text: String
    }

    private func yRanges(_ traces: [DisplaySeries]) -> [String: (min: Double, max: Double)] {
        var ranges: [String: (min: Double, max: Double)] = [:]
        for item in traces where item.series.rule.kind != .event {
            let key = item.series.rule.scaleGroup ?? "@\(item.id)"
            for point in item.series.points {
                if let old = ranges[key] {
                    ranges[key] = (min(old.min, point.value), max(old.max, point.value))
                } else {
                    ranges[key] = (point.value, point.value)
                }
            }
        }
        return ranges
    }

    private func formatTime(_ milliseconds: Double) -> String {
        let total = Int(milliseconds.rounded())
        let ms = abs(total % 1000)
        let seconds = abs(total / 1000) % 60
        let minutes = abs(total / 60_000) % 60
        let hours = abs(total / 3_600_000) % 24
        return String(format: "%02d:%02d:%02d.%03d", hours, minutes, seconds, ms)
    }

    private static let palette: [Color] = [
        Color(r: 0.30, g: 0.76, b: 0.96),
        Color(r: 0.95, g: 0.65, b: 0.28),
        Color(r: 0.92, g: 0.35, b: 0.48),
        Color(r: 0.42, g: 0.82, b: 0.56),
        Color(r: 0.72, g: 0.52, b: 0.96),
    ]

    private static let sampleRules = #"""
    # type | name | regex | time capture | value capture | shared scale
    line  | Inbound    | ^(\d\d:\d\d:\d\d\.\d+).*inboundKbps:(\d+)  | 1 | 2 | traffic
    line  | Outbound   | ^(\d\d:\d\d:\d\d\.\d+).*outboundKbps:(\d+) | 1 | 2 | traffic
    step  | Replicas   | ^(\d\d:\d\d:\d\d\.\d+).*replicas[=:](\d+)  | 1 | 2 | capacity
    event | Config     | ^(\d\d:\d\d:\d\d\.\d+).*CONFIG_RELOAD       | 1 | - |
    """#

    private static let sampleLog = """
    19:16:15.280 NetworkMetrics inboundKbps:8400 outboundKbps:3200
    19:16:16.140 ClusterScaler replicas=3
    19:16:17.010 NetworkMetrics inboundKbps:7900 outboundKbps:3500
    19:16:18.420 ClusterScaler replicas=5
    19:16:19.300 NetworkMetrics inboundKbps:4100 outboundKbps:2800
    19:16:20.492 ConfigService CONFIG_RELOAD completed
    19:16:21.050 NetworkMetrics inboundKbps:3800 outboundKbps:2600
    19:16:22.900 NetworkMetrics inboundKbps:6100 outboundKbps:3900
    19:16:24.200 ClusterScaler replicas=4
    19:16:25.100 NetworkMetrics inboundKbps:7200 outboundKbps:4300
    """
}
