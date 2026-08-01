import Foundation
import LavaUI
import TraceLoomCore

private struct DisplaySeries: Identifiable {
    let id: Int
    let series: TraceSeries
    let pyramid: TracePyramid
    let color: Color
}

private final class TraceDataCache {
    private var rules = ""
    private var log = ""
    private var result: TraceParseResult?
    private var pyramids: [TracePyramid] = []

    func resolve(log newLog: String, rules newRules: String) -> (TraceParseResult, [TracePyramid]) {
        if result == nil || newLog != log || newRules != rules {
            log = newLog
            rules = newRules
            let parsed = TraceParser.parse(log: newLog, rulesSource: newRules)
            result = parsed
            pyramids = parsed.series.map { TracePyramid(points: $0.points) }
        }
        return (result!, pyramids)
    }
}

public struct TraceLoom: View {
    @State private var rules = TraceLoom.sampleRules
    @State private var log = TraceLoom.sampleLog
    /// Pointer position inside the timeline canvas while a gesture is live —
    /// nil once released. Local coordinates only; `timeline(_:)` maps back
    /// to a time value using the same axis it drew.
    @DrawState private var cursorLocalX: Float?
    /// Active drag selection in canvas-local coordinates. The selected time
    /// range is committed only when the pointer is released.
    @DrawState private var dragStartLocalX: Float?
    @DrawState private var dragCurrentLocalX: Float?
    /// User-selected timeline domain. Nil means fit all parsed data.
    @State private var zoomStart: Double?
    @State private var zoomEnd: Double?
    @State private var showLog = false
    /// Parsing and pyramid construction are tied to source edits, not cursor
    /// motion or other view-state changes that recompute this body.
    @State private var dataCache = TraceDataCache()
    /// Set by tapping a decorated gutter row — `EditorView` has no built-in
    /// tooltip, it just tells the app which decoration was tapped.
    @State private var tappedDiagnostic: String?

    public init() {}

    private var result: TraceParseResult {
        dataCache.resolve(log: log, rules: rules).0
    }

    /// `TraceParser` reports diagnostics as prefixed strings ("Rule 3: …",
    /// "Log 5, Inbound: …") rather than a structured line/range — parsing the
    /// prefix back out here, instead of widening `TraceParseResult`'s public
    /// shape, keeps this a presentation concern local to the one thing that
    /// wants ranges.
    private func lineRange(in text: String, line: Int) -> Range<Int>? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard line >= 1, line <= lines.count else { return nil }
        var offset = 0
        for i in 0..<(line - 1) { offset += lines[i].count + 1 }
        return offset..<(offset + max(1, lines[line - 1].count))
    }

    private func decorations(prefix: String, severity: DiagnosticSeverity, in text: String) -> [EditorDecoration] {
        result.diagnostics.compactMap { message in
            guard message.hasPrefix(prefix) else { return nil }
            let digits = message.dropFirst(prefix.count).prefix { $0.isNumber }
            guard let line = Int(digits), let range = lineRange(in: text, line: line) else { return nil }
            return EditorDecoration(range: range, severity: severity, message: message)
        }
    }

    private func loadLogFile() {
        guard let url = FileDialog.openFile(
            title: "Open Log File",
            filters: [FileDialog.Filter(name: "Log/text files", extensions: ["log", "txt"])]
        ) else { return }
        loadLog(from: [url])
    }

    /// Shared by the file-dialog button and `.onDrop` — whichever way a log
    /// file arrives, only its content matters. Ignores anything past the
    /// first path: TraceLoom parses one buffer, not a multi-file batch.
    private func loadLog(from urls: [URL]) {
        guard let url = urls.first, let contents = try? String(contentsOf: url, encoding: .utf8) else { return }
        log = contents
    }

    private var displayed: [DisplaySeries] {
        let colors = TraceLoom.palette
        let resolved = dataCache.resolve(log: log, rules: rules)
        return resolved.0.series.enumerated().map {
            DisplaySeries(
                id: $0.offset, series: $0.element,
                pyramid: resolved.1[$0.offset],
                color: colors[$0.offset % colors.count]
            )
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
            VStack(padding: 6) {
                sectionTitle("PARSING RULES", detail: "type | name | regex | time | value | group")
                EditorView(
                    text: $rules,
                    rules: ruleHighlighting,
                    style: ruleStyle,
                    visibleLines: 20,
                    decorations: decorations(prefix: "Rule ", severity: .error, in: rules),
                    onDecorationTap: { tappedDiagnostic = $0.message }
                )
                .agentId("rules-editor")
                if let tappedDiagnostic {
                    Text("⚑ \(tappedDiagnostic)", color: .selected)
                        .agentId("tapped-diagnostic")
                }
            }
            .background(Environment.current.theme.panel)
            .cornerRadius(7)

            Divider()
            VStack(flexGrow: 1, padding: 6) {
                HStack(alignment: .center) {
                    sectionTitle("UNIFIED TIMELINE", detail: timelineDetail(traces))
                    Spacer()
                    if zoomStart != nil {
                        Text("Reset zoom", color: .accent, onClick: { resetZoom() })
                            .padding(4)
                            .hoverBackground(Environment.current.theme.hover)
                            .cornerRadius(4)
                            .agentId("reset-zoom")
                    }
                    Text("live parse", color: .muted)
                }
                timeline(traces)
                    .agentId("unified-timeline")
                legend(traces)
                diagnostics(parsed)
            }
            Expand("Log input · \(logLineCount) lines", isExpanded: $showLog) {
                VStack {
                    EditorView(
                        text: $log,
                        visibleLines: 8,
                        decorations: decorations(prefix: "Log ", severity: .warning, in: log),
                        onDecorationTap: { tappedDiagnostic = $0.message }
                    )
                    .agentId("log-editor")
                }
            }
            .padding(8)
            .agentId("log-disclosure")
        }
        .onDrop { urls in loadLog(from: urls) }
    }

    private var logLineCount: Int {
        log.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    private func resetZoom() {
        zoomStart = nil
        zoomEnd = nil
        dragStartLocalX = nil
        dragCurrentLocalX = nil
        cursorLocalX = nil
    }

    private func header(_ parsed: TraceParseResult) -> some View {
        HStack(padding: 10) {
            HStack() {
                Text("\(parsed.series.count) rules", color: .secondary)
                Text("\(parsed.matchedLineCount) matched lines", color: .secondary)
                Text("\(parsed.series.reduce(0) { $0 + $1.points.count }) points", color: .selected)
            }

            Spacer()

            HStack() {
                Text("Paste, edit, drop a file here, or", color: .dim)
                Text("Load file…", color: .accent, onClick: { loadLogFile() })
                    .agentId("load-log-file")
            }
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
        let lo = traces.compactMap { $0.series.points.first?.time }.min()
        let hi = traces.compactMap { $0.series.points.last?.time }.max()
        guard let lo, let hi else {
            return "waiting for matching log lines"
        }
        if let zoomStart, let zoomEnd {
            return "\(formatTime(zoomStart)) — \(formatTime(zoomEnd)) · zoomed"
        }
        return "\(formatTime(lo)) — \(formatTime(hi)) · shared X axis"
    }

    private func timeline(_ traces: [DisplaySeries]) -> some View {
        let theme = Environment.current.theme
        let fullMin = traces.compactMap { $0.series.points.first?.time }.min() ?? 0
        let rawFullMax = traces.compactMap { $0.series.points.last?.time }.max() ?? 1
        let fullMax = rawFullMax > fullMin ? rawFullMax : fullMin + 1
        let requestedMin = zoomStart ?? fullMin
        let requestedMax = zoomEnd ?? fullMax
        let clampedMin = max(fullMin, min(requestedMin, fullMax))
        let clampedMax = min(fullMax, max(requestedMax, fullMin))
        let hasValidZoom = clampedMax > clampedMin
        let tMin = hasValidZoom ? clampedMin : fullMin
        let tMax = hasValidZoom ? clampedMax : fullMax
        let groupedRanges = yRanges(traces)
        let plotLeft: Float = 116
        let plotRight: Float = 18

        return Canvas(
            label: "UnifiedTimeline",
            height: .auto,
            flexGrow: 1,
            minHeight: 300,
            onGesture: { gesture in
                switch gesture.phase {
                case .began:
                    let x = max(plotLeft, gesture.localX)
                    dragStartLocalX = x
                    dragCurrentLocalX = x
                    cursorLocalX = x
                case .moved:
                    let x = max(plotLeft, gesture.localX)
                    dragCurrentLocalX = x
                    cursorLocalX = x
                case .ended:
                    let end = max(plotLeft, gesture.localX)
                    if let start = dragStartLocalX {
                        let plotWidth = max(1, gesture.frame.w - plotLeft - plotRight)
                        let a = min(max(plotLeft, start), gesture.frame.w - plotRight)
                        let b = min(max(plotLeft, end), gesture.frame.w - plotRight)
                        // Treat a tiny movement as inspection rather than a
                        // destructive near-zero zoom.
                        if abs(b - a) >= 4 {
                            let ra = Double((a - plotLeft) / plotWidth)
                            let rb = Double((b - plotLeft) / plotWidth)
                            let selectedA = tMin + ra * (tMax - tMin)
                            let selectedB = tMin + rb * (tMax - tMin)
                            zoomStart = min(selectedA, selectedB)
                            zoomEnd = max(selectedA, selectedB)
                        }
                    }
                    dragStartLocalX = nil
                    dragCurrentLocalX = nil
                    cursorLocalX = nil
                }
            }
        ) { draw, frame in
            let left = plotLeft
            let right = plotRight
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

            draw.pushClip(
                x: frame.x + left, y: frame.y + top,
                w: plotW, h: min(plotBottom, frame.h - bottom) - top
            )
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

                switch item.series.rule.kind {
                case .line:
                    let visible = item.pyramid.sampled(
                        in: tMin...tMax,
                        targetBucketCount: max(1, Int(plotW.rounded(.down)))
                    )
                    draw.polyline(
                        visible.map { (x: px($0.time), y: py($0.value)) },
                        color: item.color
                    )
                    // Markers help sparse series but defeat the point of one
                    // draw for dense data, so stop emitting them once the line
                    // is visually continuous.
                    if visible.count <= 200 {
                        for point in visible {
                            draw.circle(cx: px(point.time), cy: py(point.value), radius: 2.5, color: item.color)
                        }
                    }
                case .step:
                    let visible = item.pyramid.sampled(
                        in: tMin...tMax,
                        targetBucketCount: max(1, Int(plotW.rounded(.down)))
                    )
                    var strip: [(x: Float, y: Float)] = []
                    if let first = visible.first {
                        strip.append((px(first.time), py(first.value)))
                    }
                    for index in visible.indices.dropFirst() {
                        let previous = visible[index - 1]
                        let current = visible[index]
                        strip.append((px(current.time), py(previous.value)))
                        strip.append((px(current.time), py(current.value)))
                    }
                    draw.polyline(strip, color: item.color)
                case .event:
                    let visible = item.pyramid.sampled(
                        in: tMin...tMax,
                        targetBucketCount: max(1, Int(plotW.rounded(.down)))
                    )
                    for point in visible {
                        let x = px(point.time)
                        draw.line(x1: x, y1: yTop + 7, x2: x, y2: yBottom - 7, color: item.color, width: 3)
                        draw.circle(cx: x, cy: yTop + 9, radius: 3.5, color: item.color)
                    }
                }
            }
            draw.popClip()

            // Range selection remains transient until button-up. Highlight the
            // entire chosen interval and give both boundaries a crisp edge.
            if let start = dragStartLocalX, let current = dragCurrentLocalX {
                let lo = min(max(left, start), frame.w - right)
                let hi = min(max(left, current), frame.w - right)
                let x0 = frame.x + min(lo, hi)
                let x1 = frame.x + max(lo, hi)
                draw.rect(
                    x: x0, y: frame.y + top,
                    w: max(1, x1 - x0), h: min(plotBottom, frame.h - bottom) - top,
                    color: theme.accent.opacity(0.16)
                )
                draw.line(x1: x0, y1: frame.y + top, x2: x0, y2: frame.y + min(plotBottom, frame.h - bottom), color: theme.accent, width: 2)
                draw.line(x1: x1, y1: frame.y + top, x2: x1, y2: frame.y + min(plotBottom, frame.h - bottom), color: theme.accent, width: 2)
            }

            // Synchronized inspection cursor — a crosshair at the pointer's
            // own x, with the time it maps to on the shared axis.
            if let cx = cursorLocalX, cx >= left, cx <= frame.w - right {
                let x = frame.x + cx
                draw.line(x1: x, y1: frame.y + top, x2: x, y2: frame.y + min(plotBottom, frame.h - bottom), color: theme.textSecondary.opacity(0.8), width: 1)
                let time = tMin + Double((cx - left) / plotW) * (tMax - tMin)
                let label = formatTime(time)
                let labelW: Float = 74
                let labelX = min(max(frame.x + left, x - labelW / 2), frame.x + frame.w - right - labelW)
                draw.roundedRect(x: labelX, y: frame.y + 2, w: labelW, h: 16, color: theme.panel, radius: 4)
                draw.text(label, x: labelX, y: frame.y + 3, w: labelW, h: 14, color: theme.textSecondary)
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
            guard let valueRange = item.pyramid.valueRange else { continue }
            if let old = ranges[key] {
                ranges[key] = (
                    min(old.min, valueRange.lowerBound),
                    max(old.max, valueRange.upperBound)
                )
            } else {
                ranges[key] = (valueRange.lowerBound, valueRange.upperBound)
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
