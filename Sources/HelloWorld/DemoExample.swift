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
    @State private var notes: String = "Multi-line with soft wrap. This sentence is long enough that it has to wrap onto several visual rows inside the panel.\nEnter still adds a hard line.\nUp/Down step visual rows."
    @State private var showSidebar = true
    @State private var showInspector = true
    @State private var flexSlots = 3
    @State private var nextId = 10
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
        VStack(flexGrow: 1, padding: 8) {
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
