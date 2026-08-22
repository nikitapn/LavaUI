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

/// How urgently an `EditorDecoration` should read — supplies a default color
/// and gutter glyph so a caller can skip both and just say what kind of
/// thing this is.
public enum DiagnosticSeverity: Sendable, Equatable {
    case error, warning, info, hint

    var defaultColor: Color {
        switch self {
        case .error: return Color(r: 0.92, g: 0.35, b: 0.35)
        case .warning: return Color(r: 0.92, g: 0.72, b: 0.30)
        case .info: return Color(r: 0.40, g: 0.68, b: 0.95)
        case .hint: return Color(r: 0.60, g: 0.62, b: 0.68)
        }
    }

    var defaultGutterIcon: String {
        switch self {
        case .error: return "●"
        case .warning: return "▲"
        case .info: return "●"
        case .hint: return "·"
        }
    }

    /// Lower ranks first — the marker a row shows when more than one
    /// decoration lands on it.
    var rank: Int {
        switch self {
        case .error: return 0
        case .warning: return 1
        case .info: return 2
        case .hint: return 3
        }
    }
}

/// Underline drawn beneath a decorated range. `wavy` is built from short
/// zigzag segments — there is no dedicated curve primitive, and a handful of
/// `line()` calls per decorated span is cheap enough not to need one.
public enum DecorationUnderline: Sendable, Equatable {
    case none
    case straight
    case wavy
}

/// A diagnostic attached to a range of `EditorView`'s bound text.
///
/// `range` is character offsets (matching `TextEditingState`'s own indexing),
/// not `String.Index` — indices aren't `Sendable` or stable across edits,
/// offsets from a fresh parse always are.
public struct EditorDecoration: Sendable, Equatable {
    public var range: Range<Int>
    public var severity: DiagnosticSeverity
    public var underline: DecorationUnderline
    public var gutterIcon: String?
    public var color: Color?
    public var message: String?

    public init(
        range: Range<Int>,
        severity: DiagnosticSeverity = .error,
        underline: DecorationUnderline = .wavy,
        gutterIcon: String? = nil,
        color: Color? = nil,
        message: String? = nil
    ) {
        self.range = range
        self.severity = severity
        self.underline = underline
        self.gutterIcon = gutterIcon
        self.color = color
        self.message = message
    }

    var resolvedColor: Color { color ?? severity.defaultColor }
    var resolvedGutterIcon: String { gutterIcon ?? severity.defaultGutterIcon }
}

/// Where an editor was left: what it was scrolled to, and what was selected.
///
/// Character offsets rather than `String.Index`, because the point of saving
/// this is to restore it into a *different* buffer state — a document swapped
/// out and back, or a workspace reopened days later. An index into a string
/// that no longer exists is not a position, it is a crash waiting for the
/// wrong buffer; an offset is merely clamped.
public struct EditorPosition: Equatable, Sendable, Codable {
    public var scrollX: Float
    public var scrollY: Float
    /// Selection ends, in character offsets. Equal means a plain caret.
    public var anchor: Int
    public var focus: Int

    public init(scrollX: Float = 0, scrollY: Float = 0, anchor: Int = 0, focus: Int = 0) {
        self.scrollX = scrollX
        self.scrollY = scrollY
        self.anchor = anchor
        self.focus = focus
    }

    public static let start = EditorPosition()
}

/// A code editor: line-number gutter, current-line highlight, rule-based
/// syntax colouring, and find-match highlighting.
///
/// Everything about the *buffer* — cursor, selection, undo, wrapping, grapheme
/// correctness — is `TextEditingState`, unchanged and already tested. This
/// type is presentation plus a gutter, which is why it is a component rather
/// than a rewrite of `TextField`.
public final class EditorController {
    private var revealAction: ((Int) -> Bool)?
    private var captureAction: (() -> EditorPosition?)?
    private var replaceAction: (([Range<Int>], String) -> Int)?
    private var pendingLine: Int?
    private var pendingPosition: EditorPosition?

    public init() {}

    /// Select and reveal a one-based physical line. If the editor is not
    /// mounted yet (for example inside a collapsed disclosure), the request is
    /// retained and consumed when it mounts.
    public func reveal(line: Int) {
        let requested = max(1, line)
        if revealAction?(requested) == true {
            pendingLine = nil
        } else {
            pendingLine = requested
        }
    }

    /// Where the editor is right now, or nil if it is not mounted.
    public func position() -> EditorPosition? { captureAction?() }

    /// Replaces `ranges` — character offsets, as `TextSearch.matches` gives
    /// them — with `replacement`, and returns how many were applied. Zero if
    /// the editor is not mounted.
    ///
    /// This exists rather than leaving the app to rewrite the bound `String`
    /// itself, because doing it through the editor is what makes it *one*
    /// undo step, keeps the caret and the row table consistent with the new
    /// buffer, and redraws once instead of per match.
    ///
    /// Ranges must come from the buffer as it is now. A `TextSearch` from
    /// before an edit holds offsets into a document that no longer exists —
    /// re-run `find` first, which is what `TextSearch` is built to expect.
    @discardableResult
    public func replace(_ ranges: [Range<Int>], with replacement: String) -> Int {
        replaceAction?(ranges, replacement) ?? 0
    }

    /// Replaces the one match `search` currently sits on. `false` when there
    /// is no current match, or the editor is not mounted.
    @discardableResult
    public func replaceCurrent(_ search: TextSearch, with replacement: String) -> Bool {
        guard let current = search.current else { return false }
        return replace([current], with: replacement) == 1
    }

    /// Replaces every match `search` found. Returns how many.
    @discardableResult
    public func replaceAll(_ search: TextSearch, with replacement: String) -> Int {
        replace(search.matches, with: replacement)
    }

    /// Puts the editor back at `position` on its next reconcile.
    ///
    /// Deliberately never immediate. The caller for this is a document switch,
    /// and at the moment of the switch the editor still holds the *outgoing*
    /// buffer — applying an offset from the incoming one would clamp it against
    /// the wrong length and scroll the document being left. Deferring to the
    /// pass that installs the new text is the only point at which the position
    /// means what it says.
    public func restore(_ position: EditorPosition) {
        pendingPosition = position
        // A restore usually rides along with a model change that would rebuild
        // the body anyway. Asking for one regardless is what makes the call
        // stand on its own rather than quietly waiting for the next unrelated
        // frame that happens to reconcile this editor.
        ViewInvalidation.markNeedsBody()
    }

    fileprivate func install(
        reveal: @escaping (Int) -> Bool,
        capture: @escaping () -> EditorPosition?,
        restore: @escaping (EditorPosition) -> Bool,
        replace: @escaping ([Range<Int>], String) -> Int
    ) {
        revealAction = reveal
        captureAction = capture
        replaceAction = replace
        if let pendingPosition, restore(pendingPosition) {
            self.pendingPosition = nil
        }
        if let pendingLine, reveal(pendingLine) {
            self.pendingLine = nil
        }
    }
}

public struct EditorView: PrimitiveView {
    @Binding public var text: String
    public var rules: [HighlightRule]
    public var style: CodeStyle
    public var font: UIFont?
    public var showLineNumbers: Bool
    /// Break long lines to the box width instead of scrolling horizontally.
    ///
    /// Off by default, which is right for code and wrong for prose. A wrapped
    /// editor has no horizontal scroll at all, numbers logical lines rather
    /// than the rows it draws, and re-wraps the whole buffer whenever the text
    /// or the width changes — that last one is O(buffer) and shapes every
    /// line, so a multi-megabyte document is a real cost per keystroke where
    /// the same document costs nothing unwrapped.
    public var wraps: Bool
    public var visibleLines: Int
    public var search: TextSearch
    public var decorations: [EditorDecoration]
    /// Fired when the user clicks a decorated row's gutter icon, instead of
    /// the default "select the whole row" gutter click.
    public var onDecorationTap: ((EditorDecoration) -> Void)?
    public var controller: EditorController?

    public init(
        text: Binding<String>,
        rules: [HighlightRule] = [],
        style: CodeStyle = CodeStyle(),
        font: UIFont? = nil,
        showLineNumbers: Bool = true,
        wraps: Bool = false,
        visibleLines: Int = 12,
        search: TextSearch = TextSearch(),
        decorations: [EditorDecoration] = [],
        onDecorationTap: ((EditorDecoration) -> Void)? = nil,
        controller: EditorController? = nil
    ) {
        self._text = text
        self.rules = rules
        self.style = style
        self.font = font
        self.showLineNumbers = showLineNumbers
        self.wraps = wraps
        self.visibleLines = visibleLines
        self.search = search
        self.decorations = decorations
        self.onDecorationTap = onDecorationTap
        self.controller = controller
    }

    public var resolvedFont: UIFont? { font ?? Environment.current.font }

    public var dumpDetail: String {
        "\(text.split(separator: "\n").count) lines, \(rules.count) rules"
    }

    public func mountPrimitive() -> any AnyViewNode {
        let leaf = LeafNode(kind: .editor, label: "EditorView", width: .auto, height: .auto)
        leaf.editing = TextEditingState(text)
        leaf.seedLogicalRows()
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
            // Before `configure` reads the row count for the gutter, not after
            // the next layout pass — otherwise a buffer that just grew from 99
            // to 100 lines measures its gutter one digit short for a frame.
            leaf.seedLogicalRows()
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
        if leaf.wraps != wraps {
            // Rows are about to mean something different. Drop the staleness
            // marks both branches of `refreshVisualRows` keep, or the first
            // pass after the toggle sees the buffer as unchanged and keeps the
            // table built for the other mode.
            leaf.lastWrappedText = ""
            leaf.lastLogicalRowsText = nil
            leaf.lastMeasuredWidth = 0
            // Holds `Substring`s of the buffer it wrapped. Keeping them behind
            // an editor that is no longer wrapping would pin that buffer's
            // storage for as long as the leaf lives.
            leaf.wrapCacheLines = []
            leaf.wrapCacheRows = []
        }
        leaf.wraps = wraps
        leaf.highlighter = SyntaxHighlighter(rules: rules)
        leaf.codeStyle = style
        leaf.showsGutter = showLineNumbers
        leaf.search = search
        leaf.text = leaf.editing.text
        leaf.minWidth = 160
        // Over the whole box, gutter included: the gutter is part of the
        // editor's own click behaviour (it selects a row), not a separate
        // surface, so switching the pointer there would say otherwise.
        leaf.cursor = .text
        leaf.decorations = decorations
        leaf.onDecorationTap = onDecorationTap

        let binding = _text
        controller?.install(
            reveal: { [weak leaf] line in
                guard let leaf, let font = leaf.font ?? FontStore.default else { return false }
                leaf.revealPhysicalLine(line, font: font)
                leaf.focusSelf(binding: binding, onSubmit: nil)
                CaretBlink.noteEdit()
                ViewInvalidation.markNeedsRedraw()
                return true
            },
            capture: { [weak leaf] in leaf?.editorPosition() },
            restore: { [weak leaf] position in
                guard let leaf else { return false }
                leaf.apply(position)
                return true
            },
            replace: { [weak leaf] ranges, replacement in
                guard let leaf else { return 0 }
                let applied = leaf.editing.replaceAll(ranges, with: replacement)
                guard applied > 0 else { return 0 }
                // The edit cleared the row table (see `TextEditingState`), and
                // the gutter reads it before the next measure pass runs.
                leaf.seedLogicalRows()
                leaf.markMeasureDirty()
                binding.wrappedValue = leaf.editing.text
                CaretBlink.noteEdit()
                ViewInvalidation.markDirty()
                return applied
            }
        )

        // Height is decided by the measure callback from the row count, so
        // the box always matches what is drawn.
        leaf.maxLines = visibleLines
        if let f = resolvedFont {
            leaf.gutterWidth = showLineNumbers ? leaf.measuredGutterWidth(font: f) : 0
        }

        leaf.isScrollable = true
        // Wheel scrolls three rows a notch, the usual desktop feel.
        ScrollRouter.register(
            leaf.id,
            canScroll: { [weak leaf] dx, dy in
                leaf?.editorCanScroll(dx: dx, dy: dy) ?? false
            }
        ) { [weak leaf] dx, dy in
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

        leaf.onClickLocal = { [weak leaf] localX, localY, originX, originY, _, _ in
            guard let leaf else { return }
            leaf.focusSelf(binding: binding, onSubmit: nil)
            // Clicks in the gutter select the whole line, as they do in every
            // editor with one — unless the row is decorated and the app
            // wants to hear about that instead.
            if leaf.showsGutter, localX < leaf.gutterWidth {
                if let deco = leaf.decoration(atLocalY: localY), let onTap = leaf.onDecorationTap {
                    onTap(deco)
                } else {
                    leaf.selectRow(atLocalY: localY)
                }
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
                                // Selection lives on the retained node, not
                                // the bound text — `.body` here meant every
                                // pointer-move of a drag-select re-ran
                                // whatever the bound text drives (for
                                // TraceLoom, a full reparse of the buffer
                                // being selected *from*).
                                ViewInvalidation.markNeedsRedraw()
                            }
                        }
                    )
                }
            }
            CaretBlink.noteEdit()
            ViewInvalidation.markNeedsRedraw()
        }
    }
}

extension LeafNode {
    /// Scroll offsets and selection, as `EditorController.position()` reports
    /// them.
    func editorPosition() -> EditorPosition {
        // `charOffset` is anchored, so the second call walks only the distance
        // between the two ends rather than back to the start of the buffer.
        EditorPosition(
            scrollX: scrollX,
            scrollY: scrollY,
            anchor: charOffset(of: editing.anchor),
            focus: charOffset(of: editing.focus)
        )
    }

    /// Puts the editor back where `editorPosition()` found it, clamped to the
    /// buffer that is there now — which is not necessarily the one it came
    /// from, and after an external edit is not even the same length.
    func apply(_ position: EditorPosition) {
        // The row table's last upper bound is the character count, already
        // computed. `editing.text.count` would walk the whole buffer for a
        // number we are holding.
        let total = editing.layout.rows.last?.upperBound ?? 0
        let anchor = min(max(0, position.anchor), total)
        let focus = min(max(0, position.focus), total)

        let anchorIndex = textIndex(atOffset: anchor)
        editing.setCursor(anchorIndex)
        if focus != anchor {
            editing.setCursor(textIndex(atOffset: focus), extending: true)
        }

        if let font = font ?? FontStore.default {
            scrollY = min(max(0, position.scrollY), maxScrollY(lineHeight: font.lineHeight))
            scrollX = min(max(0, position.scrollX), maxScrollX(font: font))
        } else {
            scrollY = max(0, position.scrollY)
            scrollX = max(0, position.scrollX)
        }
        ViewInvalidation.markNeedsRedraw()
    }

    /// Selects and centers a one-based logical line.
    ///
    /// Logical, not the row the editor happens to draw: with wrapping on,
    /// "line 400" is a line of the file, and the row it starts at is wherever
    /// the 399 above it happened to break.
    func revealPhysicalLine(_ line: Int, font: UIFont) {
        let rows = editing.layout.rows
        guard !rows.isEmpty else { return }
        let row = max(0, min(rows.count - 1, firstRow(ofLine: line - 1)))
        let range = logicalLineRange(ofRow: row)
        editing.setCursor(editing.index(atOffset: range.lowerBound))
        let end = min(range.upperBound + 1, editing.text.count)
        editing.setCursor(editing.index(atOffset: end), extending: true)

        let visibleHeight = viewportHeight > 0
            ? max(font.lineHeight, viewportHeight - textInset * 2)
            : Float(max(1, maxLines)) * font.lineHeight
        let target = Float(row) * font.lineHeight
            - max(0, (visibleHeight - font.lineHeight) / 2)
        let contentHeight = Float(rows.count) * font.lineHeight
        scrollY = min(max(0, target), max(0, contentHeight - visibleHeight))
        scrollX = 0
    }

    /// Gutter wide enough for the highest line number, plus breathing room.
    /// Sized from the digit count so it does not jitter as the caret moves.
    ///
    /// Counted off the row table rather than `editing.lines`: the gutter
    /// numbers *are* the rows, and `lines` re-splits the whole buffer on every
    /// access. `configure` calls this on every mount and reconcile, so on a
    /// 10 MB log that split was ~200ms of the body pass each time the editor
    /// appeared. `seedLogicalRows` is what guarantees the table exists here,
    /// on the mount that runs before any layout pass.
    func measuredGutterWidth(font: UIFont) -> Float {
        let digits = max(2, String(max(1, logicalLineCount)).count)
        let sample = String(repeating: "0", count: digits)
        return font.shapedRun(sample).width + textInset * 3
    }

    /// Selects the whole logical line under `localY` — the gutter-click
    /// gesture. The gutter numbers lines, so clicking one selects a line, even
    /// where that line is drawn across several wrapped rows.
    func selectRow(atLocalY localY: Float) {
        let y = localY + scrollY
        guard let f = font ?? FontStore.default else { return }
        let rows = editing.layout.rows
        let row = max(0, min(rows.count - 1, Int((y - textInset) / f.lineHeight)))
        let r = logicalLineRange(ofRow: row)
        editing.setCursor(editing.index(atOffset: r.lowerBound))
        // Include the newline so a pasted replacement keeps the line structure.
        let end = min(r.upperBound + 1, editing.text.count)
        editing.setCursor(editing.index(atOffset: end), extending: true)
    }

    /// The decoration whose row is under `localY`, if any — same row math as
    /// `selectRow`, so a gutter click resolves to the same line either way.
    func decoration(atLocalY localY: Float) -> EditorDecoration? {
        guard !decorations.isEmpty else { return nil }
        let y = localY + scrollY
        guard let f = font ?? FontStore.default else { return nil }
        let rows = editing.layout.rows
        guard !rows.isEmpty else { return nil }
        let row = max(0, min(rows.count - 1, Int((y - textInset) / f.lineHeight)))
        let range = rows[row]
        return decorations.first { $0.range.overlaps(range) }
    }
}
