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
    /// Indexed by `HighlightRule.styleIndex`, for a caller whose indices are
    /// its own positions. Takes precedence over `colors` for the indices it
    /// covers.
    public var palette: [Color]
    /// Colours by `HighlightName` — `keyword`, `function.method` — for spans
    /// whose index is a name. A name with no colour takes its parent's
    /// (`function.method` → `function`), and one with no coloured ancestor is
    /// `text`: a theme colours what it means to and nothing else.
    public var colors: [String: Color] {
        didSet { resolution = Resolution(colors) }
    }
    /// `colors` resolved per name index, so the draw path's lookup is one
    /// array read. Shared by copies of this style and owned by the colours
    /// it was made from: setting `colors` starts a new one.
    private var resolution: Resolution
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
    /// Behind blank rows (`EditorView(lineGaps:)`), or the gutter's colour
    /// when nil.
    public var gapFill: Color?
    /// Diagonal hatching over blank rows, or none when nil.
    public var gapStripe: Color?

    /// Creates a palette. Colours left `nil` come from the current theme, apart
    /// from the two search fills, which have fixed amber defaults.
    public init(
        text: Color = .primary,
        gutterText: Color? = nil,
        gutterBackground: Color? = nil,
        currentLine: Color? = nil,
        searchMatch: Color? = nil,
        currentSearchMatch: Color? = nil,
        palette: [Color] = [],
        colors: [String: Color] = [:]
    ) {
        let theme = Environment.current.theme
        self.text = text
        self.gutterText = gutterText ?? theme.textSecondary
        self.gutterBackground = gutterBackground ?? theme.canvas
        self.currentLine = currentLine ?? theme.background
        self.searchMatch = searchMatch ?? Color(r: 0.45, g: 0.40, b: 0.15)
        self.currentSearchMatch = currentSearchMatch ?? Color(r: 0.70, g: 0.55, b: 0.15)
        self.palette = palette
        self.colors = colors
        resolution = Resolution(colors)
    }

    func color(for styleIndex: Int) -> Color {
        if palette.indices.contains(styleIndex) { return palette[styleIndex] }
        guard !colors.isEmpty, styleIndex >= 0 else { return text }
        return resolution.color(at: styleIndex, in: colors) ?? text
    }

    /// Colours by name index, grown when a span carries a name registered
    /// after the last growth — a language server's `function.method`, a
    /// query capture met for the first time — so each name is resolved once,
    /// not on every span of every frame. Drawing is on the main thread, and
    /// so is every call here.
    private final class Resolution: @unchecked Sendable {
        private var colors: [Color?] = []

        init(_ table: [String: Color]) {
            // A themed name is registered now, so it is resolved up front
            // even if nothing has produced it yet.
            for name in table.keys { _ = HighlightName.index(of: name) }
        }

        func color(at index: Int, in table: [String: Color]) -> Color? {
            if index >= colors.count {
                let count = HighlightName.count
                guard index < count else { return nil }
                colors += (colors.count..<count).map { index in
                    HighlightName.name(at: index).flatMap { Self.color(named: $0, in: table) }
                }
            }
            return colors[index]
        }

        private static func color(named name: String, in table: [String: Color]) -> Color? {
            for candidate in HighlightName.fallbacks(of: name) {
                if let color = table[String(candidate)] { return color }
            }
            return nil
        }
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
    private var caretOffsetAction: (() -> Int?)?
    private var insertAction: ((String, Range<Int>, Int?) -> Bool)?
    private var linePrefixAction: ((Int) -> String?)?
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

    /// Character offset of the caret — the active end of the selection.
    public func caretOffset() -> Int? { caretOffsetAction?() }

    /// Replaces `range` with `text` as one undoable edit: accepting a
    /// completion. The caret goes `caretAt` characters into the inserted text,
    /// or after it. False when not mounted or read-only.
    @discardableResult
    public func insert(_ text: String, replacing range: Range<Int>, caretAt: Int? = nil) -> Bool {
        insertAction?(text, range, caretAt) ?? false
    }

    /// Up to `maxCharacters` before the caret, stopping at the start of its
    /// line: the word being typed, without walking a large buffer from its
    /// start on every keystroke.
    public func linePrefix(maxCharacters: Int = 80) -> String? {
        linePrefixAction?(maxCharacters)
    }

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
        caretOffset: @escaping () -> Int?,
        insert: @escaping (String, Range<Int>, Int?) -> Bool,
        linePrefix: @escaping (Int) -> String?,
        focus: @escaping () -> Void
    ) {
        caretOffsetAction = caretOffset
        insertAction = insert
        linePrefixAction = linePrefix
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

/// An action beside a logical line. The gutter and inline label invoke the same handler.
public struct EditorLineAction {
    public let gutterPlay: Bool
    public let hint: String
    public let perform: () -> Void
    public init(gutterPlay: Bool, hint: String, perform: @escaping () -> Void) {
        self.gutterPlay = gutterPlay
        self.hint = hint
        self.perform = perform
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
    /// A character drawn after the line number — a diff's `+` or `−` — in
    /// `bar`'s colour, or the gutter's when there is no bar.
    public var sign: String?

    /// Creates a mark. Every parameter matches the property of the same name.
    public init(lines: Range<Int>, bar: Color? = nil, fill: Color? = nil, sign: String? = nil) {
        self.lines = lines
        self.bar = bar
        self.fill = fill
        self.sign = sign
    }
}

/// Blank rows above a line: room an editor leaves for lines it does not have,
/// so a line stays beside its counterpart in another editor — a side-by-side
/// diff's filler. Not text: no number, no caret, and a click on one lands on
/// the line below.
public struct EditorLineGap: Sendable, Equatable {
    /// The logical line the rows go above, from 0. The line count puts them
    /// below the last line.
    public var line: Int
    /// How many rows.
    public var rows: Int

    public init(line: Int, rows: Int) {
        self.line = line
        self.rows = rows
    }
}

/// A background behind a run of characters — a diff's changed words.
/// Drawn under the selection and search matches.
public struct EditorRangeFill: Sendable, Equatable {
    /// Character offsets into the editor's text.
    public var range: Range<Int>
    public var color: Color

    public init(range: Range<Int>, color: Color) {
        self.range = range
        self.color = color
    }
}

/// Where an editor's text, selection and undo history live.
final class EditingSlot {
    var state: TextEditingState
    /// Whether anything has been put here yet — a new slot's state is an
    /// empty placeholder, not a document.
    var isFilled = false

    init(_ state: TextEditingState = TextEditingState("")) { self.state = state }
}

/// Editing state kept per document rather than per editor: undo history,
/// caret and selection survive switching an editor to another document and
/// back, and being shown by a different editor (a diff's, then the main
/// one) — an editor given `stateStore` and a `stateKey` picks up whatever
/// the store holds for that key, provided its text still matches.
///
/// The app owns it and calls `forget` when a document closes; otherwise a
/// document's history is kept for as long as the store is.
public final class EditorStateStore {
    private var slots: [AnyHashable: EditingSlot] = [:]

    public init() {}

    func slot(for key: AnyHashable) -> EditingSlot {
        if let slot = slots[key] { return slot }
        let slot = EditingSlot()
        slots[key] = slot
        return slot
    }

    /// Drops what is kept for `key`.
    public func forget(_ key: AnyHashable) {
        slots[key] = nil
    }

    /// Drops everything kept for keys not in `keys`.
    public func retain(_ keys: Set<AnyHashable>) {
        slots = slots.filter { keys.contains($0.key) }
    }

    /// Whether `key` has undo history kept, for tests and menus.
    public func canUndo(_ key: AnyHashable) -> Bool {
        slots[key]?.state.canUndo ?? false
    }
}

/// Editors that scroll together: give two `EditorView`s the same link and a
/// scroll of either — wheel, scrollbar, caret, `reveal` — moves both, on
/// both axes. Their content should be the same height, which is what
/// `lineGaps` are for; each still clamps to its own.
///
/// A reference the app keeps for as long as the editors are shown; it holds
/// the editors weakly.
public final class EditorScrollLink {
    private var members: [Weak] = []
    private var applying = false

    private struct Weak { weak var leaf: LeafNode? }

    public init() {}

    func join(_ leaf: LeafNode) {
        members.removeAll { $0.leaf == nil || $0.leaf === leaf }
        // A newcomer takes the offset the others already have, so a pane
        // that is rebuilt does not jump its partner back to the top.
        if let other = members.first?.leaf {
            applying = true
            leaf.scrollY = other.scrollY
            leaf.scrollX = other.scrollX
            applying = false
        }
        members.append(Weak(leaf: leaf))
    }

    func leave(_ leaf: LeafNode) {
        members.removeAll { $0.leaf == nil || $0.leaf === leaf }
    }

    /// Runs `body` without passing on what it does to the offsets.
    func quietly(_ body: () -> Void) {
        let was = applying
        applying = true
        body()
        applying = was
    }

    /// The widest row of any member, for a horizontal range they share.
    func widestRow(font: UIFont) -> Float {
        members.compactMap { $0.leaf?.widestRowWidth(font: font) }.max() ?? 0
    }

    func moved(_ source: LeafNode) {
        guard !applying else { return }
        applying = true
        defer { applying = false }
        for member in members {
            guard let leaf = member.leaf, leaf !== source else { continue }
            leaf.scrollY = source.scrollY
            leaf.scrollX = source.scrollX
        }
        // The partner is paint state like the source's own offset: a redraw,
        // never a body.
        ViewInvalidation.markNeedsRedraw()
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

/// How Enter indents a new logical line in an editor.
public enum EditorIndentation {
    case none
    case inherit
    /// Inherit the line's indent, adding a level after an opening brace in code.
    /// Use with a stateful highlighter backed by `CodeLexer`.
    case braces
    /// Computes whitespace at the insertion point. Nil inherits the current line's indent.
    case provider((EditorIndentationRequest) -> String?)
}

/// What an indentation provider is asked with.
public struct EditorIndentationRequest {
    /// The buffer as the editor holds it. Its `revision` and
    /// `changes(since:)` are what let a syntax tree follow the edits since it
    /// last looked instead of reading the whole buffer again.
    public let editing: TextEditingState
    /// Where the new line goes.
    public let caret: String.Index
    /// One level of indentation, as the configured format writes it.
    public let unit: String

    public var text: String { editing.text }
}

/// The width and representation of newly inserted indentation.
public struct EditorIndentationFormat {
    public let tabSize: Int
    public let insertSpaces: Bool

    public init(tabSize: Int, insertSpaces: Bool) {
        self.tabSize = min(32, max(1, tabSize))
        self.insertSpaces = insertSpaces
    }

    var unit: String { insertSpaces ? String(repeating: " ", count: tabSize) : "\t" }
}

public struct EditorView: PrimitiveView {
    /// The text being edited.
    @Binding public var text: String
    /// Allows selection, copying and navigation while preventing text changes.
    public var isReadOnly: Bool
    /// Syntax colouring rules, applied per line. Each rule's `styleIndex` picks a colour from `style.palette`.
    public var rules: [HighlightRule]
    /// A highlighter to use instead of `rules` — one built from a
    /// `StatefulLexer`, so a block comment or a multi-line string is coloured
    /// on every line it spans. Nil uses `rules`.
    public var highlighter: SyntaxHighlighter?
    public var indentation: EditorIndentation
    /// When supplied, what Tab inserts and the level Enter adds. Whitespace
    /// Enter inherits from the line is never rewritten into it.
    public var indentationFormat: EditorIndentationFormat?
    /// Told the buffer's state after it changes — at most once a frame, with
    /// every edit since the last call on record in `changes(since:)`. For
    /// something that follows the buffer as it is edited, such as a syntax
    /// tree parsing in the background. Called on the main thread; it must
    /// return at once.
    public var followBuffer: ((TextEditingState) -> Void)?
    /// Highlighting worked out elsewhere — a syntax tree on a worker — laid
    /// under `highlighter`: where it has spans for a line they are the line's
    /// base, and `highlighter` colours the lines it has none for yet.
    public var highlightSource: HighlightSource?
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
    public var lineActions: [Int: [EditorLineAction]]
    public var lineMarks: [EditorLineMark]
    /// Fired when the user clicks a decorated row's gutter icon, instead of
    /// the default "select the whole row" gutter click.
    public var onDecorationTap: ((EditorDecoration) -> Void)?
    /// Ctrl+wheel notches, consumed even when the document cannot scroll.
    public var onZoom: ((Float) -> Void)?
    /// A card about the text at its anchor, drawn below it. See `EditorHoverCard`.
    public var hoverCard: EditorHoverCard?
    /// Completions at the caret. Steer it with `onKey`; see `EditorCompletionList`.
    public var completion: EditorCompletionList?
    /// A click on a completion row, with the item's index — or nil for a
    /// click anywhere else in the editor while the list is up, which the app
    /// takes as "close it".
    public var onCompletionPick: ((Int?) -> Void)?
    /// The character under the resting pointer, or nil — told only when it
    /// changes, and never while Control is held (that is a link).
    public var onPointerOffset: ((Int?) -> Void)?
    /// Sees each key press before the editor. Return true to take it.
    public var onKey: ((KeyEvent) -> Bool)?
    /// A language server's highlighting, laid over the highlighter's per
    /// logical line. Its line numbers must describe the bound text as it is
    /// now — the app shifts them across edits until the server replies.
    public var semanticHighlights: SemanticHighlights?
    /// Ctrl+click on a word, with the character offset clicked: go to
    /// definition, open a link. While Control is held, the word under the
    /// pointer is underlined and the pointer becomes a hand, all drawn by the
    /// editor without asking the app. Nil turns the behaviour off, and a
    /// Ctrl+click then places the caret as usual.
    public var onFollow: ((Int) -> Void)?
    /// Handle for revealing lines, restoring positions and replacing matches.
    public var controller: EditorController?
    /// Blank rows between lines. See `EditorLineGap`.
    public var lineGaps: [EditorLineGap]
    /// Backgrounds behind character ranges. See `EditorRangeFill`.
    public var rangeFills: [EditorRangeFill]
    /// Shared with another editor to scroll in step. See `EditorScrollLink`.
    public var scrollLink: EditorScrollLink?
    /// Keeps this editor's undo history, caret and selection per `stateKey`.
    /// See `EditorStateStore`.
    public var stateStore: EditorStateStore?
    public var stateKey: AnyHashable?
    /// Told where the gap above its line was drawn, for `.editorZone`. See
    /// `EditorZoneAnchor`.
    public var zone: EditorZoneAnchor?

    /// Creates an editor bound to `text`. Every parameter matches the property of the same name.
    public init(
        text: Binding<String>,
        isReadOnly: Bool = false,
        rules: [HighlightRule] = [],
        highlighter: SyntaxHighlighter? = nil,
        indentation: EditorIndentation = .none,
        indentationFormat: EditorIndentationFormat? = nil,
        followBuffer: ((TextEditingState) -> Void)? = nil,
        highlightSource: HighlightSource? = nil,
        style: CodeStyle = CodeStyle(),
        font: UIFont? = nil,
        showLineNumbers: Bool = true,
        wraps: Bool = false,
        visibleLines: Int = 12,
        search: TextSearch = TextSearch(),
        decorations: [EditorDecoration] = [],
        lineMarks: [EditorLineMark] = [],
        lineActions: [Int: [EditorLineAction]] = [:],
        onDecorationTap: ((EditorDecoration) -> Void)? = nil,
        controller: EditorController? = nil,
        onZoom: ((Float) -> Void)? = nil,
        semanticHighlights: SemanticHighlights? = nil,
        hoverCard: EditorHoverCard? = nil,
        completion: EditorCompletionList? = nil,
        onCompletionPick: ((Int?) -> Void)? = nil,
        onPointerOffset: ((Int?) -> Void)? = nil,
        onKey: ((KeyEvent) -> Bool)? = nil,
        onFollow: ((Int) -> Void)? = nil,
        lineGaps: [EditorLineGap] = [],
        rangeFills: [EditorRangeFill] = [],
        scrollLink: EditorScrollLink? = nil,
        stateStore: EditorStateStore? = nil,
        stateKey: AnyHashable? = nil,
        zone: EditorZoneAnchor? = nil
    ) {
        self.zone = zone
        self.stateStore = stateStore
        self.stateKey = stateKey
        self.lineGaps = lineGaps
        self.rangeFills = rangeFills
        self.scrollLink = scrollLink
        self._text = text
        self.isReadOnly = isReadOnly
        self.rules = rules
        self.highlighter = highlighter
        self.indentation = indentation
        self.indentationFormat = indentationFormat
        self.followBuffer = followBuffer
        self.highlightSource = highlightSource
        self.style = style
        self.font = font
        self.showLineNumbers = showLineNumbers
        self.wraps = wraps
        self.visibleLines = visibleLines
        self.search = search
        self.decorations = decorations
        self.lineMarks = lineMarks
        self.lineActions = lineActions
        self.onDecorationTap = onDecorationTap
        self.controller = controller
        self.onZoom = onZoom
        self.onFollow = onFollow
        self.semanticHighlights = semanticHighlights
        self.hoverCard = hoverCard
        self.completion = completion
        self.onCompletionPick = onCompletionPick
        self.onPointerOffset = onPointerOffset
        self.onKey = onKey
    }

    /// The font the editor draws with: `font`, or the environment's when that is `nil`.
    public var resolvedFont: UIFont? { font ?? Environment.current.font }

    public var dumpDetail: String {
        "\(text.split(separator: "\n").count) lines, \(rules.count) rules"
    }

    public func mountPrimitive() -> any AnyViewNode {
        let leaf = LeafNode(kind: .editor, label: "EditorView", width: .auto, height: .auto)
        if !adoptStoredState(leaf) {
            leaf.editing = TextEditingState(text)
        }
        leaf.seedLogicalRows()
        configure(leaf)
        leaf.installTextMeasure()
        return leaf
    }

    public func reconcilePrimitive(_ node: any AnyViewNode) -> any AnyViewNode {
        guard let leaf = node as? LeafNode, leaf.kind == .editor else {
            return mountPrimitive()
        }
        let switched = (stateStore != nil ? stateKey : nil) != leaf.editingKey
        if switched {
            if !adoptStoredState(leaf) {
                // Leaving a store for an editor's own state: a fresh one, not
                // the document's, which stays in the store.
                leaf.editingSlot = EditingSlot(TextEditingState(text))
                leaf.editingKey = nil
            }
            leaf.forgetRows()
            leaf.seedLogicalRows()
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

    /// Points `leaf` at the store's state for `stateKey`, filling it from
    /// `text` the first time. A kept state whose text no longer matches —
    /// the file was reloaded, or edited by something that is not an editor —
    /// is reset to the text: its history describes a buffer that is gone.
    /// False when there is no store to use.
    private func adoptStoredState(_ leaf: LeafNode) -> Bool {
        guard let stateStore, let stateKey else { return false }
        let slot = stateStore.slot(for: stateKey)
        if !slot.isFilled {
            slot.state = TextEditingState(text)
            slot.isFilled = true
        } else if slot.state.text != text {
            slot.state.setText(text, keepingCursor: true)
        }
        leaf.editingSlot = slot
        leaf.editingKey = stateKey
        return true
    }

    /// Ctrl+hover links. The editor finds and draws the word itself — a
    /// redraw per word the pointer crosses, never a body — and only a click
    /// reaches the app.
    private func configureFollow(_ leaf: LeafNode) {
        leaf.onFollow = onFollow
        leaf.onPointerOffset = onPointerOffset
        guard onFollow != nil || onPointerOffset != nil else {
            leaf.onPointerHoverLocal = nil
            if leaf.onHover != nil {
                leaf.onHover = nil
                HoverState.unregister(leaf.id)
            }
            leaf.pointerCursor = nil
            leaf.setLink(nil)
            return
        }
        // `onHover` is what makes the leaf a stop on the local hover walk, and
        // its leave is what takes the underline down when the pointer goes on
        // to something else with Control still held.
        leaf.onHover = { [weak leaf] inside in
            guard !inside, let leaf else { return }
            leaf.pointerCursor = nil
            leaf.setLink(nil)
            leaf.reportPointer(nil)
        }
        HoverState.register(leaf.id) { [weak leaf] inside in leaf?.onHover?(inside) }
        leaf.onPointerHoverLocal = { [weak leaf] x, y in
            leaf?.updateLink(localX: x, localY: y)
        }
    }

    private func configure(_ leaf: LeafNode) {
        let theme = Environment.current.theme
        leaf.theme = theme
        let previousFont = leaf.font ?? FontStore.default
        let nextFont = resolvedFont ?? FontStore.default
        let fontChanged = previousFont?.identity != nextFont?.identity
        if fontChanged, let previousFont, previousFont.lineHeight > 0 {
            let topRow = leaf.row(atScreenY: 0, lineHeight: previousFont.lineHeight)
            let rows = leaf.editing.layout.rows
            let row = min(max(0, topRow), rows.count - 1)
            leaf.pendingFontAnchor = (rows[row].lowerBound, -leaf.screenY(ofRow: row, lineHeight: previousFont.lineHeight) / previousFont.lineHeight)
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
            leaf.forgetRows()
        }
        leaf.wraps = wraps
        let next = highlighter ?? SyntaxHighlighter(rules: rules)
        // The cache holds spans per line and re-lexes only lines whose text
        // changed. A different highlighter changes every line's spans without
        // changing a character, so its results are dropped with it.
        if leaf.highlighter?.identity != next.identity {
            leaf.highlightCache = SyntaxHighlighter.Cache()
        }
        leaf.highlighter = next
        leaf.indentation = indentation
        leaf.indentationFormat = indentationFormat
        // Every edit is committed through the binding, and the binding's
        // change is what brings the view back here — so this sees each one,
        // batched by frame, without a call at every place that edits.
        if let followBuffer, leaf.followedRevision != leaf.editing.revision {
            leaf.followedRevision = leaf.editing.revision
            followBuffer(leaf.editing)
        }
        if leaf.highlightSource !== highlightSource {
            leaf.highlightSource = highlightSource
            // A layer the source finishes between frames has to bring one
            // about, in this editor's window: nothing else is going to.
            if let highlightSource {
                let target = RedrawTarget(source: highlightSource, scope: WindowScope.currentOrMain)
                highlightSource.highlightsChanged = {
                    MainQueue.async { target.redrawIfUndrawn() }
                }
            }
        }
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
        leaf.lineActions = lineActions
        leaf.lineMarks = lineMarks.sorted { $0.lines.lowerBound < $1.lines.lowerBound }
        leaf.onDecorationTap = onDecorationTap
        leaf.lineGaps = lineGaps
        leaf.zoneAnchor = zone
        leaf.rangeFills = rangeFills.sorted { $0.range.lowerBound < $1.range.lowerBound }
        leaf.scrollLink = scrollLink
        leaf.semanticHighlights = semanticHighlights?.isEmpty == false ? semanticHighlights : nil
        leaf.hoverCard = hoverCard
        leaf.completion = completion
        leaf.onCompletionPick = onCompletionPick
        leaf.keyInterceptor = onKey
        configureFollow(leaf)

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
            caretOffset: { [weak leaf] in leaf?.focusOffset() },
            insert: { [weak leaf] text, range, caretAt in
                guard let leaf, !leaf.isReadOnly else { return false }
                leaf.editing.replace(offsets: range, with: text)
                if let caretAt, caretAt < text.count {
                    leaf.editing.setCursor(leaf.textIndex(atOffset: range.lowerBound + caretAt))
                }
                leaf.seedLogicalRows()
                leaf.markMeasureDirty()
                binding.wrappedValue = leaf.editing.text
                CaretBlink.noteEdit()
                ViewInvalidation.markDirty()
                return true
            },
            linePrefix: { [weak leaf] limit in
                guard let leaf else { return nil }
                let text = leaf.editing.text
                let caret = leaf.textIndex(atOffset: leaf.focusOffset())
                var start = caret
                var taken = 0
                while start > text.startIndex, taken < limit {
                    let previous = text.index(before: start)
                    if text[previous] == "\n" || text[previous] == "\r\n" { break }
                    start = previous
                    taken += 1
                }
                return String(text[start..<caret])
            },
            focus: { [weak leaf] in
                leaf?.focusSelf(binding: binding, onSubmit: nil)
            }
        )

        // Height is decided by the measure callback from the row count, so
        // the box always matches what is drawn.
        leaf.maxLines = visibleLines
        if let f = resolvedFont {
            leaf.gutterWidth = (showLineNumbers ? leaf.measuredGutterWidth(font: f) : 0) + leaf.actionGutterWidth
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

        leaf.onClickLocal = { [weak leaf] localX, localY, originX, originY, mods, _ in
            guard let leaf else { return }
            // The list is drawn over the text, so a press on it is read that
            // way first, like the scrollbars.
            if let hit = leaf.completionHit, let pick = leaf.onCompletionPick {
                if let item = hit.item(atLocalX: localX, localY: localY) {
                    pick(item)
                    return
                }
                pick(nil)
            }
            // Before anything else: the bars are painted over the text, so a
            // press on one has to be read that way too. Without this, grabbing
            // the thumb would put the caret behind it.
            if leaf.beginScrollbarDrag(
                localX: localX, localY: localY, originX: originX, originY: originY
            ) {
                ViewInvalidation.markNeedsRedraw()
                return
            }
            if let hit = leaf.lineAction(atX: localX, y: localY) {
                hit.perform()
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
            } else if KeyMods.contains(mods, KeyMods.control), let follow = leaf.onFollow,
                      let offset = leaf.linkOffset(
                          localX: localX - leaf.gutterWidth + leaf.scrollX,
                          localY: Double(localY) + leaf.scrollY
                      )
            {
                // The link, not the caret: a go-to that also moved the caret
                // would leave the old file's position wherever the user
                // happened to click.
                follow(offset)
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
    /// Ctrl+hover: the word under the pointer while Control is held, else
    /// nothing. `localX`/`localY` are the box's own, gutter included.
    func lineAction(atX x: Float, y: Float) -> EditorLineAction? {
        lineActionHits.first { $0.rect.contains(CGPoint(x: CGFloat(x), y: CGFloat(y))) }?.action
    }

    func updateLink(localX: Float, localY: Float) {
        if !PointerCapture.isActive, lineAction(atX: localX, y: localY) != nil {
            pointerCursor = .pointer
            setLink(nil)
            reportPointer(nil)
            return
        }
        var link: Range<Int>?
        var pointer: Int?
        if !PointerCapture.isActive, localX >= gutterWidth {
            let contentX = localX - gutterWidth + scrollX
            let contentY = Double(localY) + scrollY
            if HeldModifiers.control, onFollow != nil {
                link = wordUnder(localX: contentX, localY: contentY)
            } else if onPointerOffset != nil {
                pointer = characterUnder(localX: contentX, localY: contentY)?.offset
            }
        }
        pointerCursor = link == nil ? nil : .pointer
        setLink(link)
        reportPointer(pointer)
    }

    func reportPointer(_ offset: Int?) {
        guard offset != reportedPointerOffset else { return }
        reportedPointerOffset = offset
        onPointerOffset?(offset)
    }

    func setLink(_ link: Range<Int>?) {
        guard link != linkRange else { return }
        linkRange = link
        ViewInvalidation.markNeedsRedraw()
    }

    /// The offset a Ctrl+click follows: the character clicked, when it is in a
    /// word. Content coordinates, as `characterUnder` takes them.
    func linkOffset(localX: Float, localY: Double) -> Int? {
        guard wordUnder(localX: localX, localY: localY) != nil else { return nil }
        return characterUnder(localX: localX, localY: localY)?.offset
    }

    func editorPosition() -> EditorPosition {
        // `charOffset` is anchored, so the second call walks only the distance
        // between the two ends rather than back to the start of the buffer.
        let height = (font ?? FontStore.default)?.lineHeight ?? 1
        let topRow = self.row(atScreenY: 0, lineHeight: height)
        let rows = editing.layout.rows
        let row = min(max(0, topRow), max(0, rows.count - 1))
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
            topFraction: -screenY(ofRow: row, lineHeight: height) / max(1, height)
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
                                 fraction.isFinite ? min(0.999, max(-1, fraction)) : 0)
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

/// What a highlight source's "changed" callback holds: weakly, because the
/// source outlives the window and the editor that installed it.
private final class RedrawTarget: @unchecked Sendable {
    // Read on the main thread only, from `MainQueue`.
    private weak var source: HighlightSource?
    private weak var scope: WindowScope?

    init(source: HighlightSource, scope: WindowScope) {
        self.source = source
        self.scope = scope
    }

    func redrawIfUndrawn() {
        guard let source, source.hasUndrawnHighlights, let scope else { return }
        scope.raise(.redraw)
    }
}
