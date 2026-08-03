#if canImport(CYoga)
import CYoga
import Foundation
import Observation

// Retained view nodes + Yoga mirror.
//
// - Nodes are long-lived; `LayoutHost.setRoot` reconciles, does not freeTree.
// - Yoga handles: created in node init, freed in deinit (ARC owns the tree).
// - Fragments (TupleView / Either / Optional / ForEach / Composite) have
//   yoga == nil and splice children into the parent flex container.

public enum FlexDirection {
    case row
    case column

    var yoga: YGFlexDirection {
        switch self {
        case .row: return YGFlexDirectionRow
        case .column: return YGFlexDirectionColumn
        }
    }
}

extension StackAlignment {
    var yoga: YGAlign {
        switch self {
        case .start: return YGAlignFlexStart
        case .center: return YGAlignCenter
        case .end: return YGAlignFlexEnd
        case .stretch: return YGAlignStretch
        }
    }
}

public struct LayoutFrame: Sendable, Equatable {
    public var label: String
    public var x: Float
    public var y: Float
    public var w: Float
    public var h: Float

    public var description: String {
        String(format: "%@  (%.1f, %.1f) %.1f×%.1f", label, x, y, w, h)
    }
}

// MARK: - Node protocol

public protocol AnyViewNode: AnyObject {
    var id: NodeID { get }
    var label: String { get }
    /// Non-nil for layout boxes (stacks, text, spacer…). Nil for fragments.
    var yoga: YGNodeRef? { get }
    /// Direct retained children (not flattened).
    var childNodes: [any AnyViewNode] { get }
    var needsBodyRecompute: Bool { get set }

    /// Author-assigned agent id (`.agentId("…")`). Stable across process runs.
    /// Prefer this over process-local `id` when scripting the UI.
    var agentId: String? { get set }

    /// Path segment override (e.g. ForEach element key). Used when building
    /// structural `sid` fallbacks for untagged nodes.
    var structuralKey: String? { get set }

    func collectFrames(originX: Float, originY: Float, into: inout [LayoutFrame])
}

extension AnyViewNode {
    /// Depth-first list of nodes that own a Yoga box (fragments expand).
    func flattenedLayoutNodes() -> [any AnyViewNode] {
        if yoga != nil {
            return [self]
        }
        return childNodes.flatMap { $0.flattenedLayoutNodes() }
    }
}

// MARK: - Yoga-backed base

/// Owns one `YGNodeRef` for its lifetime.
class YogaBoxNode: AnyViewNode {
    let id: NodeID
    let yogaStorage: YGNodeRef
    var label: String
    var agentId: String?
    var structuralKey: String?
    var needsBodyRecompute = false

    var flexGrow: Float = 0
    /// Yoga's default, not CSS's.
    ///
    /// CSS defaults this to 1, which makes every box negotiable: one sibling
    /// whose content overflows shrinks *everything* on the line in proportion,
    /// boxes that stated an explicit size included. A `height: .pt(56)` toolbar
    /// beside a ScrollView holding 1483pt of content came out at 29pt, having
    /// absorbed its share of the deficit — and a size a distant sibling can
    /// quietly renegotiate is not a size.
    ///
    /// Yoga defaults it to 0 for that reason, and so does this — see
    /// `effectiveFlexShrink` for the one case that opts back in.
    ///
    /// `nil` means nobody has stated a value, which is why this is optional: an
    /// explicit 0 and an unset 0 have to be told apart.
    var flexShrink: Float?

    /// What actually reaches Yoga.
    ///
    /// Unset, a box shrinks only if it asked to grow. `flexGrow > 0` says *this*
    /// is the flexible box on its line, and something that takes the leftover
    /// space should be able to give it back — a column that fills the window is
    /// also the one that must yield when the window is too small for it.
    /// Without that, a ScrollView inside such a column is laid out at its full
    /// content height, its viewport equals its content, and it has nothing left
    /// to scroll.
    ///
    /// A box with a stated size and no `flexGrow` is not making that offer, and
    /// is what the 0 default protects.
    var effectiveFlexShrink: Float { flexShrink ?? (flexGrow > 0 ? 1 : 0) }
    var width: Dimension = .auto
    var height: Dimension = .auto
    var padding: Float = 0
    var minWidth: Float = 0
    var minHeight: Float = 0
    /// The node's own settings, captured before any modifier touched it, so a
    /// removed modifier does not leave its effect behind.
    var styleBaseline: ViewStyle?
    /// Set by any box that accepts the wheel.
    var isScrollable = false
    /// Appear/disappear animation, if `.transition()` was applied.
    var transitionState: TransitionState?
    /// Backdrop blur radius from `.backdropBlur(radius:)`. Emitted as Begin/End
    /// BackdropBlur around this node's paint (see DrawList).
    var backdropBlurRadius: Float?
    /// Content blur radius from `.blur(radius:)`. Same bookends, different
    /// subject: the engine renders this node's own paint offscreen and blurs
    /// that, rather than blurring what was already behind it.
    var contentBlurRadius: Float?
    /// When true, paint (and children) is scissored to this box's layout rect.
    /// Yoga still allows overflow for measure; we clip at emit only — used by
    /// the menubar strip so a title's hover fill cannot paint over content.
    var clipsContent: Bool = false

    /// How far this node's children are drawn from its own origin.
    ///
    /// A scroll container shifts its content; every traversal — emit, hit test,
    /// hover, frame collection — has to apply the *same* shift or they disagree.
    /// They did disagree once: the emitter offset children while the hit walks
    /// did not, so clicks in a scrolled view landed off by the scroll amount.
    /// Overriding this in one place is what keeps them in step.
    var childOffset: (x: Float, y: Float) { (0, 0) }

    var yoga: YGNodeRef? { yogaStorage }
    var childNodes: [any AnyViewNode] { [] }

    init(label: String) {
        self.id = .generate()
        self.label = label
        self.yogaStorage = YGNodeNew()
    }

    deinit {
        // Detaches from parent automatically (YGNodeFree).
        YGNodeFree(yogaStorage)
    }

    func applyStyle() {
        YGNodeStyleSetFlexGrow(yogaStorage, flexGrow)
        YGNodeStyleSetFlexShrink(yogaStorage, effectiveFlexShrink)
        applyDimension(
            width, setPoint: YGNodeStyleSetWidth, setAuto: YGNodeStyleSetWidthAuto,
            setPercent: YGNodeStyleSetWidthPercent
        )
        applyDimension(
            height, setPoint: YGNodeStyleSetHeight, setAuto: YGNodeStyleSetHeightAuto,
            setPercent: YGNodeStyleSetHeightPercent
        )
        YGNodeStyleSetPadding(yogaStorage, YGEdgeAll, padding)
        if minWidth > 0 {
            YGNodeStyleSetMinWidth(yogaStorage, minWidth)
        } else {
            YGNodeStyleSetMinWidth(yogaStorage, 0)
        }
        if minHeight > 0 {
            YGNodeStyleSetMinHeight(yogaStorage, minHeight)
        } else {
            YGNodeStyleSetMinHeight(yogaStorage, 0)
        }
    }

    private func applyDimension(
        _ dim: Dimension,
        setPoint: (YGNodeRef?, Float) -> Void,
        setAuto: (YGNodeRef?) -> Void,
        setPercent: (YGNodeRef?, Float) -> Void
    ) {
        switch dim {
        case .undefined:
            setPoint(yogaStorage, .nan)
        case .auto:
            setAuto(yogaStorage)
        case .point(let v):
            setPoint(yogaStorage, v)
        case .percent(let v):
            setPercent(yogaStorage, v)
        }
    }

    func collectFrames(originX: Float, originY: Float, into frames: inout [LayoutFrame]) {
        let x = originX + YGNodeLayoutGetLeft(yogaStorage)
        let y = originY + YGNodeLayoutGetTop(yogaStorage)
        let w = YGNodeLayoutGetWidth(yogaStorage)
        let h = YGNodeLayoutGetHeight(yogaStorage)
        frames.append(LayoutFrame(label: label, x: x, y: y, w: w, h: h))
        let shift = childOffset
        collectChildFrames(originX: x - shift.x, originY: y - shift.y, into: &frames)
    }

    func collectChildFrames(originX: Float, originY: Float, into frames: inout [LayoutFrame]) {}
}

// MARK: - Leaf (Text / Spacer / DiagramHost / Empty)

enum LeafKind: Equatable {
    case text
    case markdown
    case spacer
    case diagramHost
    case empty
    case image
    case textField
    case editor
    case button
    case toggle
    case slider
    case divider
    /// App-supplied paint via `Canvas` / `canvasPaint` (no built-in chrome).
    case canvas
    case scene3D
}

final class LeafNode: YogaBoxNode {
    let kind: LeafKind
    /// Phase 3/4 draw / hit-test payload (text leaves).
    var text: String = ""
    var color: Color = .primary
    var onClick: (() -> Void)?
    var fillColor: Color?
    /// Explicit face, or nil → `FontStore.default` at measure time.
    var font: UIFont?
    /// Captured from `Environment.current.theme` at mount/reconcile — measure
    /// and draw-list emit run later, as separate passes with no environment
    /// scope active, so they read this instead of `Theme.current` directly.
    var theme: Theme = Theme.current
    /// Last layout lines from Font measure cache (for multi-line emit).
    var cachedLines: [String] = []
    var markdownSpans: [MarkdownSpan] = []
    var markdownStyle: MarkdownStyle?
    var usesTextMeasure = false
    /// Editable payload (textField leaves). Lives on the node because a
    /// PrimitiveView has no body, so it never goes through CompositeNode's
    /// @State transplant — the node's own lifetime is the persistence.
    var editing = TextEditingState("") {
        // Any write invalidates the offset anchor below. Deliberately every
        // write, not just text edits: a cursor move cannot invalidate it, but
        // paying a nil-out on those is nothing next to the cost of getting
        // this wrong, which is glyphs drawn from the wrong part of the buffer.
        didSet { indexAnchor = nil }
    }
    /// Last character offset resolved to a `String.Index` in this buffer.
    ///
    /// `TextEditingState.index(atOffset:)` walks from `startIndex` on every
    /// call. The draw path needs the first visible row's index once per
    /// redraw, so an editor scrolled to the end of a 10 MB log paid a
    /// full-buffer walk per frame — including every frame a blinking caret
    /// causes, at ~25ms each. Scrolling moves that offset by a few rows, so
    /// resolving from the previous answer makes the steady state a few
    /// characters instead.
    private var indexAnchor: (offset: Int, index: String.Index)?
    var placeholder: String = ""
    var isMultiline = false
    var maxLines = 8
    var wraps = false
    /// Per-field focus chrome override; nil falls through to `theme.focusRing*`.
    var focusRingStyle: FocusRingStyle?
    var focusRingWidth: Float?
    var focusRingColor: Color?
    /// Button-only payload.
    var buttonFill: Animated<Color>?
    var buttonStyle: ButtonStyle?
    var isPressed = false
    var isEnabled = true

    /// Toggle-only payload. `toggleKnob` runs 0…1 across the track, so the
    /// knob and the track colour can be interpolated independently — a flick
    /// looks wrong if the colour lands before the knob does.
    var toggleStyle: ToggleStyle?
    var toggleKnob: Animated<Float>?
    var toggleTrack: Animated<Color>?
    /// Animated separately rather than recomputed from the current track: the
    /// knob's contrast colour flips at a luminance threshold, which mid-slide
    /// would be a visible pop.
    var toggleKnobColor: Animated<Color>?
    var isOn = false

    /// Slider-only payload.
    ///
    /// The knob *position* is deliberately not animated: during a drag it must
    /// sit under the pointer, and any interpolation there reads as lag. Only
    /// the knob's size responds to hover and press.
    var sliderStyle: SliderStyle?
    var sliderFraction: Float = 0
    var sliderKnobScale: Animated<Float>?
    /// Geometry recorded at emit, so a drag converts pointer position through
    /// exactly the numbers that drew the track rather than recomputing them.
    var sliderInset: Float = 0
    var sliderTravel: Float = 0

    /// Custom `Canvas` paint (absolute frame). Nil for non-canvas leaves.
    var canvasPaint: ((DrawList, CanvasFrame) -> Void)?
    var spatialRuntime: SpatialRuntime?
    var onPointerHoverLocal: ((_ localX: Float, _ localY: Float) -> Void)?
    /// When true, `AnimationDriver` keeps requesting redraws for this leaf.
    var continuousRedraw: Bool = false
    /// Absolute frame from the most recent `emitLeafContents` — the same
    /// rect `canvasPaint` was just handed. A wheel event carries no position
    /// of its own (see `PointerState`); this is what turns that window
    /// position into a coordinate local to the canvas.
    var lastCanvasFrame: CanvasFrame = CanvasFrame(x: 0, y: 0, w: 0, h: 0)

    /// Divider-only payload. `dividerAxis` is an explicit override; nil infers
    /// the orientation from whatever container this ended up in.
    var dividerStyle: DividerStyle?
    var dividerAxis: DividerAxis?

    /// True when the container runs horizontally, so the rule runs vertically.
    ///
    /// Read from the Yoga owner rather than passed down: the owner is not set
    /// until the parent inserts this node, which happens after mount, so there
    /// is no moment during construction when the answer is known. Measure and
    /// emit both run after insertion, and both ask here.
    var isVerticalDivider: Bool {
        if let dividerAxis { return dividerAxis == .vertical }
        guard let owner = YGNodeGetOwner(yogaStorage) else { return false }
        let direction = YGNodeStyleGetFlexDirection(owner)
        return direction == YGFlexDirectionRow || direction == YGFlexDirectionRowReverse
    }

    /// Editor-only payload.
    var highlighter: SyntaxHighlighter?
    /// Only actually used (and updated) when `highlighter.isStateful` — see
    /// `SyntaxHighlighter.Cache`. Harmless to carry around otherwise: `update`
    /// clears it to empty for a stateless highlighter, so a stale cache from
    /// a prior stateful one can't leak through if `highlighter` is swapped.
    var highlightCache = SyntaxHighlighter.Cache()
    var codeStyle: CodeStyle?
    var showsGutter = false
    var gutterWidth: Float = 0
    var search = TextSearch()
    /// Diagnostics keyed by character range — gutter icon, underline, and
    /// (via `onDecorationTap`) a click-through to whatever message the app
    /// wants to show. Not hover-tracked: nothing in the input pipeline feeds
    /// a leaf continuous pointer position outside an active drag/capture, so
    /// "click the gutter icon" is the interaction this offers, not "hover
    /// the underline" — see `docs/traceloom-lavaui-gaps.md` #4.
    var decorations: [EditorDecoration] = []
    var onDecorationTap: ((EditorDecoration) -> Void)?
    /// Vertical scroll offset in pixels. Positive scrolls content up.
    var scrollY: Float = 0
    /// Horizontal offset in pixels. The gutter does not move with it.
    var scrollX: Float = 0
    /// Width of the text area (box minus gutter and padding), from the last
    /// emit. Needed to clamp horizontal scrolling against something real.
    var textViewportWidth: Float = 0
    /// Widest row in pixels, cached per (text, font) so a wide buffer does not
    /// reshape every line on every frame just to clamp a scrollbar.
    ///
    /// Keyed on `editing.text` directly rather than `.count` (an O(length)
    /// grapheme count, paid on every call, hit or miss) — `String` equality
    /// short-circuits on shared storage when nothing changed, which is the
    /// common case here, so this is the one comparison that's actually free
    /// when it matters.
    private var widestRowCache: (fontIdentity: String, text: String, width: Float)?

    /// How many of the longest-by-bytes rows get shaped for real.
    ///
    /// More than one because byte length is only a proxy: with a proportional
    /// face a long run of `i` can out-count a shorter run of `W`. A dozen
    /// candidates makes that miss vanishingly unlikely, and this is a scroll
    /// bound and an intrinsic width — not a layout invariant — so being a few
    /// pixels shy on a pathological buffer costs nothing that matters.
    private static let widestRowCandidates = 12

    /// Also used by `measureForYoga`'s intrinsic-width case — one
    /// computation, one cache, instead of the measure pass silently
    /// reshaping every line again right after this already did.
    ///
    /// Shapes only the longest few rows, not all of them. Shaping every row to
    /// find the widest is O(buffer) in the slowest operation text has, *and*
    /// leaves an entry per row in the shape cache: on a 23 MB Android log
    /// (166,636 lines) opening the editor pegged a core and grew the process
    /// past 9 GB before it was killed. Ranking by `utf8.count` is O(1) per row
    /// on a `Substring`, so the scan is effectively free and only the
    /// candidates cost a shaping.
    func widestRowWidth(font: UIFont) -> Float {
        if let c = widestRowCache, c.fontIdentity == font.identity, c.text == editing.text {
            return c.width
        }
        // Both cases rank on the row table layout has already built and
        // cached. The no-wrap case used to rank on `editing.lines` instead,
        // and that property re-splits the entire buffer on every access — a
        // 10 MB log paid a fresh 200,000-substring split here on each measure
        // pass, which was most of what opening the editor on one cost.
        let rows = editing.layout.rows
        let picks = Self.longestIndices(count: rows.count, limit: Self.widestRowCandidates) {
            rows[$0].count
        }
        let widest = rowTexts(at: picks, rows: rows).reduce(Float(0)) {
            max($0, font.shapedRun($1).width)
        }
        widestRowCache = (font.identity, editing.text, widest)
        return widest
    }

    /// `String.Index` for a character offset, resolved relative to the last
    /// offset this leaf resolved — see `indexAnchor`.
    func textIndex(atOffset offset: Int) -> String.Index {
        let text = editing.text
        if let anchor = indexAnchor {
            let delta = offset - anchor.offset
            if delta == 0 { return anchor.index }
            let limit = delta > 0 ? text.endIndex : text.startIndex
            if let moved = text.index(anchor.index, offsetBy: delta, limitedBy: limit) {
                indexAnchor = (offset, moved)
                return moved
            }
        }
        let resolved = editing.index(atOffset: offset)
        indexAnchor = (offset, resolved)
        return resolved
    }

    /// Text of the given rows, extracted in a single forward pass.
    ///
    /// `index(atOffset:)` walks from the start of the buffer on every call, so
    /// a dozen candidate rows near the end of a large file walked it a dozen
    /// times. Sorting the candidates and carrying a cursor makes it one walk —
    /// the same trick `emitEditor` uses for the visible window.
    private func rowTexts(at indices: [Int], rows: [Range<Int>]) -> [String] {
        let text = editing.text
        let endOffset = text.count
        var cursor = text.startIndex
        var cursorOffset = 0
        var out: [String] = []
        out.reserveCapacity(indices.count)
        for i in indices.sorted() {
            let row = rows[i]
            // Stale visual rows (edit before the next wrap/seed) can overshoot
            // the buffer; clamp rather than trap in `index(_:offsetBy:)`.
            let lo = min(max(0, row.lowerBound), endOffset)
            let hiOff = min(max(lo, row.upperBound), endOffset)
            if lo > cursorOffset {
                cursor = text.index(cursor, offsetBy: lo - cursorOffset, limitedBy: text.endIndex)
                    ?? text.endIndex
                cursorOffset = lo
            } else if lo < cursorOffset {
                // Sorted picks can still land before the cursor if earlier
                // rows were clamped; re-anchor from the start.
                cursor = text.index(text.startIndex, offsetBy: lo, limitedBy: text.endIndex)
                    ?? text.endIndex
                cursorOffset = lo
            }
            let span = hiOff - lo
            let hi = text.index(cursor, offsetBy: span, limitedBy: text.endIndex)
                ?? text.endIndex
            out.append(String(text[cursor..<hi]))
            cursor = hi
            cursorOffset = hiOff
        }
        return out
    }

    /// Indices of the `limit` longest items, in one pass.
    ///
    /// The `n <= shortest` guard is what keeps this linear in practice: after
    /// the first few rows almost every line fails it on the first comparison,
    /// so the insertion path is cold.
    private static func longestIndices(
        count: Int, limit: Int, length: (Int) -> Int
    ) -> [Int] {
        guard count > limit else { return Array(0..<count) }
        var best: [(index: Int, length: Int)] = []
        best.reserveCapacity(limit + 1)
        var shortest = Int.min
        for i in 0..<count {
            let n = length(i)
            if best.count == limit && n <= shortest { continue }
            let at = best.firstIndex { n > $0.length } ?? best.count
            best.insert((index: i, length: n), at: at)
            if best.count > limit { best.removeLast() }
            shortest = best.count == limit ? best[best.count - 1].length : Int.min
        }
        return best.map(\.index)
    }

    func maxScrollX(font: UIFont) -> Float {
        max(0, widestRowWidth(font: font) - textViewportWidth)
    }

    func scrollByX(_ delta: Float, font: UIFont) {
        let next = min(max(0, scrollX + delta), maxScrollX(font: font))
        if next != scrollX {
            scrollX = next
            // Paint state on a retained node, not a view value — `emitEditor`
            // reads `scrollX` fresh every emit regardless of level. `markDirty`
            // (a full `.body` rebuild — for `EditorView`, re-running whatever
            // parses/highlights the bound text) here meant every wheel notch
            // over a large buffer repeated all of that just to move pixels.
            ViewInvalidation.markNeedsRedraw()
        }
    }

    /// Keeps the caret horizontally visible, with a small margin so it never
    /// sits flush against the edge it just crossed.
    func scrollToCaretX(font: UIFont) {
        guard textViewportWidth > 0 else { return }
        let rows = editing.layout.rows
        let row = editing.layout.rowIndex(
            ofOffset: editing.offset(of: editing.focus), affinity: editing.affinity
        )
        guard row < rows.count else { return }
        let r = rows[row]
        let lo = editing.index(atOffset: r.lowerBound)
        let hi = editing.index(atOffset: r.upperBound)
        let line = String(editing.text[lo..<hi])
        let column = editing.offset(of: editing.focus) - r.lowerBound
        let clamped = max(0, min(column, line.count))
        let caretX = font.shapedRun(line)
            .caretX(for: line.index(line.startIndex, offsetBy: clamped))

        let margin: Float = 24
        if caretX < scrollX + margin {
            scrollX = max(0, caretX - margin)
            ViewInvalidation.markDirty()
        } else if caretX > scrollX + textViewportWidth - margin {
            scrollX = caretX - textViewportWidth + margin
            ViewInvalidation.markDirty()
        }
        scrollX = min(max(0, scrollX), maxScrollX(font: font))
    }
    /// Box height from the last layout, needed to clamp scrolling and to
    /// decide how many rows fit.
    var viewportHeight: Float = 0

    /// Rows that fit in the viewport, at least one.
    func visibleRowCount(lineHeight: Float) -> Int {
        max(1, Int((viewportHeight - textInset * 2) / lineHeight))
    }

    /// Largest legal scroll offset for the current content.
    func maxScrollY(lineHeight: Float) -> Float {
        let content = Float(editing.layout.count) * lineHeight
        let visible = viewportHeight - textInset * 2
        return max(0, content - visible)
    }

    func scrollBy(_ delta: Float, lineHeight: Float) {
        let next = min(max(0, scrollY + delta), maxScrollY(lineHeight: lineHeight))
        if next != scrollY {
            scrollY = next
            // See `scrollByX` — same paint-only state, same reason `.body`
            // is the wrong (and, for a large buffer, ruinously expensive)
            // level for it.
            ViewInvalidation.markNeedsRedraw()
        }
    }

    /// Whether a wheel notch of `dx`/`dy` would move this editor at all, which
    /// is what `ScrollRouter` asks before delivering. An editor whose buffer
    /// already fits — or one scrolled to its end — hands the notch to the
    /// enclosing scroll container instead of swallowing it.
    func editorCanScroll(dx: Float, dy: Float) -> Bool {
        guard let f = font ?? FontStore.default else { return false }
        let step = f.lineHeight * 3
        func movesX(_ delta: Float) -> Bool {
            min(max(0, scrollX + delta), maxScrollX(font: f)) != scrollX
        }
        func movesY(_ delta: Float) -> Bool {
            min(max(0, scrollY + delta), maxScrollY(lineHeight: f.lineHeight)) != scrollY
        }
        // Mirrors the axis choice the handler makes, so eligibility and effect
        // never disagree.
        if ScrollRouter.shiftHeld, dx == 0 { return movesX(-dy * step) }
        return (dx != 0 && movesX(-dx * step)) || (dy != 0 && movesY(-dy * step))
    }

    /// Last computed `(offset(of: focus), layout.rowIndex(of that offset))`,
    /// keyed on the exact `focus`/`affinity` they were computed from.
    private var cachedFocusPosition: (
        index: String.Index, affinity: CaretAffinity, offset: Int, row: Int
    )?

    /// `editing.offset(of: editing.focus)`, cached against the last `focus`
    /// this was computed for. `offset(of:)` walks the buffer from its start;
    /// a caret that hasn't moved — a blink, or any unrelated redraw while
    /// focused — would otherwise pay that walk again every single frame,
    /// which for a caret sitting deep in a large file is most of the cost
    /// a "nothing is happening" redraw had.
    func focusOffset() -> Int { focusPosition().offset }

    /// `editing.layout.rowIndex(ofOffset:affinity:)` for the caret, cached
    /// the same way and for the same reason — it is itself an O(rows) scan
    /// (rows are not random-access by offset), so on a large file this was
    /// the next-largest per-redraw cost once `focusOffset()` stopped being
    /// the dominant one. Deliberately memoized rather than made O(log rows):
    /// `rowIndex`'s affinity handling at a wrap boundary is subtle enough
    /// that reimplementing it as a binary search risks a caret-position
    /// regression for a cost that is already gone whenever the caret is not
    /// actually moving, which is almost always.
    func focusRow() -> Int { focusPosition().row }

    private func focusPosition() -> (offset: Int, row: Int) {
        if let cached = cachedFocusPosition,
           cached.index == editing.focus, cached.affinity == editing.affinity
        {
            return (cached.offset, cached.row)
        }
        let offset = editing.offset(of: editing.focus)
        let row = editing.layout.rowIndex(ofOffset: offset, affinity: editing.affinity)
        cachedFocusPosition = (editing.focus, editing.affinity, offset, row)
        return (offset, row)
    }

    /// Keeps the caret on screen after a move or an edit.
    ///
    /// Without this, typing past the last visible row silently moves the caret
    /// somewhere the user cannot see, which reads as the editor being frozen.
    func scrollToCaret(lineHeight: Float) {
        guard viewportHeight > 0 else { return }
        let row = editing.layout.rowIndex(
            ofOffset: editing.offset(of: editing.focus), affinity: editing.affinity
        )
        let rowTop = Float(row) * lineHeight
        let visible = viewportHeight - textInset * 2
        if rowTop < scrollY {
            scrollY = rowTop
            ViewInvalidation.markDirty()
        } else if rowTop + lineHeight > scrollY + visible {
            scrollY = rowTop + lineHeight - visible
            ViewInvalidation.markDirty()
        }
        scrollY = min(max(0, scrollY), maxScrollY(lineHeight: lineHeight))
    }
    /// Last width we soft-wrapped against (Yoga measure / post-layout).
    var lastMeasuredWidth: Float = 0
    /// Buffer at last wrap — text edits must re-wrap even if width is unchanged.
    var lastWrappedText: String = ""
    /// Buffer at last *no-wrap* row rebuild — nil so the very first measure
    /// always builds. Separate from `lastWrappedText`: `wraps` is fixed per
    /// leaf, but keeping these apart means one can't accidentally satisfy
    /// the other's staleness check.
    var lastLogicalRowsText: String?
    /// Click handler receiving node-local coordinates *and* the node's
    /// absolute origin. The caret needs the former; a drag needs the latter,
    /// because pointer capture delivers window coordinates long after the hit
    /// test that knew where this node was. `mods` is whatever was held at the
    /// moment of the press — a drag can't ask again mid-flight, only a fresh
    /// press reflects current modifier state.
    var onClickLocal: ((_ localX: Float, _ localY: Float,
                        _ originX: Float, _ originY: Float,
                        _ mods: Int32) -> Void)?
    /// Called when hover enters/leaves, for views wanting more than a fill.
    var onHover: ((Bool) -> Void)?

    /// Fill drawn when the pointer is over this leaf (nil = no hover effect).
    var hoverFill: Color?
    /// Optional foreground used while a text leaf is hovered.
    var hoverColor: Color?
    /// Corner radius for `fillColor`/`hoverFill`.
    var cornerRadius: Float = 0
    /// Maximum painted/measured rows for a read-only text leaf. `nil` means
    /// all wrapped rows; TextField has its separate `maxLines` policy.
    var textLineLimit: Int?

    /// Raster image leaf payload.
    var image: UIImage?
    var imageTint: Color = Color(r: 1, g: 1, b: 1)
    var imageContentMode: ImageContentMode = .stretch
    /// Set instead of `image` by `Image(path:)`: the texture is resolved at
    /// *emit*, not when the body ran, so an image arriving later needs only a
    /// redraw and never changes the shape of the tree.
    var imagePath: String?
    /// Longer-edge cap for the decode, derived from the layout box.
    var imageDecodePixels: UInt32 = 0
    /// Drawn in place of the bitmap until it resolves.
    var imagePlaceholder: Color?
    var imagePlaceholderRadius: Float = 0

    init(
        kind: LeafKind,
        label: String,
        width: Dimension,
        height: Dimension,
        flexGrow: Float = 0,
        minWidth: Float = 0
    ) {
        self.kind = kind
        super.init(label: label)
        self.width = width
        self.height = height
        self.flexGrow = flexGrow
        self.minWidth = minWidth
        theme = Environment.current.theme
        if kind == .diagramHost {
            fillColor = theme.canvas
        }
        applyStyle()
    }

    func update(
        label: String,
        width: Dimension,
        height: Dimension,
        flexGrow: Float = 0,
        minWidth: Float = 0,
        text: String = "",
        color: Color = .primary,
        onClick: (() -> Void)? = nil
    ) {
        let textChanged = self.text != text
        self.label = label
        self.width = width
        self.height = height
        self.flexGrow = flexGrow
        self.minWidth = minWidth
        self.text = text
        self.color = color
        self.onClick = onClick
        theme = Environment.current.theme
        applyStyle()
        if usesTextMeasure {
            // Content change invalidates Yoga's measure cache for this leaf.
            if textChanged {
                YGNodeMarkDirty(yogaStorage)
            }
        }
    }

    /// Re-wrap before measuring: row count drives the box height, and
    /// navigation consults the same rows.
    func prepareWrap(availableWidth: Float) {
        guard kind == .textField || kind == .editor else { return }
        refreshVisualRows(availableWidth: availableWidth)
    }

    /// Install Yoga measure callback (Phase 4). Width/height become auto;
    /// intrinsic size comes from `Font::measure` via `TextLayoutCache`.
    func installTextMeasure() {
        usesTextMeasure = true
        width = .auto
        height = .auto
        applyStyle()
        YGNodeSetContext(yogaStorage, Unmanaged.passUnretained(self).toOpaque())
        YGNodeSetMeasureFunc(yogaStorage, leafTextMeasure)
        YGNodeMarkDirty(yogaStorage)
    }

    func measureForYoga(width: Float, widthMode: YGMeasureMode) -> YGSize {
        PerfCounters.yogaMeasures &+= 1
        // Before the font guard: a rule is the one leaf with no text in it.
        if kind == .divider, let style = dividerStyle {
            let extent = style.thickness + style.spacing * 2
            // Only the main axis is claimed. The cross axis is left at zero and
            // filled by `alignItems: stretch`, which every container here sets
            // — a divider is *defined* as spanning its container, so taking the
            // measurement would just be guessing at what stretch already knows.
            return isVerticalDivider
                ? YGSize(width: extent, height: 0)
                : YGSize(width: 0, height: extent)
        }

        guard let font = font ?? FontStore.default else {
            // Fallback estimate if font not bootstrapped yet.
            let w = max(8, Float(text.count) * 8 + 8)
            return YGSize(width: w, height: 22)
        }

        if kind == .textField || kind == .editor {
            // Soft-wrap needs a *finite* offered width. Yoga probes with AtMost
            // (parent free space) and Exactly (resolved box). We used to wrap
            // only on Exactly, but stretch/auto fields often size from the
            // AtMost result alone — so the long first line never broke and the
            // field grew (or overflowed) as one visual row. Wrap on any
            // constrained mode; Undefined stays unwrapped (intrinsic width).
            // Called unconditionally (not just while wrapping): it caches
            // row boundaries for the no-wrap case too, and does its own
            // text/width staleness check either way.
            refreshVisualRows(availableWidth: width)

            if isMultiline {
                // Height comes from the rows we will actually draw, so the box
                // and its contents cannot disagree. Deriving it from
                // Font::measure instead let the two drift, which is what made
                // the editor's last line spill past its own box.
                let shown = min(max(editing.layout.count, 1), max(1, maxLines))
                let height = Float(shown) * font.lineHeight + textInset * 2
                // Seed the viewport; the emitter corrects it from the box Yoga
                // actually granted, which can be smaller.
                if viewportHeight <= 0 { viewportHeight = height }
                // Cached on (text, font) — see `widestRowWidth` — so a
                // measure pass right after a `maxScrollX` call (or vice
                // versa) doesn't reshape every line a second time.
                let widest = widestRowWidth(font: font)
                let contentWidth = widest + gutterWidth + textInset * 2
                // A wrapping field fills the offered width so Yoga does not
                // expand the box to the unwrapped line length.
                let w: Float
                if wraps, width > 0,
                   widthMode == YGMeasureModeExactly || widthMode == YGMeasureModeAtMost
                {
                    w = width
                } else {
                    w = contentWidth
                }
                return YGSize(width: w, height: height)
            }
        }

        if kind == .slider, let style = sliderStyle {
            // The readout is given a *reserved* width rather than its measured
            // one: a number whose width changes as it is dragged would resize
            // the track under the pointer, and the knob would drift away from
            // the finger holding it.
            let readout = text.isEmpty ? 0 : style.valueGap + style.valueWidth
            let natural = style.trackWidth + readout + 8
            // Honour an exact width so `.flexGrow(1)` and `.frame(width:)`
            // stretch the track; otherwise take the natural size.
            let w = (widthMode == YGMeasureModeExactly && width > 0) ? width : natural
            // Tall enough for the knob at its hover size, or it clips.
            let knobExtent = style.knobRadius * 2 * style.knobHoverScale
            return YGSize(width: w, height: max(knobExtent, font.lineHeight) + 4)
        }

        if kind == .toggle, let style = toggleStyle {
            // The track is fixed; only the label is measured, and it is
            // measured unconstrained (mode 0) because a control label that
            // wraps mid-word is worse than one that overflows its row.
            var contentW = style.trackWidth
            var contentH = max(style.trackHeight, font.lineHeight)
            if !text.isEmpty {
                let entry = TextLayoutCache.shared.layout(
                    font: font, text: text, availWidth: 0, mode: 0
                )
                cachedLines = entry.lines
                contentW += style.labelGap + entry.width
                contentH = max(contentH, entry.height)
            }
            return YGSize(width: contentW + 8, height: contentH + 4)
        }

        let mode: Int
        switch widthMode {
        case YGMeasureModeUndefined: mode = 0
        case YGMeasureModeExactly: mode = 1
        case YGMeasureModeAtMost: mode = 2
        default: mode = 0
        }
        let entry = TextLayoutCache.shared.layout(
            font: font,
            text: text,
            availWidth: width,
            mode: mode
        )
        if kind == .text, let limit = textLineLimit, entry.lines.count > limit {
            var visible = Array(entry.lines.prefix(limit))
            if let last = visible.indices.last {
                visible[last] = font.ellipsized(visible[last], availWidth: max(0, width))
            }
            cachedLines = visible
            return YGSize(
                width: entry.width + 8,
                height: font.lineHeight * Float(visible.count) + 4
            )
        }
        cachedLines = entry.lines
        // Padding keeps a slightly larger hit target.
        return YGSize(width: entry.width + 8, height: max(entry.height, font.lineHeight) + 4)
    }

    func markMeasureDirty() {
        if usesTextMeasure {
            YGNodeMarkDirty(yogaStorage)
        }
    }
}

/// No-capture C function pointer for Yoga (Phase 0b pattern).
private func leafTextMeasure(
    _ node: YGNodeConstRef?,
    _ width: Float,
    _ widthMode: YGMeasureMode,
    _ height: Float,
    _ heightMode: YGMeasureMode
) -> YGSize {
    guard let node, let ctx = YGNodeGetContext(node) else {
        return YGSize(width: 0, height: 0)
    }
    let leaf = Unmanaged<LeafNode>.fromOpaque(ctx).takeUnretainedValue()
    return leaf.measureForYoga(width: width, widthMode: widthMode)
}

// MARK: - Stack container (HStack / VStack only)

final class StackNode: YogaBoxNode {
    private(set) var contentNode: any AnyViewNode
    let direction: FlexDirection
    /// Panel background (Phase 3 draw list).
    var fillColor: Color?
    var hoverFill: Color?
    var onClick: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    /// Corner radius for `fillColor`. Set via `.cornerRadius()` modifiers.
    var cornerRadius: Float = 0

    /// Yoga children currently inserted (flattened leaves under content).
    private var insertedLeaves: [any AnyViewNode] = []

    init(
        label: String, direction: FlexDirection, style: StackStyle,
        content: any AnyViewNode, onClick: (() -> Void)?,
        onHover: ((Bool) -> Void)?
    ) {
        self.direction = direction
        self.contentNode = content
        self.onClick = onClick
        self.onHover = onHover
        super.init(label: label)
        YGNodeStyleSetFlexDirection(yogaStorage, direction.yoga)
        apply(style)
        configureHover()
        relinkYogaChildren()
    }

    override var childNodes: [any AnyViewNode] { [contentNode] }

    func update(
        style: StackStyle, contentView: some View,
        onClick: (() -> Void)?, onHover: ((Bool) -> Void)?
    ) {
        apply(style)
        self.onClick = onClick
        self.onHover = onHover
        configureHover()
        contentNode = ViewGraph.reconcile(contentNode, with: contentView)
        relinkYogaChildren()
    }

    private func configureHover() {
        guard let onHover else {
            HoverState.unregister(id)
            return
        }
        HoverState.register(id) { inside in onHover(inside) }
    }

    private func apply(_ style: StackStyle) {
        flexGrow = style.flexGrow
        width = style.width
        height = style.height
        padding = style.padding
        YGNodeStyleSetAlignItems(yogaStorage, style.alignment.yoga)
        YGNodeStyleSetFlexWrap(yogaStorage, style.wraps ? YGWrapWrap : YGWrapNoWrap)
        // Side columns get a solid panel fill; main HStack stays transparent.
        // Re-evaluated every apply (not just at construction) so a theme
        // swap — or a `.theme(_:)` override — reaches it on reconcile too.
        // `.percent` counts as "a side column with a stated width" exactly
        // like `.point` — a proportional panel is still a panel, just one
        // that scales with the window instead of staying fixed.
        switch (direction, style.width) {
        case (.column, .point), (.column, .percent):
            fillColor = Environment.current.theme.panel
        default:
            break
        }
        applyStyle()
    }

    /// Detach old leaves, insert flattened content. Old leaf *nodes* are kept
    /// alive via `contentNode` if still in the tree; dropped fragments free via ARC.
    private func relinkYogaChildren() {
        YGNodeRemoveAllChildren(yogaStorage)
        insertedLeaves = contentNode.flattenedLayoutNodes()
        for (i, leaf) in insertedLeaves.enumerated() {
            guard let y = leaf.yoga else { continue }
            YGNodeInsertChild(yogaStorage, y, i)
        }
    }

    override func collectChildFrames(
        originX: Float, originY: Float, into frames: inout [LayoutFrame]
    ) {
        // Walk retained tree (includes fragments for labels) in z-order.
        contentNode.collectFrames(originX: originX, originY: originY, into: &frames)
    }
}

// MARK: - Fragment nodes (no Yoga box)

/// Base for nodes that only group children.
class FragmentNode: AnyViewNode {
    let id: NodeID
    var label: String
    var agentId: String?
    var structuralKey: String?
    var needsBodyRecompute = false

    /// Children the view tree currently describes.
    private(set) var liveChildren: [any AnyViewNode] = []
    /// Children removed from the view tree but still animating out.
    private(set) var departingChildren: [any AnyViewNode] = []

    /// Both, so layout, emit and frame collection see a departing child
    /// without any of them needing to know it is departing. Keeping it in the
    /// flow is deliberate: dropping it from layout the instant it starts
    /// fading makes the content jump, which is the thing the animation exists
    /// to avoid.
    var childNodes: [any AnyViewNode] {
        departingChildren.isEmpty ? liveChildren : liveChildren + departingChildren
    }

    var yoga: YGNodeRef? { nil }

    init(label: String, children: [any AnyViewNode] = []) {
        self.id = .generate()
        self.label = label
        self.liveChildren = children
    }

    /// Replaces the children, animating whatever arrived or left.
    ///
    /// Every reconciler that can insert or remove a child routes through here,
    /// so the transition rules exist once rather than three times in
    /// `EitherView`, `OptionalView` and `ForEach`.
    func setChildren(_ next: [any AnyViewNode]) {
        let nextIDs = Set(next.map(\.id))
        let oldIDs = Set(liveChildren.map(\.id))

        for old in liveChildren where !nextIDs.contains(old.id) {
            guard let box = old as? YogaBoxNode,
                  let transition = box.transitionState
            else { continue }  // no transition: dropped now, ARC frees it
            departingChildren.append(old)
            transition.leave { [weak self, weak old] in
                guard let self, let old else { return }
                self.departingChildren.removeAll { $0.id == old.id }
            }
        }

        for child in next where !oldIDs.contains(child.id) {
            (child as? YogaBoxNode)?.transitionState?.enter()
        }

        liveChildren = next
    }

    func collectFrames(originX: Float, originY: Float, into frames: inout [LayoutFrame]) {
        // No box of our own — children already laid out by an ancestor stack.
        for child in childNodes {
            child.collectFrames(originX: originX, originY: originY, into: &frames)
        }
    }
}

/// Composite user view (`EditorChrome`): forwards to `body` node.
///
/// `@unchecked Sendable` so `computeBody()` can weak-capture `self` in
/// `withObservationTracking`'s `@Sendable onChange` — UI construction is
/// single-threaded (frame loop), same as `Editor`.
final class CompositeNode<V: View>: FragmentNode, BodyRecomputable, @unchecked Sendable {
    var view: V

    /// The window this node was mounted into. Captured here rather than read
    /// at invalidation time because the write that dirties this node can come
    /// from any window — see `BodyRecomputable.invalidationScope`. Mounting
    /// always happens inside the owning window's frame phase, so the ambient
    /// scope is correct exactly once: now.
    let invalidationScope: WindowScope?

    init(_ view: V) {
        self.view = view
        self.invalidationScope = WindowScope.currentOrMain
        super.init(label: String(describing: V.self))
        setChildren([ViewGraph.mount(computeBody())])
    }

    func update(_ newView: V) {
        // The parent handed us a freshly built struct, so its `@State` is new.
        // Re-attach the storage the old copy owned before anything reads it —
        // reading `newView.body` first would observe reset state.
        StateTransfer.adopt(into: newView, from: view)
        view = newView
        reconcileBody()
    }

    /// Re-evaluates `body` against the `view` already stored — no new value
    /// from a parent, because nothing about *it* changed; only some
    /// `@State`/`@Observable` property it reads did, and that storage is a
    /// reference type living outside the struct, so it's already current.
    /// Called when `ViewInvalidation` tracked this node specifically as
    /// dirty, so a change here does not force every unrelated node's body
    /// to run again too.
    func recomputeBody() {
        reconcileBody()
    }

    private func reconcileBody() {
        needsBodyRecompute = true
        let body = computeBody()
        if let existing = liveChildren.first {
            setChildren([ViewGraph.reconcile(existing, with: body)])
        } else {
            setChildren([ViewGraph.mount(body)])
        }
        needsBodyRecompute = false
    }

    /// Evaluates `body` while recording which observable properties it read.
    ///
    /// Two things about `withObservationTracking` that shape this:
    ///
    /// - `onChange` fires *before* the new value is written, so it must never
    ///   read state. Marking this node dirty is all it does.
    /// - It fires at most once per registration. Re-registration happens
    ///   implicitly here, because every re-render recomputes bodies. A path
    ///   that skips `computeBody()` would silently unsubscribe that node.
    private func computeBody() -> V.Body {
        var body: V.Body!
        withObservationTracking {
            body = view.body
        } onChange: { [weak self] in
            guard let self else { return }
            ViewInvalidation.markBodyDirty(self)
        }
        return body
    }
}

/// TupleView: fixed heterogeneous children, each a retained node.
final class TupleFragmentNode: FragmentNode {
    init(children: [any AnyViewNode]) {
        super.init(label: "TupleView", children: children)
    }
}

/// EitherView: one active branch retained across flips of the same case.
final class EitherFragmentNode: FragmentNode {
    enum Active {
        case first(any AnyViewNode)
        case second(any AnyViewNode)
    }

    private var active: Active?

    init() {
        super.init(label: "EitherView", children: [])
    }

    func updateFirst<A: View>(_ view: A) {
        label = "EitherView.first"
        if case .first(let node) = active {
            let n = ViewGraph.reconcile(node, with: view)
            active = .first(n)
            setChildren([n])
        } else {
            let n = ViewGraph.mount(view)
            active = .first(n)
            setChildren([n])
        }
    }

    func updateSecond<B: View>(_ view: B) {
        label = "EitherView.second"
        if case .second(let node) = active {
            let n = ViewGraph.reconcile(node, with: view)
            active = .second(n)
            setChildren([n])
        } else {
            let n = ViewGraph.mount(view)
            active = .second(n)
            setChildren([n])
        }
    }
}

/// OptionalView: zero or one child.
final class OptionalFragmentNode: FragmentNode {
    init() {
        super.init(label: "OptionalView", children: [])
    }

    func updateSome<V: View>(_ view: V) {
        label = "OptionalView.some"
        if let existing = liveChildren.first {
            setChildren([ViewGraph.reconcile(existing, with: view)])
        } else {
            setChildren([ViewGraph.mount(view)])
        }
    }

    func updateNone() {
        label = "OptionalView.none"
        setChildren([])
    }
}

/// ForEach: keyed child list (structural recon).
final class ForEachFragmentNode<ID: Hashable>: FragmentNode {
    private var keyed: [(id: ID, node: any AnyViewNode)] = []

    init() {
        super.init(label: "ForEach", children: [])
    }

    func update<Data: RandomAccessCollection, Content: View>(
        data: Data,
        idKeyPath: KeyPath<Data.Element, ID>,
        content: (Data.Element) -> Content
    ) {
        var oldMap = Dictionary(uniqueKeysWithValues: keyed.map { ($0.id, $0.node) })
        var next: [(id: ID, node: any AnyViewNode)] = []
        next.reserveCapacity(data.count)

        for element in data {
            let key = element[keyPath: idKeyPath]
            let childView = content(element)
            let childNode: any AnyViewNode
            if let existing = oldMap.removeValue(forKey: key) {
                childNode = ViewGraph.reconcile(existing, with: childView)
            } else {
                childNode = ViewGraph.mount(childView)
            }
            // Structural path uses the ForEach key so list order changes do not
            // rename other rows (and agents can target `…/item-3/…`).
            childNode.structuralKey = "k:\(key)"
            next.append((key, childNode))
        }
        // Remaining oldMap entries drop out of `keyed` → ARC frees nodes.
        keyed = next
        setChildren(next.map(\.node))
        label = "ForEach[\(next.count)]"
    }
}

// MARK: - LayoutHost

/// Owns the retained root and runs Yoga layout.
public final class LayoutHost {
    private var root: (any AnyViewNode)?
    /// Generations of setRoot — for tests / dumps.
    public private(set) var reconcileCount = 0
    public private(set) var mountCount = 0

    /// Committed layout from the last `calculateLayout` (hit-test / queries read this).
    public private(set) var lastFrames: [LayoutFrame] = []
    public private(set) var lastLayoutWidth: Float = 0
    public private(set) var lastLayoutHeight: Float = 0
    private var layoutValid = false

    public init() {}

    public var rootID: NodeID? { root?.id }

    public func setRoot<V: View>(_ view: V) {
        if let existing = root {
            root = ViewGraph.reconcile(existing, with: view)
            reconcileCount += 1
        } else {
            root = ViewGraph.mount(view)
            mountCount += 1
        }
        // Structure/style may have changed — next hit-test must not use stale frames
        // until the frame loop lays out again.
        layoutValid = false
    }

    /// Layout into a definite viewport size (window / body pixels).
    ///
    /// The root Yoga node is given an **exact** width/height matching the
    /// viewport. With `width: auto` alone, Yoga sizes the root to its content
    /// and `flexGrow` children never receive free space — so after a window
    /// resize the UI stayed content-sized (black empty region). Setting
    /// definite root dimensions is the standard full-window Yoga pattern.
    @discardableResult
    public func calculateLayout(width: Float, height: Float) -> [LayoutFrame] {
        guard let root else {
            lastFrames = []
            layoutValid = false
            return []
        }
        PerfCounters.layoutPasses &+= 1
        let boxes = root.flattenedLayoutNodes()
        guard let yogaRoot = boxes.first?.yoga else {
            lastFrames = []
            layoutValid = false
            return []
        }

        let w = max(1, width)
        let h = max(1, height)
        let sizeChanged =
            !layoutValid
            || abs(w - lastLayoutWidth) > 0.5
            || abs(h - lastLayoutHeight) > 0.5

        // Full-window root: exact size so flexGrow children receive free space.
        // Re-apply every pass — reconcile's applyStyle may have reset auto.
        YGNodeStyleSetWidth(yogaRoot, w)
        YGNodeStyleSetHeight(yogaRoot, h)
        // Min size tracks the viewport so a stale content-sized layout cannot
        // "win" against a larger window if Yoga skips a dirty path.
        YGNodeStyleSetMinWidth(yogaRoot, w)
        YGNodeStyleSetMinHeight(yogaRoot, h)

        if sizeChanged {
            // Measure leaves cache by constraint; force remeasure when the
            // viewport changes (panel AtMost widths can change with chrome).
            markAllMeasureLeavesDirty(root)
        }

        YGNodeCalculateLayout(yogaRoot, w, h, YGDirectionLTR)

        // Virtualized containers can only size themselves and choose a window
        // once they have a real width, a real position, and their scroll
        // container's height — none of which exist until Yoga has run. So they
        // settle afterwards, and settling can change geometry (a new column
        // count, a new content height, newly mounted cells), which needs
        // another pass.
        //
        // This converges rather than oscillating: the second pass changes the
        // window only if the first pass's own geometry change moved it, and
        // that is a fixed point. The bound is a safety net, not the mechanism —
        // if it is ever hit, something is genuinely thrashing and a stale
        // window for one frame is better than a hang.
        var settlePasses = 0
        while settleLazyWindows(root), settlePasses < 3 {
            YGNodeCalculateLayout(yogaRoot, w, h, YGDirectionLTR)
            settlePasses += 1
        }

        var frames: [LayoutFrame] = []
        boxes[0].collectFrames(originX: 0, originY: 0, into: &frames)
        lastFrames = frames
        lastLayoutWidth = w
        lastLayoutHeight = h
        layoutValid = true
        return frames
    }

    /// Lets every virtualized container re-window against fresh geometry.
    /// Returns whether any of them changed something layout depends on.
    private func settleLazyWindows(_ node: any AnyViewNode) -> Bool {
        var changed = false
        for grid in LazyGrid.nodes(in: node) {
            if grid.settleWindow() { changed = true }
        }
        return changed
    }

    private func markAllMeasureLeavesDirty(_ node: any AnyViewNode) {
        if let leaf = node as? LeafNode {
            leaf.markMeasureDirty()
        }
        for child in node.childNodes {
            markAllMeasureLeavesDirty(child)
        }
    }

    /// After `FontStore` content-scale change: force every text leaf to
    /// re-measure on the next `calculateLayout` (library helper).
    public func invalidateTextMetrics() {
        layoutValid = false
        if let root {
            markAllMeasureLeavesDirty(root)
        }
    }

    public func dumpFrames(width: Float, height: Float) {
        let frames = calculateLayout(width: width, height: height)
        FileHandle.standardError.write(
            Data("--- Phase 2 layout \(Int(width))×\(Int(height)) ---\n".utf8)
        )
        FileHandle.standardError.write(
            Data(
                "root id=\(root?.id.raw ?? 0) mounts=\(mountCount) reconciles=\(reconcileCount)\n"
                    .utf8
            )
        )
        for f in frames {
            FileHandle.standardError.write(Data((f.description + "\n").utf8))
        }
        FileHandle.standardError.write(Data("--- end layout ---\n".utf8))
    }

    public var rootNode: (any AnyViewNode)? { root }

    /// Frames from the most recent layout, for frames that only redraw.
    public var lastLayoutFrames: [LayoutFrame] { lastFrames }

    /// Diagram host from **committed** layout — does not re-run Yoga.
    public func diagramHostFrame() -> LayoutFrame? {
        guard layoutValid else { return nil }
        return lastFrames.first(where: { $0.label == "DiagramHost" })
    }

    /// Reverse-z hit test against **committed** Yoga geometry (no re-layout).
    /// `originY` matches emit offset (menu bar). Window-pixel coordinates.
    public func hitTestClick(
        x: Float, y: Float,
        originX: Float = 0, originY: Float = 0,
        mods: Int32 = 0
    ) -> (() -> Void)? {
        guard layoutValid, let root else { return nil }

        // Overlays first, topmost down. Two rules a menu has to obey and the
        // main tree cannot express: a click on the popup must not fall through
        // to whatever it covers, and a click outside must dismiss it rather
        // than activate what it landed on.
        let overlays = OverlayScan.presented(in: root)
        if !overlays.isEmpty {
            for att in overlays.reversed() {
                guard let overlayRoot = att.root else { continue }
                if let hit = hitWalk(
                    overlayRoot, x: x, y: y,
                    ox: originX + att.origin.x, oy: originY + att.origin.y, mods: mods
                ) {
                    return hit
                }
                // Inside the panel but on an inert part: swallow, so the click
                // neither dismisses nor reaches the content below.
                if att.contains(x - originX, y - originY) { return {} }
            }
            return { for att in overlays { att.dismiss() } }
        }

        return hitWalk(root, x: x, y: y, ox: originX, oy: originY, mods: mods)
    }

    /// Topmost interactive node under the pointer, for hover highlighting.
    public func hitTestHover(
        x: Float, y: Float, originX: Float = 0, originY: Float = 0
    ) -> NodeID? {
        guard layoutValid, let root else { return nil }

        for att in OverlayScan.presented(in: root).reversed() {
            guard let overlayRoot = att.root else { continue }
            if let id = hoverWalk(
                overlayRoot, x: x, y: y,
                ox: originX + att.origin.x, oy: originY + att.origin.y
            ) {
                return id
            }
            // Hovering the panel must not highlight what is underneath it.
            if att.contains(x - originX, y - originY) { return nil }
        }

        return hoverWalk(root, x: x, y: y, ox: originX, oy: originY)
    }

    /// Every node under the pointer that a wheel event may be offered to,
    /// innermost first.
    ///
    /// Hover resolves exactly *one* node, which is right for highlighting and
    /// wrong for the wheel: a button, text field, or canvas sitting inside a
    /// `ScrollView` is the topmost hit, so routing by hover alone let it mask
    /// the container and a notch over it scrolled nothing. This keeps the whole
    /// ancestor path instead so `ScrollRouter` can bubble. Deliberately a
    /// separate walk — hover and click targeting stay exactly as they were.
    public func hitTestScrollChain(
        x: Float, y: Float, originX: Float = 0, originY: Float = 0
    ) -> [NodeID] {
        guard layoutValid, let root else { return [] }
        var chain: [NodeID] = []

        for att in OverlayScan.presented(in: root).reversed() {
            guard let overlayRoot = att.root else { continue }
            if scrollChainWalk(
                overlayRoot, x: x, y: y,
                ox: originX + att.origin.x, oy: originY + att.origin.y,
                into: &chain
            ) {
                return chain
            }
            // A wheel over the panel must not scroll what is underneath it,
            // same rule hover follows.
            if att.contains(x - originX, y - originY) { return [] }
        }

        _ = scrollChainWalk(root, x: x, y: y, ox: originX, oy: originY, into: &chain)
        return chain
    }

    /// Dismisses everything presented. Returns true if anything was showing,
    /// so a key handler can tell whether it consumed the event.
    @discardableResult
    public func dismissOverlays() -> Bool {
        guard let root else { return false }
        let overlays = OverlayScan.presented(in: root)
        guard !overlays.isEmpty else { return false }
        for att in overlays { att.dismiss() }
        return true
    }

    private func hoverWalk(
        _ node: any AnyViewNode, x: Float, y: Float, ox: Float, oy: Float
    ) -> NodeID? {
        // A departing subtree is still drawn but is no longer part of the view
        // tree, so it must not answer for input on the way out.
        if let box = node as? YogaBoxNode, box.transitionState?.isLeaving == true {
            return nil
        }
        if let box = node as? YogaBoxNode, let yref = box.yoga {
            let nx = ox + YGNodeLayoutGetLeft(yref)
            let ny = oy + YGNodeLayoutGetTop(yref)
            let nw = YGNodeLayoutGetWidth(yref)
            let nh = YGNodeLayoutGetHeight(yref)
            for child in node.childNodes.reversed() {
                let shift = box.childOffset
                if let h = hoverWalk(
                    child, x: x, y: y, ox: nx - shift.x, oy: ny - shift.y
                ) { return h }
            }
            // Scrollables count as hover targets too: the wheel routes by what
            // is under the pointer, and neither an editor nor a ScrollView has
            // a hover fill. Checked on the box, not the leaf, so containers
            // qualify — but only *after* children, so an inner scrollable wins.
            if x >= nx, x < nx + nw, y >= ny, y < ny + nh {
                if let leaf = node as? LeafNode,
                   leaf.hoverFill != nil || leaf.hoverColor != nil || leaf.onHover != nil
                {
                    leaf.onPointerHoverLocal?(x - nx, y - ny)
                    return leaf.id
                }
                if let stack = node as? StackNode,
                   stack.hoverFill != nil || stack.onHover != nil
                {
                    return stack.id
                }
                if box.isScrollable { return box.id }
                // A `.onDrop()` target has no visual hover feedback of its
                // own — this is the only thing that makes it resolvable at
                // drop time at all, on a container as much as a leaf.
                if DropRouter.hasHandler(box.id) { return box.id }
            }
            return nil
        }
        for child in node.childNodes.reversed() {
            if let h = hoverWalk(child, x: x, y: y, ox: ox, oy: oy) { return h }
        }
        return nil
    }

    /// Appends the hit node and then each of its ancestors, so `chain` comes
    /// out innermost-first. Returns whether this subtree claimed the point.
    ///
    /// Mirrors `hoverWalk`'s geometry exactly — children before self, shifted
    /// by `childOffset` — but has no interest in whether a node is an
    /// interactive target: an inert `VStack` between a button and its
    /// `ScrollView` still has to appear so the walk can reach the container.
    private func scrollChainWalk(
        _ node: any AnyViewNode, x: Float, y: Float, ox: Float, oy: Float,
        into chain: inout [NodeID]
    ) -> Bool {
        if let box = node as? YogaBoxNode, box.transitionState?.isLeaving == true {
            return false
        }
        if let box = node as? YogaBoxNode, let yref = box.yoga {
            let nx = ox + YGNodeLayoutGetLeft(yref)
            let ny = oy + YGNodeLayoutGetTop(yref)
            let nw = YGNodeLayoutGetWidth(yref)
            let nh = YGNodeLayoutGetHeight(yref)
            var hit = false
            for child in node.childNodes.reversed() {
                let shift = box.childOffset
                if scrollChainWalk(
                    child, x: x, y: y, ox: nx - shift.x, oy: ny - shift.y, into: &chain
                ) {
                    hit = true
                    break
                }
            }
            // An ancestor of a hit child belongs in the chain whether or not
            // the point is inside its own box — overflowing scroll content is
            // the whole reason a child can be hit outside its container.
            if hit || (x >= nx && x < nx + nw && y >= ny && y < ny + nh) {
                chain.append(box.id)
                return true
            }
            return false
        }
        for child in node.childNodes.reversed() {
            if scrollChainWalk(child, x: x, y: y, ox: ox, oy: oy, into: &chain) {
                return true
            }
        }
        return false
    }

    private func hitWalk(
        _ node: any AnyViewNode,
        x: Float, y: Float,
        ox: Float, oy: Float,
        mods: Int32
    ) -> (() -> Void)? {
        // Clicking something that is fading out would run an action the view
        // tree no longer describes.
        if let box = node as? YogaBoxNode, box.transitionState?.isLeaving == true {
            return nil
        }
        if let box = node as? YogaBoxNode, let yref = box.yoga {
            let nx = ox + YGNodeLayoutGetLeft(yref)
            let ny = oy + YGNodeLayoutGetTop(yref)
            let nw = YGNodeLayoutGetWidth(yref)
            let nh = YGNodeLayoutGetHeight(yref)
            // Children front-to-back.
            for child in node.childNodes.reversed() {
                let shift = box.childOffset
                if let h = hitWalk(
                    child, x: x, y: y, ox: nx - shift.x, oy: ny - shift.y, mods: mods
                ) { return h }
            }
            if let leaf = node as? LeafNode,
               x >= nx, x < nx + nw, y >= ny, y < ny + nh
            {
                if let local = leaf.onClickLocal {
                    let lx = x - nx
                    let ly = y - ny
                    return { local(lx, ly, nx, ny, mods) }
                }
                if let click = leaf.onClick, leaf.kind == .text || leaf.kind == .image {
                    return click
                }
            }
            if let stack = node as? StackNode, let click = stack.onClick,
               x >= nx, x < nx + nw, y >= ny, y < ny + nh
            {
                return click
            }
            return nil
        }
        for child in node.childNodes.reversed() {
            if let h = hitWalk(child, x: x, y: y, ox: ox, oy: oy, mods: mods) { return h }
        }
        return nil
    }
}

#else

import Foundation

public enum FlexDirection { case row, column }

public struct LayoutFrame: Sendable, Equatable {
    public var label: String
    public var x: Float, y: Float, w: Float, h: Float
    public var description: String { label }
}

public protocol AnyViewNode: AnyObject {
    var id: NodeID { get }
    var label: String { get }
    var childNodes: [any AnyViewNode] { get }
    var needsBodyRecompute: Bool { get set }
    var agentId: String? { get set }
    var structuralKey: String? { get set }
    func collectFrames(originX: Float, originY: Float, into: inout [LayoutFrame])
    func flattenedLayoutNodes() -> [any AnyViewNode]
}

public final class LayoutHost {
    public private(set) var reconcileCount = 0
    public private(set) var mountCount = 0
    public var rootID: NodeID? { nil }
    public var rootNode: (any AnyViewNode)? { nil }
    public init() {}
    public func setRoot<V: View>(_ view: V) {}
    public func calculateLayout(width: Float, height: Float) -> [LayoutFrame] { [] }
    public func dumpFrames(width: Float, height: Float) {
        FileHandle.standardError.write(Data("Phase 2: CYoga unavailable\n".utf8))
    }
    public private(set) var lastFrames: [LayoutFrame] = []
    public func diagramHostFrame() -> LayoutFrame? { nil }
    public func hitTestClick(x: Float, y: Float, originX: Float = 0, originY: Float = 0) -> (() -> Void)? { nil }
}

// Minimal stubs so primitives compile without CYoga.
enum LeafKind: Equatable { case text, spacer, diagramHost, empty, image, textField, editor, button, toggle, slider, divider, canvas, scene3D }

final class LeafNode: AnyViewNode {
    let id = NodeID.generate()
    let kind: LeafKind
    var label: String
    var agentId: String?
    var structuralKey: String?
    var needsBodyRecompute = false
    var text = ""
    var color = Color.primary
    var onClick: (() -> Void)?
    var onClickLocal: ((Float, Float, Float, Float) -> Void)?
    var editing = TextEditingState("")
    var placeholder = ""
    var isMultiline = false
    var maxLines = 8
    var wraps = false
    /// Last width Yoga gave this leaf, used to wrap on the next pass.
    var lastMeasuredWidth: Float = 0
    var hoverFill: Color?
    var cornerRadius: Float = 0
    var onHover: ((Bool) -> Void)?
    var fillColor: Color?
    var childNodes: [any AnyViewNode] { [] }
    init(kind: LeafKind, label: String, width: Dimension, height: Dimension, flexGrow: Float = 0, minWidth: Float = 0) {
        self.kind = kind
        self.label = label
    }
    func update(label: String, width: Dimension, height: Dimension, flexGrow: Float = 0, minWidth: Float = 0, text: String = "", color: Color = .primary, onClick: (() -> Void)? = nil) {
        self.label = label
        self.text = text
        self.color = color
        self.onClick = onClick
    }
    func collectFrames(originX: Float, originY: Float, into frames: inout [LayoutFrame]) {}
    func flattenedLayoutNodes() -> [any AnyViewNode] { [self] }
}

final class StackNode: AnyViewNode {
    let id = NodeID.generate()
    var label: String
    var agentId: String?
    var structuralKey: String?
    var needsBodyRecompute = false
    var fillColor: Color?
    let direction: FlexDirection
    var childNodes: [any AnyViewNode]
    init(label: String, direction: FlexDirection, style: StackStyle, content: any AnyViewNode) {
        self.label = label
        self.direction = direction
        self.childNodes = [content]
    }
    func update(style: StackStyle, contentView: some View) {}
    func collectFrames(originX: Float, originY: Float, into frames: inout [LayoutFrame]) {}
    func flattenedLayoutNodes() -> [any AnyViewNode] { [self] }
}

final class CompositeNode<V: View>: AnyViewNode {
    let id = NodeID.generate()
    var label: String { String(describing: V.self) }
    var agentId: String?
    var structuralKey: String?
    var needsBodyRecompute = false
    var childNodes: [any AnyViewNode] = []
    init(_ view: V) {}
    func update(_ newView: V) {}
    func collectFrames(originX: Float, originY: Float, into frames: inout [LayoutFrame]) {}
    func flattenedLayoutNodes() -> [any AnyViewNode] { [] }
}

final class TupleFragmentNode: AnyViewNode {
    let id = NodeID.generate()
    var label = "TupleView"
    var agentId: String?
    var structuralKey: String?
    var needsBodyRecompute = false
    var childNodes: [any AnyViewNode]
    init(children: [any AnyViewNode]) { self.childNodes = children }
    func collectFrames(originX: Float, originY: Float, into frames: inout [LayoutFrame]) {}
    func flattenedLayoutNodes() -> [any AnyViewNode] { childNodes.flatMap { $0.flattenedLayoutNodes() } }
}

final class EitherFragmentNode: AnyViewNode {
    let id = NodeID.generate()
    var label = "EitherView"
    var agentId: String?
    var structuralKey: String?
    var needsBodyRecompute = false
    var childNodes: [any AnyViewNode] = []
    func updateFirst<A: View>(_ view: A) {}
    func updateSecond<B: View>(_ view: B) {}
    func collectFrames(originX: Float, originY: Float, into frames: inout [LayoutFrame]) {}
    func flattenedLayoutNodes() -> [any AnyViewNode] { childNodes.flatMap { $0.flattenedLayoutNodes() } }
}

final class OptionalFragmentNode: AnyViewNode {
    let id = NodeID.generate()
    var label = "OptionalView"
    var agentId: String?
    var structuralKey: String?
    var needsBodyRecompute = false
    var childNodes: [any AnyViewNode] = []
    func updateSome<V: View>(_ view: V) {}
    func updateNone() {}
    func collectFrames(originX: Float, originY: Float, into frames: inout [LayoutFrame]) {}
    func flattenedLayoutNodes() -> [any AnyViewNode] { childNodes.flatMap { $0.flattenedLayoutNodes() } }
}

final class ForEachFragmentNode<ID: Hashable>: AnyViewNode {
    let id = NodeID.generate()
    var label = "ForEach"
    var agentId: String?
    var structuralKey: String?
    var needsBodyRecompute = false
    var childNodes: [any AnyViewNode] = []
    func update<Data: RandomAccessCollection, Content: View>(
        data: Data, idKeyPath: KeyPath<Data.Element, ID>, content: (Data.Element) -> Content
    ) {}
    func collectFrames(originX: Float, originY: Float, into frames: inout [LayoutFrame]) {}
    func flattenedLayoutNodes() -> [any AnyViewNode] { childNodes.flatMap { $0.flattenedLayoutNodes() } }
}

#endif
