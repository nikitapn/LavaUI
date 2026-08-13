import Foundation
import LavaUI

// MARK: - Model

/// One row in the interactive list (ForEach + selection).
struct DemoItem: Hashable, Identifiable {
    let id: Int
    var title: String
    /// Index into `DemoPalette.swatches` for the flex chip color.
    var hue: Int
}

enum DemoPalette {
    static let swatches: [Color] = [
        Color(r: 0.55, g: 0.35, b: 0.70),
        Color(r: 0.25, g: 0.55, b: 0.75),
        Color(r: 0.30, g: 0.65, b: 0.45),
        Color(r: 0.80, g: 0.50, b: 0.25),
        Color(r: 0.70, g: 0.35, b: 0.40),
        Color(r: 0.40, g: 0.55, b: 0.65),
    ]

    static func color(at i: Int) -> Color {
        swatches[abs(i) % swatches.count]
    }
}

// MARK: - Demo root

/// Showcase for LavaUI: dynamic flex, stateful list, and every current widget.
///
/// Widgets exercised:
/// - `HStack` / `VStack` (fixed + `flexGrow`, padding)
/// - `Spacer`
/// - `Text` (colors, click, hover)
/// - `TextField` (`@Binding`)
/// - `Image`
/// - `ForEach` (keyed)
/// - `if` / `else` (Optional + Either via `ViewBuilder`)
/// - `DiagramHost` (flex center “canvas”)
/// - `@State` (list, selection, panels, theme, fields)
///
/// Not shown as a separate type: `EmptyView`, `TupleView`, `EitherView`,
/// `OptionalView` — they appear as fragments from the builder / conditionals.
public struct DemoExample: View {
    public var brandImage: UIImage?

    /// Shared with `LavaApp.run(menu:)` — see `DemoSession`. `@Bindable` so
    /// `$session.showSidebar` projects a binding the way `$state` does.
    @Bindable var session: DemoSession

    @State private var items: [DemoItem] = DemoExample.seedItems
    @State private var selectedId: Int? = 1
    @State private var draft: String = ""
    @State private var code: String = """
    // ST-ish sample for EditorView
    FUNCTION_BLOCK Motor
    VAR
      speed : REAL := 0.0;
      running : BOOL := FALSE;
    END_VAR

    IF speed > 10.0 THEN
      running := TRUE;
    ELSE
      running := FALSE;
    END_IF

    // A deliberately long line to exercise horizontal scrolling: shift+wheel moves the text while the gutter stays pinned in place.
    total := speed * 2.0 + offset * 3.0 - correction * 0.5 + trim;
    """
    @State private var findQuery: String = ""
    @State private var search = TextSearch()

    @State private var notes: String = "Multi-line with soft wrap. This sentence is long enough that it has to wrap onto several visual rows inside the panel.\nEnter still adds a hard line.\nUp/Down step visual rows."
    @State private var flexSlots = 3
    @State private var nextId = 10
    @State private var gauge: Float = 0.35
    @State private var showMenu = false
    @State private var showGlass = false
    /// Neon EQ showcase — continuous animation while true.
    @State private var pulsePlaying = true
    /// Selected donut wedge (`nil` = show title in the hole).
    @State private var pieSelected: Int? = 1
    /// Live telemetry overlay on the line chart (only while the lab is open).
    @State private var chartLive = true
    /// Expand disclosure for the live lab; collapsed so AnimationDriver is idle.
    @State private var showLiveLab = false
    @State private var status = "Click a list row, edit the field, resize the window."
    @State private var actionCount = 0

    private let posters: [UIImage]

    init(session: DemoSession, brandImage: UIImage? = nil, posters: [UIImage]) {
        self.session = session
        self.brandImage = brandImage
        self.posters = posters
    }

    private static let seedItems: [DemoItem] = [
        DemoItem(id: 1, title: "Alpha", hue: 0),
        DemoItem(id: 2, title: "Bravo", hue: 1),
        DemoItem(id: 3, title: "Charlie", hue: 2),
        DemoItem(id: 4, title: "Delta", hue: 3),
    ]

    /// Style indices are arbitrary but must match `codeStyle.palette`.
    private var stRules: [HighlightRule] {
        [
            HighlightRule(pattern: #"//[^\n]*"#, styleIndex: 0, priority: 100),
            HighlightRule(
                pattern: #"\b(IF|THEN|ELSE|END_IF|VAR|END_VAR|FUNCTION_BLOCK)\b"#,
                styleIndex: 1, priority: 50
            ),
            HighlightRule(pattern: #"\b(REAL|BOOL|INT)\b"#, styleIndex: 2, priority: 40),
            HighlightRule(pattern: #"\b(TRUE|FALSE)\b"#, styleIndex: 3, priority: 40),
            HighlightRule(pattern: #"\b\d+(\.\d+)?\b"#, styleIndex: 4, priority: 30),
        ]
    }

    private var codeStyle: CodeStyle {
        CodeStyle(palette: [
            Color(r: 0.45, g: 0.62, b: 0.45),   // comment
            Color(r: 0.78, g: 0.58, b: 0.95),   // keyword
            Color(r: 0.45, g: 0.75, b: 0.95),   // type
            Color(r: 0.95, g: 0.62, b: 0.45),   // literal
            Color(r: 0.85, g: 0.80, b: 0.50),   // number
        ])
    }

    private func runSearch() {
        search.find(findQuery, in: code)
        status = searchStatus()
        actionCount += 1
    }

    private func searchStatus() -> String {
        guard search.isActive else { return "no search" }
        guard search.count > 0 else { return "no matches" }
        let n = (search.currentIndex ?? 0) + 1
        return "match \(n)/\(search.count)"
    }

    /// A menu row: hover highlight, click, and it closes the menu after acting.
    /// Dismissing here rather than in the framework keeps the overlay unopinionated
    /// about whether picking something should close it — a checklist would not.
    private func menuItem(_ title: String, action: @escaping () -> Void) -> some View {
        Text(title, color: .primary, onClick: {
            action()
            showMenu = false
        })
        .padding(4)
        .hoverBackground(Environment.current.theme.hover)
        .cornerRadius(3)
    }

    public var body: some View {
        VStack(flexGrow: 1, padding: 0) {
            toolbar
            HStack(flexGrow: 1, padding: 4) {
                if session.showSidebar {
                    sidebar
                }
                centerColumn
                if session.showInspector {
                    inspector
                }
            }
        }
    }

    // MARK: - Toolbar

    @ViewBuilder
    private var toolbar: some View {
        HStack(height: .pt(56), padding: 8) {
            // Client-side decoration. With no compositor title bar above it
            // this row *is* the non-client area: the buttons are here, and
            // `.windowDrag()` below makes its empty space the drag handle.
            // Hidden in a windowed app, where the window manager's own frame
            // already carries all three.
            if WindowBridge.drawsOwnChrome {
                WindowControls()
                    .padding(.trailing, 6)
                    .windowChrome()
            }
            if let brandImage {
                Image(brandImage, width: .pt(40), height: .pt(40), contentMode: .fit)
            }
            VStack(padding: 2) {
                Text("LavaUI · DemoExample", color: .accent)
                Text(status, color: .secondary)
            }
            Spacer()
            Text(
                session.lightTheme ? "[ Theme: Light ]" : "[ Theme: Dark ]",
                color: .muted,
                onClick: {
                    session.toggleTheme()
                    bump("theme → \(session.lightTheme ? "light" : "dark")")
                }
            )
            .agentId("theme-toggle")
            Text(
                session.showSidebar ? "[ Hide nav ]" : "[ Show nav ]",
                color: .muted,
                onClick: {
                    session.showSidebar.toggle()
                    bump(session.showSidebar ? "sidebar on" : "sidebar off")
                }
            )
            .agentId("sidebar-toggle")
            Text(
                session.showInspector ? "[ Hide inspector ]" : "[ Show inspector ]",
                color: .muted,
                onClick: {
                    session.showInspector.toggle()
                    bump(session.showInspector ? "inspector on" : "inspector off")
                }
            )
            .agentId("inspector-toggle")
        }
        // Everything the toolbar does not otherwise use drags the window, and
        // a double-click maximizes it — a title bar's two gestures, on a row
        // the app was drawing anyway. The controls and text above still take
        // their own clicks: the hit test reaches children first.
        .windowDrag()
    }

    // MARK: - Sidebar (fixed width column + dynamic ForEach)

    @ViewBuilder
    private var sidebar: some View {
        VStack(width: .pt(200), padding: 8) {
            Text("Navigation", color: .accent)
            Text("ForEach + selection", color: .dim)
            // Rows slide in from the left as they are added and fade out where
            // they stood when removed — a keyed ForEach is the case that most
            // needs it, since a row can leave from the middle of the list.
            ForEach(items, id: \.id) { item in
                let selected = item.id == selectedId
                Text(
                    "  \(item.title)",
                    color: selected ? .selected : .primary,
                    onClick: {
                        selectedId = item.id
                        bump("selected \(item.title)")
                    }
                )
                .transition(.slide(dx: -14, dy: 0))
            }
            Spacer()
            Text(
                "+ Add item",
                color: .accent,
                onClick: { addItem() }
            )
            if !items.isEmpty {
                Text(
                    "− Remove last",
                    color: .muted,
                    onClick: { removeLast() }
                )
            }
            Text("items: \(items.count)", color: .dim)
        }
    }

    // MARK: - Center (flexGrow fills remaining width)

    @ViewBuilder
    private var centerColumn: some View {
        // The column's content has outgrown the window for a while; this is
        // what a general ScrollView is for.
        ScrollView {
            centerContent
        }
    }

    @State private var hovered: Int?
    @State private var selected: Int?

    private var bgColor = Color(r: 0.38, g: 0.09, b: 0.1)

    private var centerContent: some View {
        VStack(padding: 8) {
            SpatialCatalogDemo(posters)

            Text("Stack spacing", color: .accent)
            Text(
                "nil uses the theme default; zero and explicit spacing match SwiftUI.",
                color: .secondary
            )
            VStack(spacing: 6) {
                HStack(alignment: .center) {
                    Text("One", color: .primary).padding(3).background(bgColor)
                    Text("Two", color: .primary).padding(3).background(bgColor)
                    Text("Three", color: .primary).padding(3).background(bgColor)
                }.background(Color(r: 0.3, g: 0.5, b: 0.0))
                HStack(alignment: .center, spacing: 16) {
                    Text("16 pt", color: .dim).frame(width: .pt(64)).background(bgColor)
                    Text("One", color: .primary).padding(.bottom, 10).background(bgColor)
                    Text("Two", color: .primary).padding(.top, 10).background(bgColor)
                    Text("Three", color: .primary).padding(.trailing, 10).background(bgColor)
                    Text("Four", color: .primary).padding(.leading, 10).background(bgColor)
                }
                HStack(alignment: .center, spacing: 0) {
                    Text("zero", color: .dim).frame(width: .pt(64)).background(bgColor)
                    Text("One", color: .primary).padding(3).background(bgColor)
                    Text("Two", color: .primary).padding(3).background(bgColor)
                    Text("Three", color: .primary).padding(3).background(bgColor)
                }
            }

            Text("Charts · pie (static Canvas)", color: .accent)
            Text(
                "Donut tap cycles slices. Live widgets live in the collapsible lab below.",
                color: .secondary
            )
            PieChart(
                slices: pieSlices,
                selectedId: $pieSelected,
                size: 168,
                title: "Mix"
            )

            // Constant AnimationDriver work (pulse + live line) is gated here so
            // a long scroll is not paying 60fps redraws while the lab is closed.
            Expand("Live lab", isExpanded: $showLiveLab) {
                VStack(padding: 6) {
                    Text("PulseMeter · neon EQ", color: .accent)
                    Text(
                        "Continuous redraw while playing — click the meter to pause.",
                        color: .secondary
                    )
                    PulseMeter(isPlaying: $pulsePlaying, barCount: 16)
                    HStack(padding: 2) {
                        Toggle("Pulse", isOn: $pulsePlaying)
                            .agentId("pulse-toggle")
                        Text(pulsePlaying ? "live" : "paused", color: .dim)
                        Spacer()
                    }

                    Text("Line chart · live series", color: .accent)
                    LineChart(
                        series: lineSeries,
                        width: 360,
                        height: 168,
                        live: chartLive,
                        title: "Signals"
                    )
                    HStack(padding: 2) {
                        Toggle("Live wave", isOn: $chartLive)
                            .agentId("chart-live-toggle")
                        Spacer()
                    }
                }
            }
            .agentId("live-lab")

            Text("Dynamic flex row", color: .accent)
            Text(
                "Each chip has flexGrow=1 — resize the window or change slot count.",
                color: .secondary
            )

            // Equal-share flex children; count is stateful.
            HStack(height: .pt(56), padding: 4) {
                ForEach(Array(0..<max(1, flexSlots)), id: \.self) { i in
                    VStack(flexGrow: 1, padding: 6) {
                        Text("slot \(i + 1)", color: .primary)
                        Text("grow", color: .dim)
                    }
                }
            }

            HStack(padding: 4) {
                Text(
                    "− slots",
                    color: .muted,
                    onClick: {
                        flexSlots = max(1, flexSlots - 1)
                        bump("flexSlots=\(flexSlots)")
                    }
                )
                Text("slots: \(flexSlots)", color: .primary)
                Text(
                    "+ slots",
                    color: .muted,
                    onClick: {
                        flexSlots = min(8, flexSlots + 1)
                        bump("flexSlots=\(flexSlots)")
                    }
                )
                Spacer()
                Text("actions: \(actionCount)", color: .dim)
            }

            Text("TextField + list", color: .accent)
            TextField(
                text: $draft,
                placeholder: "Type a name, then Add…",
                onSubmit: { addItem() }
            )
            // Modifier chain on a single node: no extra Yoga boxes.
            Text("Modifiers · .padding().background().cornerRadius()", color: .accent)
            HStack(padding: 2) {
                Text("chip", color: .primary)
                    .padding(6)
                    .background(Color(r: 0.30, g: 0.35, b: 0.50))
                    .cornerRadius(6)
                Text("wide", color: .primary)
                    .padding(6)
                    .background(Color(r: 0.20, g: 0.40, b: 0.35))
                    .cornerRadius(6)
                    .frame(width: .pt(120))
                // Fragment content: this one legitimately materialises a box.
                VStack(padding: 0) {
                    Text("two", color: .secondary)
                    Text("rows", color: .secondary)
                }
                .padding(6)
                .background(Color(r: 0.40, g: 0.28, b: 0.28))
                .cornerRadius(6)
                // A bare ForEach is a *fragment* — no node of its own — so this
                // is the one case that materialises a wrapper box.
                ForEach(items.prefix(2), id: \.id) { item in
                    Text(item.title, color: .secondary)
                }
                .padding(6)
                .background(Color(r: 0.28, g: 0.30, b: 0.45))
                .cornerRadius(6)
                Spacer()
            }

            Text("Backdrop blur · .blur() glass", color: .accent)
            Text(
                "Captures UI already painted under the panel, blurs it, draws chrome sharp on top.",
                color: .secondary
            )
            // Saturated strip so frost is obvious; glass overlay anchors here.
            HStack(height: .pt(72), padding: 4) {
                ForEach(Array(DemoPalette.swatches.enumerated()), id: \.offset) { i, c in
                    VStack(flexGrow: 1, padding: 4) {
                        Text("\(i + 1)", color: .primary)
                    }
                    .background(c)
                    .cornerRadius(6)
                }
            }.blur(radius: 5)
            HStack(padding: 2) {
                Button(showGlass ? "Hide glass" : "Show glass") {
                    showGlass.toggle()
                    bump(showGlass ? "glass on" : "glass off")
                }

                Text("(glass opens on the colour strip)", color: .dim)
                Spacer()
            }
            .overlay(
                isPresented: $showGlass,
                alignment: .above,
                // Transparent shell — glass fill + blur live on the content below.
                style: OverlayStyle(
                    background: Color(r: 0, g: 0, b: 0, a: 0),
                    border: Color(r: 0.85, g: 0.88, b: 0.95).opacity(0.4),
                    cornerRadius: 24,
                    padding: 0,
                    minWidth: 400
                )
            ) {
                VStack(padding: 4) {
                    Text("Frosted panel", color: .primary)
                    Text("backdrop blur · radius 10", color: .secondary)
                    Text("Close", color: .accent, onClick: {
                        showGlass = false
                        bump("glass off")
                    })
                }
                .padding(14)
                // Stronger tint so glass reads even when the blur is subtle.
                .background(Color(r: 0.95, g: 0.96, b: 1.0).opacity(0.28))
                .cornerRadius(12)
                .backdropBlur(radius: 10)
            }

            Text("Button · animated press + hover", color: .accent)
            HStack(padding: 2) {
                Button("Add item") { addItem() }
                Button("Remove last") { removeLast() }
                Button("Disabled", isEnabled: false) {}
                Spacer()
            }

            Text("Toggle · animated knob", color: .accent)
            HStack(padding: 2) {
                // Bound to the same state the toolbar drives, so flipping it
                // from up there animates these too.
                Toggle("Nav", isOn: $session.showSidebar)
                Divider()
                Toggle("Inspector", isOn: $session.showInspector)
                Divider()
                Toggle("Locked", isOn: .constant(true), isEnabled: false)
                Spacer()
            }

            // No axis given: horizontal here in the VStack, vertical in the
            // HStack below, from the same call.
            Divider()

            Text("Overlay · menu above everything", color: .accent)
            HStack(padding: 2) {
                // The menu is composed from primitives that already existed —
                // Text with a hover fill and an onClick. Nothing about it is
                // menu-specific except where it draws.
                Button("Actions") { showMenu.toggle() }
                    .overlay(isPresented: $showMenu, style: OverlayStyle(minWidth: 150)) {
                        VStack {
                            menuItem("Add item") { addItem() }
                            menuItem("Remove last") { removeLast() }
                            Divider()
                            menuItem("Reset list") {
                                items = DemoExample.seedItems
                                bump("list reset")
                            }
                        }
                    }
                Text("(Esc or a click outside closes it)", color: .dim)
                Spacer()
            }

            Text("Transition · appear / disappear", color: .accent)
            HStack(padding: 2) {
                Toggle("Show banner", isOn: $session.showBanner)
                Spacer()
            }
            // An `if` is one of the three places a node can actually be
            // inserted or removed, so this is where a transition means anything.
            if session.showBanner {
                Text("  This panel slides down and fades as it comes and goes.  ")
                    .padding(8)
                    .background(Color(r: 0.24, g: 0.30, b: 0.42))
                    .cornerRadius(6)
                    .transition(.slide(dy: -12))
            }

            Text("Slider · drag, step, readout", color: .accent)
            HStack(padding: 2) {
                Text("slots", color: .secondary)
                // An Int driven through a Float binding — the flex row above
                // reflows as this is dragged.
                Slider(
                    value: Binding(
                        get: { Float(flexSlots) },
                        set: { flexSlots = Int($0) }
                    ),
                    in: 1...6, step: 1, format: { String(Int($0)) }
                )
                Text("gauge", color: .secondary)
                Slider(value: $gauge, in: 0...1, format: { String(format: "%.2f", $0) })
                Slider(value: .constant(0.5), isEnabled: false)
                Spacer()
            }

            Text("EditorView · gutter, rules, find", color: .accent)
            HStack(padding: 2) {
                TextField(
                    text: $findQuery, placeholder: "find…",
                    onSubmit: { runSearch() }
                )
                Text("[ find ]", color: .accent, onClick: { runSearch() })
                Text("[ next ]", color: .accent, onClick: {
                    search.next()
                    status = searchStatus()
                })
                Text(searchStatus(), color: .dim)
            }
            EditorView(
                text: $code, rules: stRules, style: codeStyle,
                visibleLines: 12, search: search
            )

            Text("Multi-line TextField", color: .accent)
            TextField(
                text: $notes, placeholder: "Notes…",
                multiline: true, maxLines: 8, wraps: true
            )

            HStack(padding: 2) {
                Text(
                    "[ Add from field ]",
                    color: .accent,
                    onClick: { addItem() }
                )
                Text(
                    "[ Clear selection ]",
                    color: .muted,
                    onClick: {
                        selectedId = nil
                        bump("selection cleared")
                    }
                )
                Spacer()
            }

            // Detail branch: EitherView via if/else
            if let id = selectedId, let item = items.first(where: { $0.id == id }) {
                VStack(padding: 6) {
                    Text("Selected", color: .accent)
                    Text("id=\(item.id)  ·  \(item.title)", color: .primary)
                    Text(
                        "Hue swatch \(item.hue % DemoPalette.swatches.count) — "
                            + "click another row or remove items to reflow the list.",
                        color: .secondary
                    )
                }
            } else {
                Text("(nothing selected — click a nav row)", color: .secondary)
            }

            // Growing canvas region (DiagramHost is the flex “hole”).
            Text("DiagramHost (flex canvas)", color: .accent)
            DiagramHost(flexGrow: 1)

            Text(
                "Tip: Ctrl+Shift +/- changes UI font scale (re-measure + re-raster).",
                color: .dim
            )
        }
    }

    // MARK: - Inspector (fixed width, wrap demo)

    @ViewBuilder
    private var inspector: some View {
        VStack(width: .pt(260), padding: 8) {
            Text("Inspector", color: .accent)
            Text("Widgets in this demo", color: .secondary)
            Text("· HStack / VStack / Spacer", color: .primary)
            Text("· Text + hover / onClick", color: .primary)
            Text("· TextField (binding)", color: .primary)
            Text("· Image (optional asset)", color: .primary)
            Text("· ForEach (keyed list)", color: .primary)
            Text("· if / else branches", color: .primary)
            Text("· DiagramHost flexGrow", color: .primary)
            Text("· Canvas charts / pulse", color: .primary)
            Text("· @State + Theme", color: .primary)

            Spacer()

            Text("Wrap sample", color: .accent)
            Text(
                "This paragraph is measured with Font::measure and wraps to "
                    + "the inspector width. Resize the window or hide the "
                    + "sidebar to change free space and watch flex reflow.",
                color: .secondary
            )

            if let id = selectedId, let item = items.first(where: { $0.id == id }) {
                Text("Focus: \(item.title)", color: .selected)
            } else {
                Text("Focus: —", color: .dim)
            }

            Text(
                "Reset list",
                color: .muted,
                onClick: {
                    items = DemoExample.seedItems
                    selectedId = 1
                    nextId = 10
                    draft = ""
                    bump("list reset")
                }
            )
        }
    }

    // MARK: - Chart data

    /// Donut slices — list composition + a few fixed “channels”.
    private var pieSlices: [PieSlice] {
        var out: [PieSlice] = [
            PieSlice(id: 100, label: "UI", value: 3 + Float(flexSlots),
                     color: Color(r: 0.35, g: 0.65, b: 1.0)),
            PieSlice(id: 101, label: "GPU", value: 2 + gauge * 4,
                     color: Color(r: 0.95, g: 0.45, b: 0.75)),
            PieSlice(id: 102, label: "I/O", value: 1.5 + Float(actionCount % 5) * 0.35,
                     color: Color(r: 0.35, g: 0.9, b: 0.7)),
        ]
        // One wedge per nav item so the list and chart stay coupled.
        for item in items.prefix(4) {
            out.append(
                PieSlice(
                    id: item.id,
                    label: item.title,
                    value: 1 + Float(item.hue % 3) * 0.4,
                    color: DemoPalette.color(at: item.hue)
                )
            )
        }
        return out
    }

    /// Static series for the line chart (live wave is synthetic in paint).
    private var lineSeries: [LineSeries] {
        let n = 40
        let g = gauge
        let slots = Float(flexSlots)
        let base: [Float] = (0..<n).map { i in
            let x = Float(i) / Float(n - 1)
            return 0.3 + 0.15 * sin(x * 8 + slots) + g * 0.35 * x
        }
        let load: [Float] = (0..<n).map { i in
            let x = Float(i) / Float(n - 1)
            return 0.2 + 0.5 * x * x + 0.1 * sin(x * 12 + Float(actionCount) * 0.1)
        }
        return [
            LineSeries(name: "base", color: Color(r: 0.55, g: 0.7, b: 1.0), samples: base),
            LineSeries(name: "load", color: Color(r: 1.0, g: 0.55, b: 0.4), samples: load),
        ]
    }

    // MARK: - Mutations

    private func bump(_ message: String) {
        actionCount += 1
        status = message
    }

    private func addItem() {
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = name.isEmpty ? "Item \(nextId)" : name
        let item = DemoItem(id: nextId, title: title, hue: nextId)
        nextId += 1
        items.append(item)
        selectedId = item.id
        draft = ""
        bump("added \(title)")
    }

    private func removeLast() {
        guard let last = items.popLast() else { return }
        if selectedId == last.id {
            selectedId = items.last?.id
        }
        bump("removed \(last.title)")
    }
}
