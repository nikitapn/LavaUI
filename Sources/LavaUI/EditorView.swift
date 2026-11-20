import Foundation

/// Style palette for `EditorView`. Rules carry style *indices*; this maps them
/// to colours, so a theme change restyles code without touching any rule.
public struct CodeStyle {
    /// Colour of text no rule matched.
    public var text: Color
    /// Colour of the line numbers.
    public var gutterText: Color
    /// Fill behind the line-number gutter.
    public var gutterBackground: Color
    /// Fill behind the line the caret is on.
    public var currentLine: Color
    /// Fill behind every search match.
    public var searchMatch: Color
    /// Fill behind the search match the search is currently on.
    public var currentSearchMatch: Color
    /// Indexed by `HighlightRule.styleIndex`; out-of-range falls back to `text`.
    public var palette: [Color]
    /// Number colour for the caret's logical line. Also extends its highlight across the gutter.
    public var activeGutterText: Color?
    /// Optional emphasized face for the caret's line number.
    public var activeGutterFont: UIFont?
    /// Minimum width for a visible gutter, in points.
    public var minimumGutterWidth: Float = 0
    /// Custom indicator paint. Geometry and drag behavior are shared with the standard scrollbar.
    public var scrollbarColor: Color?
    public var scrollbarWidth: Float = 4
    /// Extends the horizontal scrollbar across the gutter.
    public var scrollbarSpansGutter = false
    /// Hint painted over an empty buffer.
    public var placeholder: String?

    /// Creates a palette. Colours left `nil` come from the current theme, apart
    /// from the two search fills, which have fixed amber defaults.
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
        self.gutterBackground = gutterBackground ?? theme.canvas
        self.currentLine = currentLine ?? theme.background
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
    /// Something is wrong: red, with a dot in the gutter.
    case error
    /// Something may be wrong: amber, with a triangle.
    case warning
    /// Worth knowing: blue, with a dot.
    case info
    /// A suggestion: grey, with a small dot.
    case hint

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
    /// No underline; the gutter icon and colour still show.
    case none
    /// A straight line under the range.
    case straight
    /// A zigzag line under the range, as spell checkers and compilers draw.
    case wavy
}

/// A diagnostic attached to a range of `EditorView`'s bound text.
///
/// `range` is character offsets (matching `TextEditingState`'s own indexing),
/// not `String.Index` — indices aren't `Sendable` or stable across edits,
/// offsets from a fresh parse always are.
public struct EditorDecoration: Sendable, Equatable {
    /// The decorated characters, as character offsets into the editor's text.
    public var range: Range<Int>
    /// How serious it is. Decides the default colour and gutter icon and, when
    /// several decorations share a row, which one the gutter shows.
    public var severity: DiagnosticSeverity
    /// How the range is underlined.
    public var underline: DecorationUnderline
    /// Text drawn in the gutter of the range's first row, or `nil` for the severity's default.
    public var gutterIcon: String?
    /// Colour of the underline and gutter icon, or `nil` for the severity's default.
    public var color: Color?
    /// The diagnostic's text. The editor does not draw it; it is for the app, for
    /// instance in `onDecorationTap`.
    public var message: String?

    /// Creates a decoration. `nil` colour and icon take the severity's defaults.
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
    /// Horizontal scroll offset, in pixels.
    public var scrollX: Float
    /// Vertical scroll offset, in pixels. A `Double` because it is a document
    /// coordinate, and a long wrapped log outgrows a `Float`'s whole pixels.
    public var scrollY: Double
    /// Selection ends, in character offsets. Equal means a plain caret.
    public var anchor: Int
    /// The end of the selection the caret is at. See `anchor`.
    public var focus: Int

    /// Text at the top of the viewport, retained across wrapping or font changes.
    /// Optional so positions saved by older versions still decode.
    public var topOffset: Int?
    /// How far through the top visual row the viewport begins (0..<1).
    public var topFraction: Float?

    /// Creates a position. The default is the top of the buffer with the caret at 0.
    public init(scrollX: Float = 0, scrollY: Double = 0, anchor: Int = 0, focus: Int = 0,
                topOffset: Int? = nil, topFraction: Float? = nil) {
        self.scrollX = scrollX
        self.scrollY = scrollY
        self.anchor = anchor
        self.focus = focus
        self.topOffset = topOffset
        self.topFraction = topFraction
    }

    /// The top of the buffer, caret at the first character, nothing selected.
    public static let start = EditorPosition()
}

/// Commands for a mounted `EditorView`: reveal a line or range, read and
/// restore its position, replace search matches.
///
/// Create one, keep it (in `@State` or a model), and pass it to the view's
/// `controller:`. Calls made while no editor is mounted return `nil`, `false`
/// or zero — except `reveal(line:)` and `restore(_:)`, which wait for one.
public final class EditorController {
    private var revealAction: ((Int) -> Bool)?
    private var revealRangeAction: ((Range<Int>) -> Bool)?
    private var captureAction: (() -> EditorPosition?)?
    private var replaceAction: (([Range<Int>], String) -> Int)?
    private var metricsAction: ((String?) -> (bytes: Int, lines: Int)?)?
    private var caretLineAction: (() -> Int?)?
    private var focusAction: (() -> Void)?
    private var pendingLine: Int?
    private var pendingPosition: EditorPosition?

    /// Creates a controller that is not yet attached to any editor.
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

    /// Selects a character range and scrolls it into view.
    ///
    /// The reason this is not `restore(_:)` with the offsets filled in: an
    /// `EditorPosition` carries a scroll offset, so restoring one moves the
    /// selection to somewhere the editor is not looking. That is right for
    /// coming back to a document — the whole point is to land where you were —
    /// and wrong for a search hit, where the caller knows the offsets and has
    /// no idea what scroll they correspond to. Only the editor can answer that,
    /// because only the editor knows how the text is currently broken into
    /// rows.
    ///
    /// Immediate rather than deferred, and false when the editor is not
    /// mounted — a caller stepping through matches wants to know.
    @discardableResult
    public func reveal(range: Range<Int>) -> Bool {
        revealRangeAction?(range) ?? false
    }

    /// Where the editor is right now, or nil if it is not mounted.
    public func position() -> EditorPosition? { captureAction?() }

    /// One-based logical line at the active end of the selection.
    public func caretLine() -> Int? { caretLineAction?() }

    /// Returns keyboard focus to the editor without moving the caret.
    public func focus() { focusAction?() }

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

    /// How many logical lines the mounted editor is showing, and how many
    /// bytes that answer was taken from.
    ///
    /// For a status bar. The editor has counted the lines already — it needs
    /// the same number for the gutter — and a caller that recounts is scanning
    /// a multi-megabyte buffer to learn something a few pointers away. The
    /// caller can supply its text to detect an outgoing buffer still mounted
    /// during a document switch.
    ///
    /// Nil when no editor is mounted.
    public func metrics(forText text: String? = nil) -> (bytes: Int, lines: Int)? {
        metricsAction?(text)
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
        revealRange: @escaping (Range<Int>) -> Bool,
        capture: @escaping () -> EditorPosition?,
        restore: @escaping (EditorPosition) -> Bool,
        replace: @escaping ([Range<Int>], String) -> Int,
        metrics: @escaping (String?) -> (bytes: Int, lines: Int)?,
        caretLine: @escaping () -> Int?,
        focus: @escaping () -> Void
    ) {
        revealAction = reveal
        revealRangeAction = revealRange
        captureAction = capture
        replaceAction = replace
        metricsAction = metrics
        caretLineAction = caretLine
        focusAction = focus
        if let pendingPosition, restore(pendingPosition) {
            self.pendingPosition = nil
        }
        if let pendingLine, reveal(pendingLine) {
            self.pendingLine = nil
        }
    }
}

/// Whole lines an app wants marked: a bar down the gutter, a fill behind the
/// text, or both — what a gutter shows for lines changed since the last
/// commit, or a run of lines a tool wants to point at.
///
/// Lines rather than `EditorDecoration`'s character range because what is
/// marked is the line, not text on it: a fill reaches the right edge however
/// short the line is, and a wrapped line is marked on every row it takes.
public struct EditorLineMark: Sendable, Equatable {
    /// Logical lines, from 0. Empty marks the gap *above* `lines.lowerBound`
    /// — where lines were removed — with a short notch across the gutter
    /// instead of a bar; at the line count, below the last line.
    public var lines: Range<Int>
    /// Colour of the bar at the gutter's inner edge, or `nil` for none.
    public var bar: Color?
    /// Colour behind the marked lines' text, or `nil` for none. Wins over the
    /// current-line highlight; the caret's line number still shows which it is.
    public var fill: Color?

    /// Creates a mark. Every parameter matches the property of the same name.
    public init(lines: Range<Int>, bar: Color? = nil, fill: Color? = nil) {
        self.lines = lines
        self.bar = bar
        self.fill = fill
    }
}

/// A code editor: line-number gutter, current-line highlight, rule-based
/// syntax colouring, and find-match highlighting.
///
/// Everything about the *buffer* — cursor, selection, undo, wrapping, grapheme
/// correctness — is `TextEditingState`, unchanged and already tested. This
/// type is presentation plus a gutter, which is why it is a component rather
/// than a rewrite of `TextField`.
extension EditorView {
    /// Seconds a frame may spend wrapping lines it does not show yet, once the
    /// lines it does show are wrapped. A soft-wrapped editor breaks what is on
    /// screen at once and the rest of the document over the frames after it,
    /// this much per frame (4 ms by default).
    ///
    /// For benchmarks: the share of the document one frame gets through then
    /// depends on how fast the machine is, so a count of lines wrapped is
    /// only reproducible with this pinned — 0 for exactly the frame a user
    /// waits on, `.infinity` to wrap the whole document in one pass.
    public static var softWrapFrameBudget: Double {
        get { LeafNode.wrapBudget }
        set { LeafNode.wrapBudget = newValue }
    }
}

public struct EditorView: PrimitiveView {
    /// The text being edited.
    @Binding public var text: String
    /// Allows selection, copying and navigation while preventing text changes.
    public var isReadOnly: Bool
    /// Syntax colouring rules, applied per line. Each rule's `styleIndex` picks a colour from `style.palette`.
    public var rules: [HighlightRule]
    /// Colours for text, gutter, current line and search matches.
    public var style: CodeStyle
    /// The editor's font, or `nil` for the environment's.
    public var font: UIFont?
    /// Whether to draw the line-number gutter.
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
    /// Most lines the editor grows to show before it scrolls. Layout can give it less.
    public var visibleLines: Int
    /// The find state whose matches are highlighted.
    public var search: TextSearch
    /// Diagnostics to underline and mark in the gutter.
    public var decorations: [EditorDecoration]
    /// Whole lines to mark with a gutter bar or a fill. See `EditorLineMark`.
    public var lineMarks: [EditorLineMark]
    /// Fired when the user clicks a decorated row's gutter icon, instead of
    /// the default "select the whole row" gutter click.
    public var onDecorationTap: ((EditorDecoration) -> Void)?
    /// Ctrl+wheel notches, consumed even when the document cannot scroll.
    public var onZoom: ((Float) -> Void)?
    /// Handle for revealing lines, restoring positions and replacing matches.
    public var controller: EditorController?

    /// Creates an editor bound to `text`. Every parameter matches the property of the same name.
    public init(
        text: Binding<String>,
        isReadOnly: Bool = false,
        rules: [HighlightRule] = [],
        style: CodeStyle = CodeStyle(),
        font: UIFont? = nil,
        showLineNumbers: Bool = true,
        wraps: Bool = false,
        visibleLines: Int = 12,
        search: TextSearch = TextSearch(),
        decorations: [EditorDecoration] = [],
        lineMarks: [EditorLineMark] = [],
        onDecorationTap: ((EditorDecoration) -> Void)? = nil,
        controller: EditorController? = nil,
        onZoom: ((Float) -> Void)? = nil
    ) {
        self._text = text
        self.isReadOnly = isReadOnly
        self.rules = rules
        self.style = style
        self.font = font
        self.showLineNumbers = showLineNumbers
        self.wraps = wraps
        self.visibleLines = visibleLines
        self.search = search
        self.decorations = decorations
        self.lineMarks = lineMarks
        self.onDecorationTap = onDecorationTap
        self.controller = controller
        self.onZoom = onZoom
    }

    /// The font the editor draws with: `font`, or the environment's when that is `nil`.
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
        let previousFont = leaf.font ?? FontStore.default
        let nextFont = resolvedFont ?? FontStore.default
        let fontChanged = previousFont?.identity != nextFont?.identity
        if fontChanged, let previousFont, previousFont.lineHeight > 0 {
            let rowPosition = max(0, leaf.scrollY / Double(previousFont.lineHeight))
            let rows = leaf.editing.layout.rows
            let row = min(Int(rowPosition), rows.count - 1)
            leaf.pendingFontAnchor = (rows[row].lowerBound, Float(rowPosition - Double(row)))
            if let nextFont {
                leaf.scrollX *= nextFont.pixelSize / previousFont.pixelSize
            }
        }
        leaf.font = resolvedFont
        leaf.color = style.text
        leaf.fillColor = theme.inset
        leaf.isReadOnly = isReadOnly
        leaf.isMultiline = true
        if leaf.wraps != wraps || fontChanged {
            // Before anything is cleared: `rowLogicalLine` still describes the
            // mode being left, and it is the only thing that can say which
            // line the reader is looking at.
            if let f = previousFont, f.lineHeight > 0 {
                leaf.pendingTopLine =
                    leaf.logicalLine(ofRow: max(0, leaf.row(atScreenY: 0, lineHeight: f.lineHeight)))
            }
            // Rows are about to mean something different. Drop the staleness
            // marks both branches of `refreshVisualRows` keep, or the first
            // pass after the toggle sees the buffer as unchanged and keeps the
            // table built for the other mode.
            leaf.lastWrappedText = ""
            leaf.lastLogicalRowsText = nil
            leaf.lastMeasuredWidth = 0
            // The plan describes rows this editor no longer has, and holds a
            // line table for a buffer it may never look at again.
            leaf.wrapCacheRows = []
            // And the rows-per-line estimate made for them: a new font fits a
            // different number of characters in the same width.
            leaf.wrapInner = 0
            leaf.wrapPerRow = 0
            leaf.wrapPlanText = ""
            leaf.wrapMeasured = []
            leaf.wrapUnmeasured = 0
            leaf.wrapCursor = 0
            leaf.logicalLineIndex = LineIndex()
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
        // Sorted once here so the paint can binary-search a screenful of rows.
        leaf.lineMarks = lineMarks.sorted { $0.lines.lowerBound < $1.lines.lowerBound }
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
            revealRange: { [weak leaf] range in
                guard let leaf, let font = leaf.font ?? FontStore.default else { return false }
                leaf.revealRange(range, font: font)
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
                guard let leaf, !leaf.isReadOnly else { return 0 }
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
            },
            metrics: { [weak leaf] text in
                guard let leaf, text == nil || text == leaf.editing.text else { return nil }
                return (leaf.editing.text.utf8.count, leaf.logicalLineCount)
            },
            caretLine: { [weak leaf] in
                leaf.map { $0.logicalLine(ofRow: $0.focusRow()) + 1 }
            },
            focus: { [weak leaf] in
                leaf?.focusSelf(binding: binding, onSubmit: nil)
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
                if ScrollRouter.controlHeld, onZoom != nil, dy != 0 { return true }
                return leaf?.editorCanScroll(dx: dx, dy: dy) ?? false
            }
        ) { [weak leaf] dx, dy in
            if ScrollRouter.controlHeld, let onZoom, dy != 0 {
                onZoom(dy)
                return
            }
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
            // Before anything else: the bars are painted over the text, so a
            // press on one has to be read that way too. Without this, grabbing
            // the thumb would put the caret behind it.
            if leaf.beginScrollbarDrag(
                localX: localX, localY: localY, originX: originX, originY: originY
            ) {
                ViewInvalidation.markNeedsRedraw()
                return
            }
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
                localY: Double(localY) + leaf.scrollY
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
                            let ly = Double(wy - originY) + leaf.scrollY
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
        let height = (font ?? FontStore.default)?.lineHeight ?? 1
        let rowPosition = max(0, scrollY / Double(max(1, height)))
        let rows = editing.layout.rows
        let row = min(Int(rowPosition), max(0, rows.count - 1))
        // Through the caches the draw path keeps, not `charOffset`. LavaEditor
        // asks for this after every emit, scrolls included, and `charOffset`
        // measures from the leaf's one index anchor — which the emitter keeps
        // at the first visible row. With the caret at the top of a 200 MB log
        // and the view at its end, that was a walk of the whole buffer to the
        // caret and, the anchor having followed it, another back on the next
        // frame. The caches answer for a caret that has not moved without
        // touching the anchor at all.
        let focus = focusOffset()
        let anchor: Int
        if editing.anchor == editing.focus {
            anchor = focus
        } else if let ends = selectionOffsets(editing.selectedRange) {
            anchor = editing.anchor == editing.selectedRange.lowerBound ? ends.from : ends.to
        } else {
            anchor = charOffset(of: editing.anchor)
        }
        return EditorPosition(
            scrollX: scrollX,
            scrollY: scrollY,
            anchor: anchor,
            focus: focus,
            topOffset: rows.isEmpty ? 0 : rows[row].lowerBound,
            topFraction: Float(rowPosition - rowPosition.rounded(.down))
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

        // The new buffer has not been laid out yet. Clamping against the old
        // row table here loses positions below its bottom; emit clamps later.
        scrollY = position.scrollY.isFinite ? max(0, position.scrollY) : 0
        scrollX = position.scrollX.isFinite ? max(0, position.scrollX) : 0
        pendingTopLine = nil
        pendingFontAnchor = nil
        if let offset = position.topOffset {
            let fraction = position.topFraction ?? 0
            pendingFontAnchor = (min(max(0, offset), total),
                                 fraction.isFinite ? min(0.999, max(0, fraction)) : 0)
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
        let target = documentY(ofRow: row, lineHeight: font.lineHeight)
            - Double(max(0, (visibleHeight - font.lineHeight) / 2))
        let contentHeight = documentY(ofRow: rows.count, lineHeight: font.lineHeight)
        scrollY = min(max(0, target), max(0, contentHeight - Double(visibleHeight)))
        scrollX = 0
    }

    /// Selects `range` and brings it on screen, vertically and horizontally.
    ///
    /// Centred like `revealPhysicalLine` when it is off screen, and left alone
    /// when it is already visible: a find-next walking down a screenful of
    /// matches should not re-centre the view on each one, which reads as the
    /// text jumping under a search that is barely moving.
    func revealRange(_ range: Range<Int>, font: UIFont) {
        let rows = editing.layout.rows
        guard !rows.isEmpty else { return }
        let total = rows.last?.upperBound ?? 0
        let from = max(0, min(range.lowerBound, total))
        let to = max(from, min(range.upperBound, total))

        editing.setCursor(textIndex(atOffset: from))
        if to != from { editing.setCursor(textIndex(atOffset: to), extending: true) }

        let row = editing.layout.rowIndex(ofOffset: from)
        let rowY = screenY(ofRow: row, lineHeight: font.lineHeight)
        let visible = viewportHeight > 0
            ? max(font.lineHeight, viewportHeight - textInset * 2)
            : Float(max(1, maxLines)) * font.lineHeight
        if rowY < 0 || rowY + font.lineHeight > visible {
            let target = documentY(ofRow: row, lineHeight: font.lineHeight)
                - Double(max(0, (visible - font.lineHeight) / 2))
            let contentHeight = documentY(ofRow: rows.count, lineHeight: font.lineHeight)
            scrollY = min(max(0, target), max(0, contentHeight - Double(visible)))
        }
        // A match far along a very long line is invisible without this, and a
        // no-wrap editor is exactly where that happens.
        scrollToCaretX(font: font)
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
        let digitWidth = max(font.shapedRun(sample).width,
                             codeStyle?.activeGutterFont?.shapedRun(sample).width ?? 0)
        return max(codeStyle?.minimumGutterWidth ?? 0, digitWidth + textInset * 3)
    }

    /// Selects the whole logical line under `localY` — the gutter-click
    /// gesture. The gutter numbers lines, so clicking one selects a line, even
    /// where that line is drawn across several wrapped rows.
    func selectRow(atLocalY localY: Float) {
        guard let f = font ?? FontStore.default else { return }
        let rows = editing.layout.rows
        let row = max(0, min(rows.count - 1, self.row(atScreenY: localY - textInset, lineHeight: f.lineHeight)))
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
        guard let f = font ?? FontStore.default else { return nil }
        let rows = editing.layout.rows
        guard !rows.isEmpty else { return nil }
        let row = max(0, min(rows.count - 1, self.row(atScreenY: localY - textInset, lineHeight: f.lineHeight)))
        let range = rows[row]
        return decorations.first { $0.range.overlaps(range) }
    }
}
