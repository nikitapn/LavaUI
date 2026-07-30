#if canImport(CxxCanvas)
import Foundation

/// Style palette for `EditorView`. Rules carry style *indices*; this maps them
/// to colours, so a theme change restyles code without touching any rule.
public struct CodeStyle {
    public var text: Color
    public var gutterText: Color
    public var gutterBackground: Color
    public var currentLine: Color
    public var searchMatch: Color
    public var currentSearchMatch: Color
    /// Indexed by `HighlightRule.styleIndex`; out-of-range falls back to `text`.
    public var palette: [Color]

    public init(
        text: Color = .primary,
        gutterText: Color? = nil,
        gutterBackground: Color? = nil,
        currentLine: Color? = nil,
        searchMatch: Color? = nil,
        currentSearchMatch: Color? = nil,
        palette: [Color] = []
    ) {
        let theme = Environment.current.theme
        self.text = text
        self.gutterText = gutterText ?? theme.textSecondary
        self.gutterBackground = gutterBackground ?? theme.panel
        self.currentLine = currentLine ?? theme.hover
        self.searchMatch = searchMatch ?? Color(r: 0.45, g: 0.40, b: 0.15)
        self.currentSearchMatch = currentSearchMatch ?? Color(r: 0.70, g: 0.55, b: 0.15)
        self.palette = palette
    }

    func color(for styleIndex: Int) -> Color {
        palette.indices.contains(styleIndex) ? palette[styleIndex] : text
    }
}

/// A code editor: line-number gutter, current-line highlight, rule-based
/// syntax colouring, and find-match highlighting.
///
/// Everything about the *buffer* — cursor, selection, undo, wrapping, grapheme
/// correctness — is `TextEditingState`, unchanged and already tested. This
/// type is presentation plus a gutter, which is why it is a component rather
/// than a rewrite of `TextField`.
public struct EditorView: PrimitiveView {
    @Binding public var text: String
    public var rules: [HighlightRule]
    public var style: CodeStyle
    public var font: UIFont?
    public var showLineNumbers: Bool
    public var visibleLines: Int
    public var search: TextSearch

    public init(
        text: Binding<String>,
        rules: [HighlightRule] = [],
        style: CodeStyle = CodeStyle(),
        font: UIFont? = nil,
        showLineNumbers: Bool = true,
        visibleLines: Int = 12,
        search: TextSearch = TextSearch()
    ) {
        self._text = text
        self.rules = rules
        self.style = style
        self.font = font
        self.showLineNumbers = showLineNumbers
        self.visibleLines = visibleLines
        self.search = search
    }

    public var resolvedFont: UIFont? { font ?? Environment.current.font }

    public var dumpDetail: String {
        "\(text.split(separator: "\n").count) lines, \(rules.count) rules"
    }

    public func mountPrimitive() -> any AnyViewNode {
        let leaf = LeafNode(kind: .editor, label: "EditorView", width: .auto, height: .auto)
        leaf.editing = TextEditingState(text)
        configure(leaf)
        leaf.installTextMeasure()
        return leaf
    }

    public func reconcilePrimitive(_ node: any AnyViewNode) -> any AnyViewNode {
        guard let leaf = node as? LeafNode, leaf.kind == .editor else {
            return mountPrimitive()
        }
        if leaf.editing.text != text {
            leaf.editing.setText(text, keepingCursor: true)
        }
        configure(leaf)
        if !leaf.usesTextMeasure { leaf.installTextMeasure() }
        leaf.markMeasureDirty()
        return leaf
    }

    private func configure(_ leaf: LeafNode) {
        let theme = Environment.current.theme
        leaf.theme = theme
        leaf.font = resolvedFont
        leaf.color = style.text
        leaf.fillColor = theme.inset
        leaf.isMultiline = true
        leaf.wraps = false          // code editors scroll horizontally, not wrap
        leaf.highlighter = SyntaxHighlighter(rules: rules)
        leaf.codeStyle = style
        leaf.showsGutter = showLineNumbers
        leaf.search = search
        leaf.text = leaf.editing.text
        leaf.minWidth = 160

        // Height is decided by the measure callback from the row count, so
        // the box always matches what is drawn.
        leaf.maxLines = visibleLines
        if let f = resolvedFont {
            leaf.gutterWidth = showLineNumbers ? leaf.measuredGutterWidth(font: f) : 0
        }

        leaf.isScrollable = true
        // Wheel scrolls three rows a notch, the usual desktop feel.
        ScrollRouter.register(leaf.id) { [weak leaf] dx, dy in
            guard let leaf, let f = leaf.font ?? FontStore.default else { return }
            // Shift+wheel scrolls horizontally, the desktop convention for a
            // mouse with no horizontal axis. A trackpad supplies dx directly.
            if ScrollRouter.shiftHeld, dx == 0 {
                leaf.scrollByX(-dy * f.lineHeight * 3, font: f)
            } else {
                if dx != 0 { leaf.scrollByX(-dx * f.lineHeight * 3, font: f) }
                if dy != 0 { leaf.scrollBy(-dy * f.lineHeight * 3, lineHeight: f.lineHeight) }
            }
        }

        let binding = _text
        leaf.onClickLocal = { [weak leaf] localX, localY, originX, originY in
            guard let leaf else { return }
            leaf.focusSelf(binding: binding, onSubmit: nil)
            // Clicks in the gutter select the whole line, as they do in every
            // editor with one.
            if leaf.showsGutter, localX < leaf.gutterWidth {
                leaf.selectRow(atLocalY: localY)
            } else if let hit = leaf.index(
                atLocalX: localX - leaf.gutterWidth + leaf.scrollX,
                localY: localY + leaf.scrollY
            ) {
                let clicks = ClickCounter.register(x: originX + localX, y: originY + localY)
                if clicks >= 2 {
                    leaf.editing.selectWord(at: hit)
                } else {
                    leaf.editing.setCursor(hit)
                    PointerCapture.capture(
                        leaf.id,
                        onMove: { [weak leaf] wx, wy in
                            guard let leaf else { return }
                            let lx = wx - originX - leaf.gutterWidth + leaf.scrollX
                            let ly = wy - originY + leaf.scrollY
                            if let target = leaf.index(atLocalX: lx, localY: ly) {
                                leaf.editing.setCursor(target, extending: true)
                                ViewInvalidation.markDirty()
                            }
                        }
                    )
                }
            }
            CaretBlink.noteEdit()
            ViewInvalidation.markDirty()
        }
    }
}

extension LeafNode {
    /// Gutter wide enough for the highest line number, plus breathing room.
    /// Sized from the digit count so it does not jitter as the caret moves.
    func measuredGutterWidth(font: UIFont) -> Float {
        let digits = max(2, String(max(1, editing.lines.count)).count)
        let sample = String(repeating: "0", count: digits)
        return font.shapedRun(sample).width + textInset * 3
    }

    /// Selects the whole visual row under `localY` — the gutter-click gesture.
    func selectRow(atLocalY localY: Float) {
        let y = localY + scrollY
        guard let f = font ?? FontStore.default else { return }
        let rows = editing.layout.rows
        let row = max(0, min(rows.count - 1, Int((y - textInset) / f.lineHeight)))
        let r = rows[row]
        editing.setCursor(editing.index(atOffset: r.lowerBound))
        // Include the newline so a pasted replacement keeps the line structure.
        let end = min(r.upperBound + 1, editing.text.count)
        editing.setCursor(editing.index(atOffset: end), extending: true)
    }
}

#endif
