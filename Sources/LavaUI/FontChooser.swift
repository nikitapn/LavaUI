import Foundation
import LavaFontCore
import Observation

/// An in-window font picker. Create a fresh chooser for each presentation and
/// use its placement and overlay style to route keyboard input to the dialog.
public struct FontChooser: View {
    private let state: FontChooserState
    private let purpose: String?
    private let onSelect: (FontChoice) -> Void
    private let onCancel: () -> Void

    public init(
        selection: FontChoice, purpose: String? = "Editor font", showsStyle: Bool = true,
        onSelect: @escaping (FontChoice) -> Void, onCancel: @escaping () -> Void
    ) {
        state = FontChooserState(selection: selection, showsStyle: showsStyle)
        self.purpose = purpose
        self.onSelect = onSelect
        self.onCancel = onCancel
    }

    public static let placement = OverlayPlacement { context in
        let width = min(920, max(1, context.viewport.width - 32))
        let height = min(640, max(1, context.viewport.height - 32))
        return OverlayFrame(x: (context.viewport.width - width) / 2,
                            y: (context.viewport.height - height) / 2, width: width, height: height)
    }

    public func overlayStyle(theme: Theme = Theme.current) -> OverlayStyle {
        var style = OverlayStyle(background: theme.panel, border: theme.border, cornerRadius: 20,
                                 padding: 0, scrim: Theme.dark.background.opacity(0.34), modal: true)
        style.onKey = handleKey
        style.onUnfocusedText = { character in
            guard !character.isNewline else { return }
            state.setQuery(state.model.query + String(character))
            state.searchFocused = true
        }
        return style
    }

    private var theme: Theme { Environment.current.theme }
    private var choice: FontChoice { state.model.choice }
    private var family: FontFamily? { state.catalog?.family(named: choice.family) }

    public var body: some View {
        VStack(flexGrow: 1, height: .pct(100), spacing: 0) {
            header
            rule(.horizontal)
            ScrollView(.vertical) {
                HStack(spacing: 0) {
                    familyPane
                        .frame(width: .pct(35))
                        .flexShrink(0)
                    rule(.vertical)
                    details
                }
                .frame(height: .pct(100), minHeight: 430)
            }
            .frame(minHeight: 0)
            .flexShrink(1)
            rule(.horizontal)
            footer
        }
        .cornerRadius(20)
        .clipped()
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("Choose a font", font: state.uiFont(20), lineLimit: 1, align: .leading)
                .flexGrow(1)
                .flexShrink(1)
            if let purpose {
                pill(purpose, size: 12, fill: theme.selectionFill, color: theme.textPrimary)
            }
            iconButton("Close", path: Glyph.close, action: onCancel)
        }
        .padding(EdgeInsets(top: 11, leading: 20, bottom: 11, trailing: 12))
        .underlay { chrome(top: true) }
    }

    private var familyPane: some View {
        let rows = state.rows
        return VStack(spacing: 0) {
            VStack(spacing: 10) {
                search
                ScrollView(.horizontal) {
                    HStack(height: .pt(28), alignment: .center, spacing: 5) {
                        ForEach(FontFilter.allCases, id: \.rawValue) { filter in
                            pill(filter.rawValue, size: 12, horizontal: 9,
                                 fill: state.model.filter == filter ? theme.selectionFill : .clear,
                                 outline: true) {
                                state.model.filter = filter
                                state.resetScroll()
                            }
                        }
                    }
                }
                .frame(height: .pt(28))
                .flexGrow(0)
            }
            .padding(EdgeInsets(top: 16, leading: 14, bottom: 10, trailing: 14))

            if state.catalog == nil {
                Text("Loading fonts…", color: theme.textSecondary).padding(14)
                Spacer()
            } else if rows.isEmpty {
                let query = state.model.query.trimmingCharacters(in: .whitespacesAndNewlines)
                Text(query.isEmpty ? "No fonts in this category." : "No fonts match “\(query)”.",
                     color: theme.textSecondary, align: .center)
                    .padding(14)
                Spacer()
            } else {
                ScrollView(.vertical, position: state.scroll) {
                    LazyVStack(rows, rowHeight: FontChooserState.rowHeight, scrollTarget: state.scrollTarget) { row in
                        switch row {
                        case .heading(let label):
                            kicker(label).padding(.leading, 10)
                                .frame(height: .pct(100))
                        case .family(let family):
                            familyRow(family)
                        }
                    }
                }
                .padding(.horizontal, 9)
                .flexShrink(1)
            }
        }
    }

    private var search: some View {
        HStack(height: .pt(40), alignment: .center, spacing: 6) {
            Icon(Glyph.search, size: 15, color: theme.textSecondary, strokeWidth: 2.5)
            TextField(text: Binding(get: { state.model.query }, set: state.setQuery),
                      placeholder: "Search fonts", font: state.uiFont(14),
                      focusRing: FocusRingStyle.none, restingOutline: false)
                .frame(minWidth: 0)
                .flexGrow(1)
                .flexShrink(1)
                .focused(Binding(get: { state.searchFocused }, set: { state.searchFocused = $0 }))
                .agentId("font-search")
            if !state.model.query.isEmpty {
                iconButton("Clear search", path: Glyph.close, size: 22, iconSize: 10,
                           fill: theme.hover) {
                    state.setQuery("")
                    state.searchFocused = true
                }
            }
        }
        .padding(.horizontal, 12)
        .background(theme.inset)
        .cornerRadius(20)
        .border(state.searchFocused ? theme.accent : theme.inset)
    }

    private func familyRow(_ family: FontFamily) -> some View {
        let selected = family.name == self.family?.name
        let favorite = state.model.favorites.contains(family.name)
        let weights = "\(family.weightCount) \(family.weightCount == 1 ? "weight" : "weights")"
        return HStack(height: .pt(FontChooserState.rowHeight), alignment: .center, spacing: 0) {
            VStack(flexGrow: 1, alignment: .stretch, spacing: 1, onClick: {
                state.model.pick(family)
                state.searchFocused = true
            }) {
                Text(family.name, font: state.font(family.face(for: .regular), size: 17), lineLimit: 1)
                Text("\(family.category.rawValue) · \(weights)", color: theme.textSecondary,
                     font: state.uiFont(12), lineLimit: 1)
            }
            .padding(EdgeInsets(top: 6, leading: 11, bottom: 6, trailing: 4))
            .frame(height: .pt(FontChooserState.rowHeight), minWidth: 0)
            .flexShrink(1)
            .cursor(.pointer)
            .cornerRadius(14)
            .hoverBackground(selected ? theme.selectionFill : theme.hover)

            iconButton("Favorite \(family.name)", path: Glyph.star, iconSize: 14, stroke: 2.25,
                       color: favorite ? theme.accent : theme.textSecondary, filled: favorite) {
                state.toggleFavorite(family.name)
            }
            .padding(.trailing, 5)
        }
        .background(selected ? theme.selectionFill : .clear)
        .cornerRadius(14)
    }

    private var details: some View {
        VStack(flexGrow: 1, spacing: 16) {
            HStack(alignment: .start, spacing: 12, wraps: true) {
                if state.model.showsStyle { styles }
                sizeControls
            }
            .flexShrink(0)
            preview
        }
        .padding(EdgeInsets(top: 16, leading: 18, bottom: 14, trailing: 18))
        .frame(minWidth: 0, minHeight: 0)
        .flexShrink(1)
    }

    private var styles: some View {
        VStack(alignment: .start, spacing: 7) {
            kicker("Style")
            HStack(alignment: .center, spacing: 2, wraps: true) {
                ForEach(FontStyle.allCases, id: \.rawValue) { style in
                    let enabled = family?.availableStyles.contains(style) == true
                    let active = choice.style == style && enabled
                    pill(style.rawValue, size: 13, horizontal: 8,
                         fill: active ? theme.panel : .clear,
                         color: enabled ? theme.textPrimary : theme.textDim,
                         font: enabled ? state.font(family?.face(for: style), size: 13) : nil,
                         action: enabled ? { if let family { state.model.pickStyle(style, in: family) } } : nil)
                }
            }
            .padding(3)
            .background(theme.inset)
            .cornerRadius(18)
        }
        .flexShrink(1)
    }

    private var sizeControls: some View {
        VStack(flexGrow: 1, alignment: .stretch, spacing: 7) {
            kicker("Size")
            HStack(alignment: .center, spacing: 10) {
                HStack(alignment: .center, spacing: 0) {
                    iconButton("Smaller", path: Glyph.minus, stroke: 3) {
                        state.setSize(choice.size - 1)
                    }
                    TextField(text: Binding(get: { state.sizeDraft ?? String(choice.size) },
                                            set: state.editSize),
                              font: state.uiFont(14), selectionOnFocus: .all,
                              focusRing: FocusRingStyle.none, restingOutline: false)
                        .frame(width: .pt(42), height: .pt(30), minWidth: 0)
                        .background(theme.panel)
                        .cornerRadius(15)
                        .focused(Binding(get: { state.sizeFocused }, set: {
                            state.sizeFocused = $0
                            if !$0 { state.sizeDraft = nil }
                        }))
                        .agentId("font-size")
                    iconButton("Larger", path: Glyph.plus, stroke: 3) {
                        state.setSize(choice.size + 1)
                    }
                }
                .padding(3)
                .background(theme.inset)
                .cornerRadius(20)

                Slider(value: Binding(get: { Float(choice.size) }, set: { state.setSize(Int($0)) }),
                       in: 6...96, step: 1, style: sliderStyle)
                    .frame(minWidth: 30)
                    .flexGrow(1)
                    .flexShrink(1)
                    .agentId("font-size-slider")
            }
            HStack(alignment: .center, spacing: 4, wraps: true) {
                ForEach(FontChooserModel.presets, id: \.self) { size in
                    let active = choice.size == size
                    pill(String(size), size: 12, horizontal: 8,
                         fill: active ? theme.accent : theme.inset,
                         color: active ? theme.background : theme.textSecondary, minWidth: 33) {
                        state.model.pickPreset(size)
                        state.sizeDraft = nil
                    }
                }
            }
        }
        .frame(width: .pt(220), minWidth: 180)
        .flexShrink(1)
    }

    private var sliderStyle: SliderStyle {
        var style = SliderStyle(trackWidth: 100, trackThickness: 5, knobRadius: 7,
                                activeTrack: theme.accent, inactiveTrack: theme.border, knob: theme.panel)
        style.knobRing = theme.accent
        style.knobRingWidth = 2
        return style
    }

    private var preview: some View {
        let colors = state.dark ? Theme.graphite : theme
        let face = family?.face(for: choice.style)
        return VStack(flexGrow: 1, spacing: 8) {
            HStack(alignment: .center, spacing: 6, wraps: true) {
                kicker("Preview").flexGrow(1)
                HStack(alignment: .center, spacing: 2) {
                    ForEach(FontSample.allCases, id: \.rawValue) { sample in
                        pill(sample.rawValue, size: 13, horizontal: 7,
                             fill: state.sample == sample ? theme.panel : .clear) {
                            state.sample = sample
                            state.previewText = sample.text
                        }
                    }
                }
                .padding(3)
                .background(theme.inset)
                .cornerRadius(20)
                pill("Dark", size: 13, horizontal: 9,
                     fill: state.dark ? colors.inset : .clear,
                     color: colors.textSecondary,
                     outline: true, icon: Glyph.moon) {
                    state.dark.toggle()
                }
            }

            VStack(flexGrow: 1, spacing: 0) {
                previewEditor(face: face, colors: colors)
                rule(.horizontal, color: colors.border)
                HStack(alignment: .center, spacing: 6) {
                    Text("Aa Bb 0O 1lI {} =>", color: colors.textPrimary,
                         font: state.font(face, size: 15), lineLimit: 1, align: .leading)
                        .flexGrow(1)
                        .flexShrink(1)
                    Text("\(state.previewText.count) characters", color: colors.textSecondary,
                         font: state.uiFont(12), lineLimit: 1)
                }
                .padding(EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14))
            }
            .frame(minHeight: 0)
            .flexShrink(1)
            .theme(previewTheme(colors))
            .background(colors.inset)
            .cornerRadius(20)
            .border(colors.border)
            .clipped()
        }
        .frame(minHeight: 0)
        .flexShrink(1)
    }

    private func previewEditor(face: FontFace?, colors: Theme) -> some View {
        var style = CodeStyle(text: colors.textPrimary, currentLine: .clear)
        style.scrollbarColor = colors.border
        style.placeholder = "Type a preview"
        return BoxRegistrationView(
            label: "Font preview",
            register: { state.previewNodeID = $0.id },
            content: EditorView(
                text: Binding(get: { state.previewText }, set: { state.previewText = $0 }),
                style: style, font: state.font(face, size: Float(choice.size), lineHeight: 1.5),
                showLineNumbers: false, wraps: true
            )
        )
        .frame(minWidth: 0, minHeight: 0)
        .background(.clear)
        .flexGrow(1)
        .flexShrink(1)
        .agentId("font-preview")
    }

    private func previewTheme(_ source: Theme) -> Theme {
        var colors = source
        colors.controlPadding = 16
        colors.cornerRadius = 0
        return colors
    }

    private var footer: some View {
        let subtitle = switch family?.category {
        case .monospace: "Monospace · good for code"
        case .serif: "Serif · proportional"
        case .sans: "Sans · proportional"
        case nil: state.catalog == nil ? "Loading fonts…" : "Family unavailable"
        }
        let face = family?.face(for: choice.style)
        let style = state.model.showsStyle ? " \(choice.style.rawValue)" : ""
        return HStack(alignment: .center, spacing: 8) {
            Text("Aa", font: state.font(face, size: 18), align: .center)
                .frame(width: .pt(36), height: .pt(36))
                .background(theme.inset)
                .cornerRadius(12)
            VStack(flexGrow: 1, spacing: 1) {
                Text("\(choice.family)\(style), \(choice.size) px", font: state.uiFont(14), lineLimit: 1)
                Text(subtitle, color: theme.textSecondary, font: state.uiFont(12), lineLimit: 1)
            }
            .frame(minWidth: 0)
            .flexShrink(1)
            pill("Reset", horizontal: 12, color: theme.accent) {
                if let catalog = state.catalog {
                    state.model.reset(in: catalog)
                    state.sizeDraft = nil
                    state.revealChoice()
                }
            }
            pill("Cancel", horizontal: 12, fill: theme.panel, outline: true, action: onCancel)
            pill("Select", horizontal: 13, fill: family == nil ? theme.inset : theme.accent,
                 color: family == nil ? theme.textDim : theme.background, icon: Glyph.check,
                 action: family == nil ? nil : { onSelect(choice) })
        }
        .padding(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 14))
        .underlay { chrome(top: false) }
    }

    private func chrome(top: Bool) -> some View {
        let color = theme.background
        return Canvas(label: "Font chooser chrome", width: .pct(100), height: .pct(100)) { list, frame in
            let radius: Float = 20
            list.roundedRect(x: frame.x, y: frame.y, w: frame.w, h: frame.h,
                             color: color, radius: radius)
            list.rect(x: frame.x, y: top ? frame.y + radius : frame.y, w: frame.w,
                      h: max(0, frame.h - radius), color: color)
        }
    }

    private func kicker(_ text: String) -> some View {
        Text(text.uppercased(), color: theme.textSecondary, font: state.uiFont(11),
             lineLimit: 1, align: .leading)
    }

    private func rule(_ axis: DividerAxis, color: Color? = nil) -> Divider {
        Divider(axis, style: DividerStyle(thickness: 1, spacing: 0, color: color ?? theme.border))
    }

    private func pill(
        _ text: String, size: Float = 14, horizontal: Float = 10, fill: Color = .clear,
        color: Color? = nil, outline: Bool = false, font: UIFont? = nil, icon: String? = nil,
        minWidth: Float? = nil,
        action: (() -> Void)? = nil
    ) -> some View {
        let foreground = color ?? theme.textPrimary
        return HStack(alignment: .center, spacing: 5, onClick: action) {
            if let icon { Icon(icon, size: 13, color: foreground, strokeWidth: 2.75) }
            Text(text, color: foreground, font: font ?? state.uiFont(size), lineLimit: 1, align: .center)
                .flexGrow(minWidth == nil ? 0 : 1)
        }
        .padding(EdgeInsets(top: 5, leading: horizontal, bottom: 5, trailing: horizontal))
        .frame(minWidth: minWidth)
        .background(fill)
        .cornerRadius(18)
        .border(outline ? theme.border : .clear)
        .hoverBackground(action == nil ? fill : (fill == theme.accent ? theme.selected : theme.hover))
        .cursor(action == nil ? nil : .pointer)
    }

    private func iconButton(
        _ label: String, path: String, size: Float = 30, iconSize: Float = 13, stroke: Float = 2.75,
        fill: Color = .clear, color: Color? = nil, filled: Bool = false, action: @escaping () -> Void
    ) -> some View {
        HStack(width: .pt(size), height: .pt(size), alignment: .center, spacing: 0, onClick: action) {
            Icon(filled ? [.fill(path), .path(path)] : [.path(path)], size: iconSize,
                 color: color ?? theme.textSecondary, strokeWidth: stroke, box: size)
        }
        .background(fill)
        .cornerRadius(size / 2)
        .hoverBackground(theme.hover)
        .cursor(.pointer)
        .agentId(label)
    }

    private func handleKey(_ event: KeyEvent) -> Bool {
        switch event.key {
        case KeyCode.escape:
            onCancel()
        case KeyCode.enter where !event.shift || !state.previewFocused:
            if family != nil { onSelect(choice) }
        case KeyCode.up, KeyCode.down:
            if state.previewFocused || state.sizeFocused { return false }
            state.moveSelection(by: event.key == KeyCode.up ? -1 : 1)
        default:
            return false
        }
        return true
    }
}

private enum Glyph {
    static let search = "M11 19a8 8 0 1 0 0-16 8 8 0 0 0 0 16ZM21 21l-4.3-4.3"
    static let close = "M18 6 6 18M6 6l12 12"
    static let star = "M12 2l3.09 6.26L22 9.27l-5 4.87 1.18 6.88L12 17.77l-6.18 3.25L7 14.14 2 9.27l6.91-1.01Z"
    static let minus = "M5 12h14"
    static let plus = "M12 5v14M5 12h14"
    static let check = "M20 6 9 17l-5-5"
    static let moon = "M21 12.8A9 9 0 1 1 11.2 3a7 7 0 0 0 9.8 9.8Z"
}

private enum FontSample: String, CaseIterable {
    case pangram = "Pangram", code = "Code", paragraph = "Paragraph"

    var text: String {
        switch self {
        case .pangram:
            "The quick brown fox jumps over the lazy dog.\nSphinx of black quartz, judge my vow.\n0123456789 — ¿¡ «» “” ‘’"
        case .code:
            """
            fn render(view: &View) -> Result<Frame, Error> {
                let scale = view.scale.max(1.0); // O0 Il1 |
                if frame.id != 0x1F && ok >= 3 { return Ok(frame) }
                todo!("=> <= != === ->")
            }
            """
        case .paragraph:
            """
            Typography is the craft of endowing human language with a durable visual form. A good editor font keeps similar letters distinct, holds its rhythm at small sizes, and stays calm over a long day of reading.
            """
        }
    }
}

private enum FontListRow: Identifiable {
    case heading(String)
    case family(FontFamily)

    var id: String {
        switch self {
        case .heading(let label): "heading:\(label)"
        case .family(let family): "family:\(family.name)"
        }
    }

    var family: FontFamily? {
        if case .family(let family) = self { return family }
        return nil
    }
}

@Observable
private final class FontChooserState: @unchecked Sendable {
    var model: FontChooserModel
    var catalog: FontCatalog?
    var sample = FontSample.code
    var previewText = FontSample.code.text
    var dark = false
    var searchFocused = true
    @ObservationIgnored var previewNodeID: NodeID?
    var previewFocused: Bool { previewNodeID.map(FocusManager.isFocused) ?? false }
    var sizeFocused = false
    var sizeDraft: String?
    var scrollTarget: Int?
    static let rowHeight: Float = 54
    let scroll = ScrollPosition()
    @ObservationIgnored private let fonts = NSCache<NSString, UIFont>()
    private static let favoritesKey = "fontChooser.favorites"
    private static let defaultFavorites: Set<String> = ["JetBrains Mono", "Figtree"]

    init(selection: FontChoice, showsStyle: Bool) {
        let favorites = AppSettings.sharedValue(forKey: Self.favoritesKey, as: Set<String>.self)
        model = FontChooserModel(selection: selection, showsStyle: showsStyle,
                                 favorites: favorites ?? Self.defaultFavorites)
        fonts.countLimit = 128
        FontCatalog.load { [weak self] catalog in
            MainQueue.async { [weak self] in
                guard let self else { return }
                self.catalog = catalog
                if let family = catalog.family(named: self.model.choice.family) { self.model.pick(family) }
                self.revealChoice()
            }
        }
    }

    var rows: [FontListRow] {
        guard let catalog else { return [] }
        return model.groups(in: catalog).flatMap { [.heading($0.label)] + $0.families.map(FontListRow.family) }
    }

    func setQuery(_ query: String) {
        model.query = query
        resetScroll()
    }

    func resetScroll() {
        scrollTarget = nil
        scroll.scroll(to: 0)
    }

    func revealChoice() {
        guard let index = rows.firstIndex(where: { $0.family?.name == model.choice.family }) else { return }
        scrollTarget = nil
        scroll.scroll(to: Float(max(0, index - 2)) * Self.rowHeight)
    }

    func moveSelection(by delta: Int) {
        let rows = rows
        let available = rows.indices.filter { rows[$0].family != nil }
        guard let first = available.first else { return }
        let current = available.firstIndex { rows[$0].family?.name == model.choice.family }
        let index = current.map { available[min(max(0, $0 + delta), available.count - 1)] } ?? first
        if let family = rows[index].family { model.pick(family) }
        scrollTarget = index
    }

    func setSize(_ size: Int) {
        sizeDraft = nil
        model.setSize(size)
    }

    func editSize(_ text: String) {
        guard text.isEmpty || Int(text) != nil else { return }
        sizeDraft = text
        if let size = Int(text) { model.setSize(size) }
    }

    func toggleFavorite(_ name: String) {
        model.favorites = AppSettings.updateSharedValue(Set<String>.self, forKey: Self.favoritesKey) {
            var updated = model
            updated.favorites = $0 ?? Self.defaultFavorites
            updated.toggleFavorite(name)
            return updated.favorites
        }
    }

    func uiFont(_ size: Float) -> UIFont? {
        guard let base = Environment.current.font else { return nil }
        return font(FontFace(path: base.path, index: base.faceIndex), size: size)
    }

    func font(_ face: FontFace?, size: Float, lineHeight: Float? = nil) -> UIFont? {
        guard let face, let editor = WindowScope.currentOrMain.editor else { return nil }
        let key = "\(face.path)#\(face.index)@\(size)/\(lineHeight ?? 0)" as NSString
        if let cached = fonts.object(forKey: key) { return cached }
        guard let font = UIFont(path: face.path, pixelSize: size, faceIndex: face.index,
                                lineHeightMultiple: lineHeight),
              font.registerWithEngine(editor) else { return nil }
        if let base = FontStore.default { font.fallbacks = [base] + base.fallbacks }
        fonts.setObject(font, forKey: key)
        return font
    }
}
