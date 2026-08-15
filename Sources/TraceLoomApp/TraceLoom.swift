import Foundation
import LavaUI
import TraceLoomCore

private struct DisplaySeries: Identifiable {
    let id: Int
    let series: TraceSeries
    let pyramid: TracePyramid
    let color: Color
}

private struct ParseInput: Equatable, Sendable {
    var log: String
    var rules: String
}

private struct ParseOutput: Sendable {
    var result: TraceParseResult
    var pyramids: [TracePyramid]
    /// Counted here rather than in the view. `log.split(...).count` on the
    /// string itself is ~2s at 57 MB, and the disclosure title that wanted it
    /// ran on every body — which would have kept the main thread blocked for
    /// exactly as long as parsing used to, defeating the point of moving the
    /// parse off it.
    var logLineCount: Int

    static let empty = ParseOutput(
        result: TraceParseResult(series: [], diagnostics: [], matchedLineCount: 0),
        pyramids: [],
        logLineCount: 0
    )
}

/// Whether a worker's parse is still wanted. One flag per dispatched parse;
/// superseding one means cancelling its flag and making a new one.
private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func isLive() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !cancelled
    }
}

/// Parse results for the current log and rules, computed off the main thread
/// when that is worth doing.
///
/// Stale-while-revalidating: `resolve` always returns something renderable
/// immediately — the previous parse while a new one runs — because it is
/// called from `body`, and a body that blocks is a frame that never ships.
/// The old version parsed inline there, which is why editing one character of
/// a rule froze the window for as long as a whole reparse took.
///
/// Every field is main-thread-only. The single cross-thread hop is the
/// `MainQueue.async` closure a worker posts on completion, and that runs on
/// the main thread like everything else here — hence `@unchecked Sendable`,
/// the same bargain `AgentServer` and `Editor` make.
private final class TraceDataCache: @unchecked Sendable {
    /// Under this, parsing inline beats a thread hop: it costs well under a
    /// frame, and going async would blank the timeline for one frame on every
    /// edit — including for the built-in sample log, which would flash on the
    /// very first frame.
    private static let syncByteLimit = 256 * 1024

    /// Parsed documents, most recently used first.
    ///
    /// Keyed per document, not per session: switching tabs is supposed to be a
    /// return, and a single-slot cache would make every switch a reparse — for
    /// a 12 MB log, seconds of stale timeline each way. The cap is what keeps
    /// that from being a memory leak with a nice name; four is enough for the
    /// pair or trio anyone actually flips between, and the fifth reparses.
    private static let cacheLimit = 4

    private var entries: [(id: Int, input: ParseInput, output: ParseOutput)] = []
    private var inFlight: ParseInput?
    private var activeCancel: CancelFlag?
    /// Bumped per request. A worker's result is dropped unless its stamp is
    /// still the newest, so a slow parse finishing after a faster later one
    /// cannot overwrite it.
    private var generation: UInt64 = 0

    /// True while a worker is running — the view shows this rather than
    /// pretending the displayed data is current.
    var isParsing: Bool { inFlight != nil }

    func resolve(document: Int, log: String, rules: String) -> ParseOutput {
        let input = ParseInput(log: log, rules: rules)
        if let hit = entries.firstIndex(where: { $0.id == document && $0.input == input }) {
            touch(hit)
            return entries[0].output
        }

        if input.log.utf8.count <= Self.syncByteLimit {
            supersedeInFlight()
            let output = Self.compute(input, shouldContinue: nil)!
            store(document, input, output)
            return output
        }

        if inFlight != input { start(document, input) }
        // This document's *previous* parse keeps rendering — never another
        // document's, which would put someone else's timeline under this log's
        // name. Only a first-ever parse of a large log has nothing to show,
        // and the view marks that as pending.
        return entries.first(where: { $0.id == document })?.output ?? .empty
    }

    /// Drops what belongs to documents that are no longer open, so a closed
    /// tab's points and pyramids go with it rather than waiting to be evicted
    /// by four unrelated parses.
    func forget(except live: Set<Int>) {
        entries.removeAll { !live.contains($0.id) }
    }

    private func store(_ id: Int, _ input: ParseInput, _ output: ParseOutput) {
        entries.removeAll { $0.id == id }
        entries.insert((id, input, output), at: 0)
        if entries.count > Self.cacheLimit { entries.removeLast(entries.count - Self.cacheLimit) }
    }

    private func touch(_ index: Int) {
        guard index != 0 else { return }
        let entry = entries.remove(at: index)
        entries.insert(entry, at: 0)
    }

    private func start(_ document: Int, _ input: ParseInput) {
        supersedeInFlight()
        let flag = CancelFlag()
        activeCancel = flag
        inFlight = input
        let stamp = generation
        Thread.detachNewThread { [self] in
            guard let output = Self.compute(input, shouldContinue: flag.isLive) else { return }
            MainQueue.async {
                self.commit(stamp: stamp, document: document, input: input, output: output)
            }
        }
    }

    /// Invalidates whatever is running: its flag stops it at the next check,
    /// and the generation bump makes its result unwelcome even if it finishes
    /// between the two.
    private func supersedeInFlight() {
        activeCancel?.cancel()
        activeCancel = nil
        inFlight = nil
        generation &+= 1
    }

    private func commit(
        stamp: UInt64, document: Int, input: ParseInput, output: ParseOutput
    ) {
        guard stamp == generation else { return }
        store(document, input, output)
        inFlight = nil
        activeCancel = nil
        // A plain class, so nothing observed this change — the frame that
        // shows it has to be asked for explicitly.
        ViewInvalidation.markNeedsBody()
    }

    /// `shouldContinue` is `@Sendable` because the parse now polls it from
    /// several chunk threads at once. `CancelFlag` is lock-protected, which is
    /// what makes that safe.
    private static func compute(
        _ input: ParseInput, shouldContinue: (@Sendable () -> Bool)?
    ) -> ParseOutput? {
        guard let result = TraceParser.parse(
            log: input.log, rulesSource: input.rules, shouldContinue: shouldContinue
        ) else { return nil }
        // Pyramid building is not itself cancellable, but it is ~2% of a
        // parse; checking once on the way out is enough to drop a result that
        // went stale during it.
        guard shouldContinue?() ?? true else { return nil }
        return ParseOutput(
            result: result,
            pyramids: result.series.map { TracePyramid(points: $0.points) },
            logLineCount: input.log.utf8.reduce(1) { $1 == 0x0A ? $0 + 1 : $0 }
        )
    }
}

public struct TraceLoom: View {
    /// Shared with `LavaHost.run(menu:)` — see `TraceLoomSession`. `@Bindable`
    /// so `$session.rules` projects a binding the way `$state` does.
    @Bindable var session: TraceLoomSession

    /// Pointer position inside the timeline canvas while a gesture is live —
    /// nil once released. Local coordinates only; `timeline(_:)` maps back
    /// to a time value using the same axis it drew.
    @DrawState private var cursorLocalX: Float?
    /// Timestamp retained after a click so inspection survives button-up.
    /// Time rather than local X keeps the probe stable across resizes.
    @DrawState private var probeTime: Double?
    /// Active drag selection in canvas-local coordinates. The selected time
    /// range is committed only when the pointer is released.
    @DrawState private var dragStartLocalX: Float?
    @DrawState private var dragCurrentLocalX: Float?
    /// Parsing and pyramid construction are tied to source edits, not cursor
    /// motion or other view-state changes that recompute this body.
    @State private var dataCache = TraceDataCache()
    /// Set by tapping a decorated gutter row — `EditorView` has no built-in
    /// tooltip, it just tells the app which decoration was tapped.
    @State private var tappedDiagnostic: String?
    /// Rule assistant: the log line the user wants parsed, and the run itself.
    @State private var assistantExample = ""
    @State private var showAssistant = false
    @State private var assistant = AssistantSession()
    @State private var showParseRules = false

    init(session: TraceLoomSession) {
        self.session = session
    }

    private var parseOutput: ParseOutput {
        dataCache.forget(except: Set(session.documents.map(\.id)))
        return dataCache.resolve(
            document: session.active.id, log: session.log, rules: session.rules
        )
    }

    private var result: TraceParseResult { parseOutput.result }

    /// Most gutter markers put on one editor.
    ///
    /// A rule whose capture group does not exist produces one diagnostic per
    /// matching line — ~126,000 on a 12 MB log. Nothing downstream has any use
    /// for that many: the reader scrolls past the first few, and building the
    /// array at all costs more than reading it ever saves.
    private static let maxDecorations = 500

    /// `TraceParser` reports diagnostics as prefixed strings ("Rule 3: …",
    /// "Log 5, Inbound: …") rather than a structured line/range — parsing the
    /// prefix back out here, instead of widening `TraceParseResult`'s public
    /// shape, keeps this a presentation concern local to the one thing that
    /// wants ranges.
    private func decorations(
        prefix: String, severity: DiagnosticSeverity, in text: String
    ) -> [EditorDecoration] {
        // Lazily filtered, so a run of 126,000 diagnostics stops being scanned
        // once the cap is met rather than being walked in full.
        let matching = Array(
            result.diagnostics.lazy
                .filter { $0.hasPrefix(prefix) }
                .prefix(Self.maxDecorations)
        )
        let numbered = matching.compactMap { message -> (line: Int, message: String)? in
            let digits = message.dropFirst(prefix.count).prefix { $0.isNumber }
            guard let line = Int(digits) else { return nil }
            return (line, message)
        }
        guard let deepest = numbered.map(\.line).max() else { return [] }

        // One shared pass, bounded by the deepest line anything asks about.
        // This used to be a `lineRange(in:line:)` call per diagnostic, each of
        // which re-split the whole text and re-summed the prefix — O(diagnostics
        // x text). With the numbers above that is ~126,000 full splits of 12 MB
        // per body evaluation, and the window stopped responding outright.
        let index = LineIndex(text, upTo: deepest)
        return numbered.compactMap { entry in
            guard let range = index.range(ofLine: entry.line) else { return nil }
            return EditorDecoration(range: range, severity: severity, message: entry.message)
        }
    }

    private var displayed: [DisplaySeries] {
        let colors = TraceLoom.palette
        let resolved = parseOutput
        return resolved.result.series.enumerated().map {
            DisplaySeries(
                id: $0.offset, series: $0.element,
                pyramid: resolved.pyramids[$0.offset],
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

            // The log is the pane people want more of, and how much more
            // depends on the log — so it is dragged, not fixed. The header
            // stays out of the split: it is chrome, not a pane.
            VSplitView(
                fraction: $session.timelineSplit, minTop: 200, minBottom: 90
            ) {
                HStack(alignment: .center) {
                    sectionTitle("UNIFIED TIMELINE", detail: timelineDetail(traces))
                    Spacer()
                    layoutPicker
                }

                timeline(traces)
                .agentId("unified-timeline")

                legend(traces)
            } bottom: {
                EditorView(
                   text: $session.log,
                   visibleLines: 8,
                   decorations: decorations(
                       prefix: "Log ", severity: .warning, in: session.log
                   ),
                   onDecorationTap: { tappedDiagnostic = $0.message },
                   controller: session.logEditor
                )
                // Fills whatever the divider leaves it; `visibleLines` is only
                // what it would measure to on its own.
                .flexGrow(1)
                .agentId("log-editor")
            }
        }
        .onDrop { urls in session.loadLog(from: urls) }
        .overlay(
            isPresented: $session.showSettings,
            placement: .viewport(inset: 48),
            style: OverlayStyle(
                background: Environment.current.theme.panel.opacity(0.94),
                cornerRadius: 12,
                padding: 16,
                minWidth: 320,
                backdropBlurRadius: 10
            )
        ) {
            settingsPanel
        }
    }

    private var logLineCount: Int { parseOutput.logLineCount }

    private func resetZoom() {
        session.resetZoom()
        dragStartLocalX = nil
        dragCurrentLocalX = nil
        cursorLocalX = nil
    }

    private func header(_ parsed: TraceParseResult) -> some View {
        VStack {
            HStack(padding: 10) {
                if WindowBridge.drawsOwnChrome {
                    WindowControls()
                        .padding(.trailing, 6)
                        .windowChrome()
                }
                documentSwitcher

                HStack() {
                    Text("\(parsed.series.count) rules", color: .secondary)
                    Text("\(parsed.matchedLineCount) matched lines", color: .secondary)
                    Text("\(parsed.series.reduce(0) { $0 + $1.points.count }) points", color: .selected)
                }

                Spacer()

                Button("Open parsing rules") { showParseRules.toggle() }
                    .padding(0)
                    .overlay(
                        isPresented: $showParseRules,
                        placement: .viewport(inset: 48),
                        style: OverlayStyle(
                            background: Theme.current.background.opacity(0.93),
                        )
                    ) {
                        VStack() {
                            sectionTitle("PARSING RULES", detail: "type | name | regex | time | value | group")
                            EditorView(
                                text: $session.rules,
                                rules: ruleHighlighting,
                                style: ruleStyle,
                                visibleLines: 14,
                                decorations: decorations(
                                    prefix: "Rule ", severity: .error, in: session.rules
                                ),
                                onDecorationTap: { tappedDiagnostic = $0.message }
                            )
                            .agentId("rules-editor")
                            .background(Theme.current.background.opacity(0.70))

                            assistantPanel()
                            Spacer()
                            diagnostics(parsed)
                        }
                        .flexGrow(1)
                    }
                Spacer()
                if session.zoomStart != nil {
                    Text("Reset zoom", color: .accent, onClick: { resetZoom() })
                        .padding(4)
                        .hoverBackground(Environment.current.theme.hover)
                        .cornerRadius(4)
                        .agentId("reset-zoom")
                }
                Text("live parse", color: .muted)

                HStack() {
                    Text("Paste, edit, drop a file here, or", color: .dim)
                    Text("Load file…", color: .accent, onClick: { session.openLogFile() })
                        .agentId("load-log-file")
                    Text("Settings", color: .muted, onClick: { session.openSettings() })
                        .agentId("open-settings")
                }
            }
            loadStatus()
        }
        .background(Environment.current.theme.panel)
    }

    /// Which log is in front, and the workspace it came from.
    ///
    /// A combo box rather than a row of tabs: the log names are file names,
    /// which are long and similar, and twenty of them across the top would
    /// leave nothing for the header to say. The closed field is one line and
    /// the list carries each log's directory, which is usually the only thing
    /// that tells two `app.log`s apart.
    private var documentSwitcher: some View {
        HStack(alignment: .center, spacing: 6) {
            ComboBox(
                selection: Binding(
                    get: { session.activeIndex },
                    set: { switchTo($0) }
                ),
                items: session.documents.enumerated().map { index, document in
                    ComboBoxItem(document.name, tag: index, detail: document.detail)
                },
                width: .pt(230),
                maxVisibleRows: 12
            )
            .agentId("document-switcher")

            Text("×", color: .muted, onClick: { closeDocument() })
                .padding(4)
                .hoverBackground(Environment.current.theme.hover)
                .cornerRadius(4)
                .cursor(.pointer)
                .agentId("close-document")

            Text(
                session.workspaceName.map { "workspace · \($0)" } ?? "no workspace",
                color: .dim
            )
            .agentId("workspace-name")
        }
    }

    /// Switching documents is a session action, plus forgetting the pointer
    /// state this view is holding: `probeTime` is a timestamp in the log being
    /// left, and in the next one it would mark a moment that log never had.
    private func switchTo(_ index: Int) {
        guard index != session.activeIndex else { return }
        session.activate(index)
        clearTimelineGesture()
    }

    private func closeDocument() {
        session.closeActiveDocument()
        clearTimelineGesture()
    }

    private func clearTimelineGesture() {
        probeTime = nil
        cursorLocalX = nil
        dragStartLocalX = nil
        dragCurrentLocalX = nil
    }

    /// One line under the header for whichever of the two states is live.
    /// Deliberately not a transient toast: a load that failed should still be
    /// readable a minute later, when the user finally looks away from the
    /// timeline that did not change.
    @ViewBuilder
    private func loadStatus() -> some View {
        if let loadingPath = session.loadingPath {
            Text(
                "Loading \(URL(fileURLWithPath: loadingPath).lastPathComponent)…",
                color: .accent
            )
            .padding(6)
            .agentId("load-status")
        } else if dataCache.isParsing {
            // Says so rather than letting the previous timeline pass for
            // current — the whole point of rendering stale data is that the
            // user knows it is stale.
            Text("Parsing on a background thread…", color: .accent)
                .padding(6)
                .agentId("parse-progress")
        } else if let notice = session.notice {
            // ASCII prefixes on purpose: the symbol font has no warning sign,
            // and a tofu box is worse than no marker at all.
            Text(
                (notice.isError ? "Load failed · " : "Note · ") + notice.text,
                color: notice.isError ? .selected : .muted
            )
            .padding(6)
            .agentId("load-notice")
        }
    }

    private var settingsPanel: some View {
        VStack(padding: 4) {
            Text("Settings", color: .accent)
            Divider()
            Toggle(
                "Light theme",
                isOn: Binding(
                    get: { Theme.current == .light },
                    set: { Theme.current = $0 ? .light : .dark }
                )
            )
            .agentId("settings-theme")
            Divider()
            HStack {
                Spacer()
                Text("Close", color: .accent, onClick: { session.showSettings = false })
                    .padding(6)
                    .hoverBackground(Environment.current.theme.hover)
                    .cornerRadius(4)
                    .agentId("settings-close")
            }
        }
        .agentId("settings-panel")
    }

    // MARK: - Rule assistant

    private func assistantPanel() -> some View {
        let state = assistant.snapshot
        return VStack(padding: 6) {
            HStack(alignment: .center) {
                Text("RULE ASSISTANT", color: .accent)
                Text(assistant.model, color: .dim)
            }
            Divider()
            Text(
                "Paste a log line you want charted. The assistant writes a rule, "
                + "tests it against your log, and fixes it until it works.",
                color: .secondary
            )
            TextField(
                text: $assistantExample,
                placeholder: "e.g. 19:16:15.280 NetworkMetrics inboundKbps:8400"
            )
            .agentId("assistant-example")

            HStack(padding: 4) {
                Text(
                    state.isRunning ? "Working…" : "Suggest rule",
                    color: state.isRunning ? .dim : .accent,
                    onClick: { startAssistant() }
                )
                .padding(4)
                .hoverBackground(Environment.current.theme.hover)
                .cornerRadius(4)
                .agentId("assistant-run")

                if !state.status.isEmpty {
                    Text(
                        state.isRunning
                            ? "\(state.status)  \(Int(state.elapsed))s"
                            : state.status,
                        color: .muted
                    )
                    .agentId("assistant-status")
                }
            }

            // Reasoning models are silent in `content` for a long time, so
            // the tail of the think is the only sign anything is happening.
            if state.isRunning, !state.thinkingTail.isEmpty {
                MarkdownView("> \(state.thinkingTail)")
                    .agentId("assistant-thinking")
            }

            ForEach(
                Array(state.activity.suffix(6).enumerated())
                    .map { Diagnostic(id: $0.offset, text: $0.element) }
            ) { entry in
                Text(entry.text, color: .secondary)
            }

            if let suggestion = state.suggestion {
                Text(suggestion, color: .accent)
                    .agentId("assistant-suggestion")
                HStack(padding: 4) {
                    Text("Add to rules", color: .accent, onClick: { acceptSuggestion() })
                        .padding(4)
                        .hoverBackground(Environment.current.theme.hover)
                        .cornerRadius(4)
                        .agentId("assistant-accept")
                    Text("Discard", color: .muted, onClick: { assistant.clearSuggestion() })
                        .padding(4)
                        .hoverBackground(Environment.current.theme.hover)
                        .cornerRadius(4)
                        .agentId("assistant-discard")
                }
            }
            if let problem = state.problem {
                MarkdownView(problem, style: MarkdownStyle(text: .selected))
                    .agentId("assistant-problem")
            }
        }
        .agentId("assistant-pane")
    }

    private func startAssistant() {
        guard !assistant.isRunning else { return }
        assistant.start(
            example: assistantExample.isEmpty ? firstLogLine() : assistantExample,
            sampleLines: sampleLogLines(),
            existingRules: session.rules
        )
    }

    private func acceptSuggestion() {
        guard let suggestion = assistant.snapshot.suggestion else { return }
        let rules = session.rules
        session.rules = rules.hasSuffix("\n") || rules.isEmpty
            ? rules + suggestion + "\n"
            : rules + "\n" + suggestion + "\n"
        assistant.clearSuggestion()
    }

    /// Cheap on purpose: `log.split(...)` over a 57 MB buffer is ~2s, and this
    /// runs on the main thread from a click. A bounded prefix is all the
    /// assistant needs — it caps the lines it checks against anyway.
    private func sampleLogLines(limit: Int = 30) -> [String] {
        session.log.prefix(20_000)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .prefix(limit)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func firstLogLine() -> String { sampleLogLines(limit: 1).first ?? "" }

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
        let mode = session.timelineLayout == .overlay ? "overlay" : "lanes"
        guard let lo, let hi else {
            return "waiting for matching log lines"
        }
        if let zoomStart = session.zoomStart, let zoomEnd = session.zoomEnd {
            return "\(formatTime(zoomStart)) — \(formatTime(zoomEnd)) · zoomed · \(mode)"
        }
        return "\(formatTime(lo)) — \(formatTime(hi)) · \(mode)"
    }

    private var layoutPicker: some View {
        HStack(padding: 2) {
            layoutChoice("Lanes", .lanes)
            layoutChoice("Overlay", .overlay)
        }
        .agentId("timeline-layout")
    }

    private func layoutChoice(_ title: String, _ layout: TimelineLayout) -> some View {
        let selected = session.timelineLayout == layout
        return Text(
            title,
            color: selected ? .accent : .muted,
            onClick: { session.timelineLayout = layout }
        )
        .padding(4)
        .background(selected ? Environment.current.theme.hover : .clear)
        .hoverBackground(Environment.current.theme.hover)
        .cornerRadius(4)
        .agentId("timeline-layout-\(layout.rawValue)")
    }

    private func timeline(_ traces: [DisplaySeries]) -> some View {
        let theme = Environment.current.theme
        let fullMin = traces.compactMap { $0.series.points.first?.time }.min() ?? 0
        let rawFullMax = traces.compactMap { $0.series.points.last?.time }.max() ?? 1
        let fullMax = rawFullMax > fullMin ? rawFullMax : fullMin + 1
        let requestedMin = session.zoomStart ?? fullMin
        let requestedMax = session.zoomEnd ?? fullMax
        let clampedMin = max(fullMin, min(requestedMin, fullMax))
        let clampedMax = min(fullMax, max(requestedMax, fullMin))
        let hasValidZoom = clampedMax > clampedMin
        let tMin = hasValidZoom ? clampedMin : fullMin
        let tMax = hasValidZoom ? clampedMax : fullMax
        let groupedRanges = yRanges(traces, in: tMin...tMax)
        let plotLeft: Float = 18
        let plotRight: Float = 18
        let overlay = session.timelineLayout == .overlay

        return Canvas(
            label: "UnifiedTimeline",
            height: .auto,
            flexGrow: 1,
            // Low enough that the split can actually be dragged: a floor the
            // pane cannot honour is not a floor, it is content hanging out of
            // a clipped box.
            minHeight: 120,
            onGesture: { gesture in
                switch gesture.phase {
                case .began:
                    let x = min(max(plotLeft, gesture.localX), gesture.frame.w - plotRight)
                    dragStartLocalX = x
                    dragCurrentLocalX = x
                    cursorLocalX = x
                case .moved:
                    let x = min(max(plotLeft, gesture.localX), gesture.frame.w - plotRight)
                    dragCurrentLocalX = x
                    cursorLocalX = x
                case .ended:
                    let end = min(max(plotLeft, gesture.localX), gesture.frame.w - plotRight)
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
                            session.zoomStart = min(selectedA, selectedB)
                            session.zoomEnd = max(selectedA, selectedB)
                            probeTime = nil
                        } else {
                            let ratio = Double((b - plotLeft) / plotWidth)
                            let selectedTime = tMin + ratio * (tMax - tMin)
                            if let point = hitTestPoint(
                                traces: traces,
                                ranges: groupedRanges,
                                time: selectedTime,
                                localX: b,
                                localY: gesture.localY,
                                frame: gesture.frame,
                                tMin: tMin,
                                tMax: tMax,
                                plotLeft: plotLeft,
                                plotRight: plotRight,
                                overlay: overlay
                            ) {
                                probeTime = point.time
                                if let line = point.sourceLine {
                                    session.logEditor.reveal(line: line)
                                }
                            } else {
                                probeTime = selectedTime
                            }
                        }
                    }
                    dragStartLocalX = nil
                    dragCurrentLocalX = nil
                    cursorLocalX = nil
                }
            }
        ) { draw, frame in
            let plot = TimelinePlot.make(
                overlay: overlay,
                width: frame.w,
                height: frame.h,
                plotLeft: plotLeft,
                plotRight: plotRight,
                laneCount: traces.count
            )
            let left = plot.left
            let right = plot.right
            let top = plot.top
            let bottom = plot.bottom
            let plotW = plot.plotW
            let plotBottom = plot.plotBottom
            let activeProbeTime: Double? = {
                if let cx = cursorLocalX, cx >= left, cx <= frame.w - right {
                    return tMin + Double((cx - left) / plotW) * (tMax - tMin)
                }
                return probeTime
            }()

            draw.roundedRect(x: frame.x, y: frame.y, w: frame.w, h: frame.h, color: theme.canvas, radius: 6)
            for tick in 0...5 {
                let ratio = Float(tick) / 5
                let x = frame.x + left + ratio * plotW
                draw.line(x1: x, y1: frame.y + top, x2: x, y2: frame.y + min(plotBottom, frame.h - bottom), color: theme.border.opacity(0.55), width: 1)
                let value = tMin + Double(ratio) * (tMax - tMin)
                draw.text(formatTime(value), x: x - 29, y: frame.y + frame.h - bottom + 5, w: 70, h: 18, color: theme.textDim)
            }

            if overlay {
                draw.line(
                    x1: frame.x + left, y1: frame.y + plotBottom,
                    x2: frame.x + left + plotW, y2: frame.y + plotBottom,
                    color: theme.border.opacity(0.65), width: 1
                )
                // Colour key lives in the plot so the legend below is not the
                // only way to tell overlaid series apart.
                for item in traces {
                    draw.text(
                        item.series.rule.name,
                        x: frame.x + left + 6,
                        y: frame.y + top + 4 + Float(item.id) * 16,
                        w: 160, h: 16, color: item.color
                    )
                }
            }

            draw.pushClip(
                x: frame.x + left, y: frame.y + top,
                w: plotW, h: min(plotBottom, frame.h - bottom) - top
            )
            for item in traces {
                let band = plot.band(index: item.id, originY: frame.y)
                if !overlay {
                    draw.line(
                        x1: frame.x + left, y1: band.yBottom,
                        x2: frame.x + left + plotW, y2: band.yBottom,
                        color: theme.border.opacity(0.65), width: 1
                    )
                    draw.text(
                        item.series.rule.name,
                        x: frame.x + 8, y: band.yTop + 8,
                        w: 160, h: 18, color: item.color
                    )
                }
                let group = item.series.rule.scaleGroup ?? "@\(item.id)"
                let range = groupedRanges[group] ?? (0, 1)
                func px(_ time: Double) -> Float {
                    frame.x + left + Float((time - tMin) / (tMax - tMin)) * plotW
                }
                func py(_ value: Double) -> Float {
                    plotY(value, range: range, yBottom: band.yBottom, laneH: band.height)
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
                        draw.line(
                            x1: x, y1: band.yTop + 7,
                            x2: x, y2: band.yBottom - 7,
                            color: item.color, width: 3
                        )
                        draw.circle(cx: x, cy: band.yTop + 9, radius: 3.5, color: item.color)
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

            // Synchronized inspection cursor. It follows the pointer while
            // pressed and remains at the selected timestamp after a click.
            if let time = activeProbeTime, time >= tMin, time <= tMax {
                let x = frame.x + left + Float((time - tMin) / (tMax - tMin)) * plotW
                draw.line(x1: x, y1: frame.y + top, x2: x, y2: frame.y + min(plotBottom, frame.h - bottom), color: theme.textSecondary.opacity(0.8), width: 1)
                let label = formatTime(time)
                let labelW: Float = 74
                let labelX = min(max(frame.x + left, x - labelW / 2), frame.x + frame.w - right - labelW)
                draw.roundedRect(x: labelX, y: frame.y + 2, w: labelW, h: 16, color: theme.panel, radius: 4)
                draw.text(label, x: labelX, y: frame.y + 3, w: labelW, h: 14, color: theme.textSecondary)

                // Use the original series rather than the display pyramid:
                // downsampling must never change which value inspection finds.
                var overlayLabel = 0
                for item in traces {
                    guard let point = nearestPoint(in: item.series.points, to: time),
                          point.time >= tMin, point.time <= tMax
                    else { continue }
                    let band = plot.band(index: item.id, originY: frame.y)
                    let group = item.series.rule.scaleGroup ?? "@\(item.id)"
                    let range = groupedRanges[group] ?? (0, 1)
                    let pointX = frame.x + left
                        + Float((point.time - tMin) / (tMax - tMin)) * plotW
                    let pointY = plotY(
                        point.value, range: range,
                        yBottom: band.yBottom, laneH: band.height
                    )

                    // Two filled circles make a crisp outline without adding
                    // another shape primitive to LavaUI.
                    draw.circle(cx: pointX, cy: pointY, radius: 6, color: theme.textPrimary)
                    draw.circle(cx: pointX, cy: pointY, radius: 3.5, color: item.color)

                    let value = formatProbeValue(point.value)
                    let valueW: Float = 86
                    let preferRight = pointX + 8 + valueW <= frame.x + frame.w - right
                    let valueX = preferRight ? pointX + 8 : pointX - valueW - 8
                    // Overlay stacks labels so independently-scaled series do
                    // not write on top of each other at the same pixel.
                    let valueY: Float
                    if overlay {
                        valueY = frame.y + top + 20 + Float(overlayLabel) * 16
                        overlayLabel += 1
                    } else {
                        valueY = min(max(band.yTop + 2, pointY - 9), band.yBottom - 20)
                    }
                    draw.text(
                        value, x: valueX, y: valueY + 2, w: valueW, h: 14,
                        color: item.color
                    )
                }
            }
        }
    }

    /// O(log n) inspection on the full-resolution, time-sorted series.
    private func nearestPoint(in points: [TracePoint], to time: Double) -> TracePoint? {
        guard !points.isEmpty else { return nil }
        var low = 0
        var high = points.count
        while low < high {
            let mid = low + (high - low) / 2
            if points[mid].time < time {
                low = mid + 1
            } else {
                high = mid
            }
        }
        if low == 0 { return points[0] }
        if low == points.count { return points[points.count - 1] }
        let before = points[low - 1]
        let after = points[low]
        return time - before.time <= after.time - time ? before : after
    }

    private func formatProbeValue(_ value: Double) -> String {
        String(format: "%.6g", value)
    }

    /// Lanes: only the strip under the pointer. Overlay: nearest series in
    /// screen space, because every chart occupies the same rectangle.
    private func hitTestPoint(
        traces: [DisplaySeries],
        ranges: [String: (min: Double, max: Double)],
        time: Double,
        localX: Float,
        localY: Float,
        frame: CanvasFrame,
        tMin: Double,
        tMax: Double,
        plotLeft: Float,
        plotRight: Float,
        overlay: Bool
    ) -> TracePoint? {
        let plot = TimelinePlot.make(
            overlay: overlay,
            width: frame.w,
            height: frame.h,
            plotLeft: plotLeft,
            plotRight: plotRight,
            laneCount: traces.count
        )
        let candidates: [DisplaySeries]
        if overlay {
            candidates = traces
        } else {
            let lane = Int((localY - plot.top) / plot.laneH)
            guard lane >= 0, let item = traces.first(where: { $0.id == lane }) else {
                return nil
            }
            candidates = [item]
        }

        var best: (point: TracePoint, dist: Float)?
        for item in candidates {
            guard let point = nearestPoint(in: item.series.points, to: time),
                  point.time >= tMin, point.time <= tMax
            else { continue }
            let band = plot.band(index: item.id, originY: 0)
            let group = item.series.rule.scaleGroup ?? "@\(item.id)"
            let range = ranges[group] ?? (0, 1)
            let pointX = plot.left
                + Float((point.time - tMin) / (tMax - tMin)) * plot.plotW
            let dx = localX - pointX
            let dist: Float
            if item.series.rule.kind == .event {
                // Event markers are a full-height tick; X proximity is enough.
                guard abs(dx) <= 4,
                      localY >= plot.top, localY <= plot.plotBottom
                else { continue }
                dist = dx * dx
            } else {
                let pointY = plotY(
                    point.value, range: range,
                    yBottom: band.yBottom, laneH: band.height
                )
                let dy = localY - pointY
                dist = dx * dx + dy * dy
                guard dist <= 10 * 10 else { continue }
            }
            if best == nil || dist < best!.dist {
                best = (point, dist)
            }
        }
        return best?.point
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
                // Three of 126,000 looked exactly like three of three. The
                // count is also the tell that a rule is wrong for every line
                // rather than a few.
                if parsed.diagnostics.count > 3 {
                    Text(
                        "+\(parsed.diagnostics.count - 3) more"
                            + (parsed.diagnostics.count > Self.maxDecorations
                                ? " · first \(Self.maxDecorations) marked in the gutter"
                                : ""),
                        color: .muted
                    )
                    .agentId("diagnostic-overflow")
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

    /// Shared plot metrics so the canvas, the probe, and hit-testing cannot
    /// disagree about where a lane (or the single overlay rect) lives.
    private struct TimelinePlot {
        var overlay: Bool
        var left: Float
        var right: Float
        var top: Float
        var bottom: Float
        var plotW: Float
        var plotBottom: Float
        var laneH: Float

        static func make(
            overlay: Bool,
            width: Float,
            height: Float,
            plotLeft: Float,
            plotRight: Float,
            laneCount: Int
        ) -> TimelinePlot {
            let top: Float = 16
            let bottom: Float = 30
            let plotW = max(1, width - plotLeft - plotRight)
            let available = max(1, height - top - bottom)
            if overlay {
                return TimelinePlot(
                    overlay: true,
                    left: plotLeft,
                    right: plotRight,
                    top: top,
                    bottom: bottom,
                    plotW: plotW,
                    plotBottom: top + available,
                    laneH: available
                )
            }
            let lanes = max(1, laneCount)
            let laneH = max(42, available / Float(lanes))
            return TimelinePlot(
                overlay: false,
                left: plotLeft,
                right: plotRight,
                top: top,
                bottom: bottom,
                plotW: plotW,
                plotBottom: top + laneH * Float(lanes),
                laneH: laneH
            )
        }

        func band(index: Int, originY: Float) -> (yTop: Float, yBottom: Float, height: Float) {
            if overlay {
                let yTop = originY + top
                let yBottom = originY + plotBottom
                return (yTop, yBottom, yBottom - yTop)
            }
            let yTop = originY + top + Float(index) * laneH
            let yBottom = min(originY + plotBottom, yTop + laneH)
            return (yTop, yBottom, laneH)
        }
    }

    /// Map a series value into the lane so the visible min sits on the bottom
    /// padding and the visible max on the top. Subtract in Double first:
    /// values like unix-millis (1.7e12) are not Float-exact, but their delta is.
    private func plotY(
        _ value: Double,
        range: (min: Double, max: Double),
        yBottom: Float,
        laneH: Float
    ) -> Float {
        let plotH = max(1, laneH - 18)
        let span = range.max - range.min
        if span > 0 {
            return yBottom - 7 - Float((value - range.min) / span) * plotH
        }
        return yBottom - 7 - plotH * 0.5
    }

    /// Per-group Y extents for the *visible* X window, not the whole series.
    /// Otherwise a 3.7M delta around 1.7e12 (or any window next to a 0) draws
    /// as a flat line against the global min/max.
    private func yRanges(
        _ traces: [DisplaySeries],
        in timeRange: ClosedRange<Double>
    ) -> [String: (min: Double, max: Double)] {
        var ranges: [String: (min: Double, max: Double)] = [:]
        for item in traces where item.series.rule.kind != .event {
            let key = item.series.rule.scaleGroup ?? "@\(item.id)"
            guard let valueRange = item.pyramid.valueRange(in: timeRange) else { continue }
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

    /// Seed document for a fresh session / File → Reload Sample.
    static let sampleRules = #"""
    # type | name | regex | time capture | value capture | shared scale
    line  | Inbound    | ^(\d\d:\d\d:\d\d\.\d+).*inboundKbps:(\d+)  | 1 | 2 | traffic
    line  | Outbound   | ^(\d\d:\d\d:\d\d\.\d+).*outboundKbps:(\d+) | 1 | 2 | traffic
    step  | Replicas   | ^(\d\d:\d\d:\d\d\.\d+).*replicas[=:](\d+)  | 1 | 2 | capacity
    event | Config     | ^(\d\d:\d\d:\d\d\.\d+).*CONFIG_RELOAD       | 1 | - |
    """#

    static let sampleLog = """
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
