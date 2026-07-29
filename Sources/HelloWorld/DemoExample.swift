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
    @State private var showSidebar = true
    @State private var showInspector = true
    @State private var flexSlots = 3
    @State private var nextId = 10
    @State private var gauge: Float = 0.35
    @State private var lightTheme = false
    @State private var status = "Click a list row, edit the field, resize the window."
    @State private var actionCount = 0

    public init(brandImage: UIImage? = nil) {
        self.brandImage = brandImage
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

    public var body: some View {
        VStack(flexGrow: 1, padding: 0) {
            toolbar
            HStack(flexGrow: 1, padding: 4) {
                if showSidebar {
                    sidebar
                }
                centerColumn
                if showInspector {
                    inspector
                }
            }
        }
    }

    // MARK: - Toolbar

    @ViewBuilder
    private var toolbar: some View {
        HStack(height: .pt(56), padding: 8) {
            if let brandImage {
                Image(brandImage, width: .pt(40), height: .pt(40), contentMode: .fit)
            }
            VStack(padding: 2) {
                Text("LavaUI · DemoExample", color: .accent)
                Text(status, color: .secondary)
            }
            Spacer()
            Text(
                lightTheme ? "[ Theme: Light ]" : "[ Theme: Dark ]",
                color: .muted,
                onClick: {
                    lightTheme.toggle()
                    Theme.current = lightTheme ? .light : .dark
                    bump("theme → \(lightTheme ? "light" : "dark")")
                }
            )
            Text(
                showSidebar ? "[ Hide nav ]" : "[ Show nav ]",
                color: .muted,
                onClick: {
                    showSidebar.toggle()
                    bump(showSidebar ? "sidebar on" : "sidebar off")
                }
            )
            Text(
                showInspector ? "[ Hide inspector ]" : "[ Show inspector ]",
                color: .muted,
                onClick: {
                    showInspector.toggle()
                    bump(showInspector ? "inspector on" : "inspector off")
                }
            )
        }
    }

    // MARK: - Sidebar (fixed width column + dynamic ForEach)

    @ViewBuilder
    private var sidebar: some View {
        VStack(width: .pt(200), padding: 8) {
            Text("Navigation", color: .accent)
            Text("ForEach + selection", color: .dim)
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

    private var centerContent: some View {
        VStack(padding: 8) {
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
                Toggle("Nav", isOn: $showSidebar)
                Divider()
                Toggle("Inspector", isOn: $showInspector)
                Divider()
                Toggle("Locked", isOn: .constant(true), isEnabled: false)
                Spacer()
            }

            // No axis given: horizontal here in the VStack, vertical in the
            // HStack below, from the same call.
            Divider()

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
