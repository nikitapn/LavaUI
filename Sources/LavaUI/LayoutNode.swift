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

/// Whether a freshly flattened child list differs from the one currently
/// inserted into Yoga.
///
/// Almost never, which is the entire point of reconciling: the same nodes come
/// back in the same order, and only an insert, a removal or a reorder changes
/// that. Relinking anyway is neither free nor cheap —
/// `YGNodeRemoveAllChildren` discards every child's layout and
/// `YGNodeInsertChild` dirties the container and every ancestor above it. Done
/// unconditionally by every container on every body pass, it handed Yoga a
/// fully dirty tree with nothing left to skip: measured on a 560-row list
/// where one label changed, 2249 of 2813 nodes dirty and 4.0 ms in
/// `YGNodeCalculateLayout`. Skipping the relink when nothing moved took that
/// to 6 nodes and 0.6 ms.
///
/// Identity, not equality: these are the same node objects reconcile returned,
/// so `===` is the exact question — one pointer compare per child, against a
/// walk of the whole subtree.
func yogaChildrenChanged(
    _ leaves: [any AnyViewNode], _ inserted: [any AnyViewNode]
) -> Bool {
    guard leaves.count == inserted.count else { return true }
    for (new, old) in zip(leaves, inserted) where new !== old { return true }
    return false
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
    var padding: EdgeInsets = .zero
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

    /// Whether children outside this box's rect are off screen.
    ///
    /// Emit scissors both cases, so the input walks have to agree with it or
    /// they answer for pixels nobody can see: a menu row scrolled past the
    /// top of its list still has a layout rect, and it sits exactly where the
    /// menu bar above the popup is drawn. Clicking a title would have run it.
    var clipsChildren: Bool { isScrollable || clipsContent }
    /// Out of layout and drawing, but still mounted. See `View.hidden(_:)`.
    var isHidden: Bool = false
    /// Pointer image while the pointer is inside this box (`View.cursor(_:)`).
    /// Nil inherits whatever an ancestor asked for, and an arrow if none did.
    var cursor: CursorShape?

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

    /// A press anywhere in this box that no child claimed.
    ///
    /// On the *press*, not the release, and that is the whole reason it is not
    /// `onClick`: the one thing using it is a window drag region, where the
    /// gesture is "the pointer went down on the chrome" and everything after
    /// belongs to whoever moves the window. Children win — a button in a
    /// toolbar that also drags the window is still a button — because
    /// `hitWalk` reaches them first.
    var onBoxPress: ((_ localX: Float, _ localY: Float, _ mods: Int32) -> Void)?
    /// Chrome this box paints *over* its own content, and which therefore has
    /// to be offered the pointer before the content is.
    ///
    /// `hitWalk` goes children-first, which is right for everything laid out:
    /// what is nested is on top. A scrollbar is not nested — it is painted
    /// after the subtree, on the edge of the box, over whatever happens to be
    /// there — so children-first would hand a press on the thumb to the row
    /// underneath it.
    ///
    /// Returns the action to run, or nil to decline and let the walk carry on
    /// into the children. An action rather than a `Bool` because a hit test
    /// must not have side effects: `hitTestClick` is asked on paths that only
    /// want to know whether *anything* would take the click.
    var onOverlayPress: ((
        _ localX: Float, _ localY: Float, _ originX: Float, _ originY: Float
    ) -> (() -> Void)?)?

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
        // `display: none` rather than a zero size: Yoga skips the subtree
        // entirely, so a hidden pane costs no measurement, and — the part that
        // matters — its children keep their nodes and therefore their ids.
        YGNodeStyleSetDisplay(yogaStorage, isHidden ? YGDisplayNone : YGDisplayFlex)
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
        // LTR mapping: leading → left, trailing → right. A future layout-
        // direction environment remaps here rather than renaming EdgeInsets.
        // Uniform / axis-paired values collapse to Yoga's grouped edges so the
        // common `.padding(8)` path stays a single style write.
        if padding.top == padding.bottom,
           padding.leading == padding.trailing,
           padding.top == padding.leading
        {
            YGNodeStyleSetPadding(yogaStorage, YGEdgeAll, padding.top)
        } else if padding.leading == padding.trailing,
                  padding.top == padding.bottom
        {
            YGNodeStyleSetPadding(yogaStorage, YGEdgeHorizontal, padding.leading)
            YGNodeStyleSetPadding(yogaStorage, YGEdgeVertical, padding.top)
        } else {
            YGNodeStyleSetPadding(yogaStorage, YGEdgeTop, padding.top)
            YGNodeStyleSetPadding(yogaStorage, YGEdgeLeft, padding.leading)
            YGNodeStyleSetPadding(yogaStorage, YGEdgeBottom, padding.bottom)
            YGNodeStyleSetPadding(yogaStorage, YGEdgeRight, padding.trailing)
        }
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
        // Nothing here is on screen, and the frames its children still carry
        // are where they were when it last was. An agent searching the tree
        // would otherwise find and click a row on a page nobody is looking at.
        if isHidden { return }
        let x = originX + YGNodeLayoutGetLeft(yogaStorage)
        let y = originY + YGNodeLayoutGetTop(yogaStorage)
        let w = YGNodeLayoutGetWidth(yogaStorage)
        let h = YGNodeLayoutGetHeight(yogaStorage)
        frames.append(LayoutFrame(label: label, x: x, y: y, w: w, h: h))
        let shift = childOffset
        collectChildFrames(originX: x - shift.x, originY: y - shift.y, into: &frames)
    }

    func collectChildFrames(originX: Float, originY: Float, into frames: inout [LayoutFrame]) {}

    /// Box size from the last layout pass. Zero before there has been one.
    var boxWidth: Float { YGNodeLayoutGetWidth(yogaStorage) }
    var boxHeight: Float { YGNodeLayoutGetHeight(yogaStorage) }
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
    /// Two-stop linear fill; wins over `fillColor` when set.
    var fillGradient: Gradient?
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
    var editing = TextEditingState("")
    /// Last character offset resolved to a `String.Index`, and the buffer
    /// version it was resolved against.
    ///
    /// `TextEditingState.index(atOffset:)` walks from `startIndex` on every
    /// call. The draw path needs the first visible row's index once per
    /// redraw, so an editor scrolled to the end of a 10 MB log paid a
    /// full-buffer walk per frame — including every frame a blinking caret
    /// causes, at ~25ms each. Scrolling moves that offset by a few rows, so
    /// resolving from the previous answer makes the steady state a few
    /// characters instead.
    ///
    /// Keyed on `revision`, which changes only when the *text* does. It used
    /// to be dropped on any write to `editing` at all, on the grounds that a
    /// cursor move could not invalidate it and paying for one anyway was
    /// nothing. That was wrong in the one case it mattered: a drag-select
    /// writes the cursor on every pointer move, so the anchor was empty
    /// exactly when the walks it exists to prevent were being made, and
    /// dragging near the end of a large file paid several full-buffer walks
    /// per move (`LAVA_EDITOR_PROBE=1` shows them).
    private var indexAnchor: (revision: UInt64, offset: Int, index: String.Index)?
    var placeholder: String = ""
    var isMultiline = false
    var maxLines = 8
    var wraps = false
    /// Per-field focus chrome override; nil falls through to `theme.focusRing*`.
    var focusRingStyle: FocusRingStyle?
    var focusRingWidth: Float?
    var focusRingColor: Color?
    /// Button-only payload.
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
    /// Where the pointer is *inside* this leaf, for a widget that does its own
    /// picking.
    ///
    /// The renderer answers which node the pointer is over, which is all a
    /// tint or an `onHover` needs. It cannot answer where inside one, because
    /// that means the widget's own geometry — for a `Scene3D`, the projection
    /// of a 3D scene it has never seen. So this one question comes back to the
    /// producer, and `LocalHoverTargets` keeps the cost of asking it
    /// proportional to how many widgets actually care.
    var onPointerHoverLocal: ((_ localX: Float, _ localY: Float) -> Void)? {
        didSet {
            LocalHoverTargets.track(
                had: oldValue != nil, has: onPointerHoverLocal != nil
            )
        }
    }

    deinit {
        // A leaf can go away with its handler still installed — an unmount, a
        // window closing — and the count has to come back down, or the walk
        // stays switched on for a widget that no longer exists.
        LocalHoverTargets.track(had: onPointerHoverLocal != nil, has: false)
    }
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
    /// Keyed on `wraps` as well as font and text: the answer is ranked over
    /// the *row* table, and the same buffer at the same size has entirely
    /// different rows depending on whether it is being wrapped. Without it,
    /// turning wrap off left `maxScrollX` reporting the width of rows built to
    /// fit the viewport — which is to say zero scroll for a line that now
    /// overflows it.
    private var widestRowCache:
        (fontIdentity: String, text: String, wraps: Bool, width: Float)?

    /// The candidate rows the cached width was measured from, as index and
    /// character length interleaved — the second, cheaper key. See
    /// `widestRowWidth`.
    private var widestRowShape: [Int] = []

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
        if let c = widestRowCache, c.fontIdentity == font.identity, c.text == editing.text,
           c.wraps == wraps
        {
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
        // Second key: which rows are the longest, and how long they are.
        //
        // The text key above misses on *every* edit, and the miss is not
        // cheap — `rowTexts` walks the buffer to reach candidates that can be
        // anywhere in it, which was 45% of what a keystroke cost on a 4 MB
        // log. But the ranking is integer work over a table layout already
        // built, so it can be recomputed and compared for microseconds, and
        // an edit that leaves the longest rows exactly as long as they were
        // cannot have changed the answer by more than the substitution of
        // equally many characters — which is the same "a few pixels" this
        // deliberately tolerates from ranking by length in the first place.
        var shape: [Int] = []
        shape.reserveCapacity(picks.count * 2)
        for pick in picks {
            shape.append(pick)
            shape.append(rows[pick].count)
        }
        if let c = widestRowCache, c.fontIdentity == font.identity, c.wraps == wraps,
           widestRowShape == shape
        {
            widestRowCache = (font.identity, editing.text, wraps, c.width)
            return c.width
        }

        let widest = rowTexts(at: picks, rows: rows).reduce(Float(0)) {
            max($0, font.shapedRun($1).width)
        }
        widestRowCache = (font.identity, editing.text, wraps, widest)
        widestRowShape = shape
        return widest
    }

    /// `String.Index` for a character offset, resolved relative to the last
    /// offset this leaf resolved — see `indexAnchor`.
    func textIndex(atOffset offset: Int) -> String.Index {
        let text = editing.text
        if let anchor = indexAnchor, anchor.revision == editing.revision {
            let delta = offset - anchor.offset
            if delta == 0 { return anchor.index }
            let limit = delta > 0 ? text.endIndex : text.startIndex
            if let moved = text.index(anchor.index, offsetBy: delta, limitedBy: limit) {
                indexAnchor = (editing.revision, offset, moved)
                return moved
            }
        }
        let resolved = editing.index(atOffset: offset)
        indexAnchor = (editing.revision, offset, resolved)
        return resolved
    }

    /// The other direction, and the one a caret and a selection need: a
    /// character offset for an index the buffer already holds.
    ///
    /// `TextEditingState.offset(of:)` is `distance(from: startIndex,…)`, so it
    /// costs the offset itself — the single largest per-move cost of dragging a
    /// selection near the end of a large file. Measuring from the anchor
    /// instead costs the *distance travelled*, which for a drag is a few
    /// characters and for a scroll a few rows.
    ///
    /// Falls back to the walk when there is no usable anchor, so the answer is
    /// the same either way; only the price changes.
    func charOffset(of index: String.Index) -> Int {
        let text = editing.text
        guard let anchor = indexAnchor, anchor.revision == editing.revision else {
            let resolved = editing.offset(of: index)
            indexAnchor = (editing.revision, resolved, index)
            return resolved
        }
        if index == anchor.index { return anchor.offset }
        // Negative when `index` sits before the anchor, which `distance`
        // handles and which a drag upwards produces constantly.
        let offset = anchor.offset + text.distance(from: anchor.index, to: index)
        indexAnchor = (editing.revision, offset, index)
        return offset
    }

    /// Text of the given rows, extracted in a single forward pass.
    ///
    /// `index(atOffset:)` walks from the start of the buffer on every call, so
    /// a dozen candidate rows near the end of a large file walked it a dozen
    /// times. Sorting the candidates and carrying a cursor makes it one walk —
    /// the same trick `emitEditor` uses for the visible window.
    private func rowTexts(at indices: [Int], rows: [Range<Int>]) -> [String] {
        let text = editing.text
        // The table's own end, not `text.count`: rows are character offsets
        // and the last one already ends at the buffer's length, so asking the
        // string costs a full grapheme walk of it to learn a number that is
        // sitting in an array — 4 ms of every keystroke on a 4 MB log.
        //
        // A stale table can still overshoot the buffer, and this no longer
        // catches that. It never was what made the overshoot safe: every walk
        // below is `limitedBy: text.endIndex`, so an offset past the end
        // saturates and yields an empty row rather than trapping.
        let endOffset = rows.last?.upperBound ?? 0
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
        // A wrapped row is built to fit the viewport, so there is nothing to
        // scroll to. Answering here rather than at each caller is what keeps
        // the wheel, the clamp, the caret-follow and the scroll-eligibility
        // test from having to agree separately — and it means a leaf switched
        // to wrapping while scrolled right is pulled back to the margin by the
        // clamp on its next emit, instead of drawing a blank column.
        guard !wraps else { return 0 }
        return max(0, widestRowWidth(font: font) - textViewportWidth)
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
    /// Box width from the same pass. The gutter and the insets come out of it
    /// to give `textViewportWidth`; this is the whole box, which is what a
    /// scrollbar on the right edge is measured from.
    var viewportWidth: Float = 0

    /// Rows that fit in the viewport, at least one.
    func visibleRowCount(lineHeight: Float) -> Int {
        max(1, Int((viewportHeight - textInset * 2) / lineHeight))
    }

    /// Vertical scrollbar geometry, or nil when the content fits.
    ///
    /// On the leaf rather than in the draw list because the drag needs the
    /// same numbers the paint does, and a drag that computed its own would be
    /// a second definition of where the thumb is.
    func verticalScrollbar(font: UIFont) -> Scrollbar.Metrics? {
        let content = Float(editing.layout.count) * font.lineHeight + textInset * 2
        return Scrollbar.metrics(
            track: viewportHeight, content: content,
            offset: scrollY, maxOffset: maxScrollY(lineHeight: font.lineHeight)
        )
    }

    /// Horizontal scrollbar geometry. Always nil while wrapping, where there
    /// is nothing to scroll to — see `maxScrollX`.
    func horizontalScrollbar(font: UIFont) -> Scrollbar.Metrics? {
        let maximum = maxScrollX(font: font)
        return Scrollbar.metrics(
            track: textViewportWidth, content: textViewportWidth + maximum,
            offset: scrollX, maxOffset: maximum
        )
    }

    /// Largest legal scroll offset for the current content.
    func maxScrollY(lineHeight: Float) -> Float {
        let content = Float(editing.layout.count) * lineHeight
        let visible = viewportHeight - textInset * 2
        return max(0, content - visible)
    }

    /// Pulls both offsets back inside the current content and viewport.
    ///
    /// Only ever shrinks them: an offset that is still legal is left exactly
    /// where it is, so this cannot fight a scroll in progress.
    func clampScroll(font: UIFont) {
        if scrollY > 0 {
            scrollY = max(0, min(scrollY, maxScrollY(lineHeight: font.lineHeight)))
        }
        if scrollX > 0 {
            scrollX = max(0, min(scrollX, maxScrollX(font: font)))
        }
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
            EditorProbe.count("caret.cacheHit")
            return (cached.offset, cached.row)
        }
        // Split, because the two are different shapes of cost and a drag
        // invalidates the cache on every pointer move: the first is a walk
        // from the buffer's start, the second a scan of every row.
        let offset = EditorProbe.measureOffset("caret.offsetOf") {
            charOffset(of: editing.focus)
        }
        let row = EditorProbe.measure("caret.rowIndex", at: offset) {
            editing.layout.rowIndex(ofOffset: offset, affinity: editing.affinity)
        }
        cachedFocusPosition = (editing.focus, editing.affinity, offset, row)
        return (offset, row)
    }

    /// The selection's two ends as character offsets, each cached against the
    /// index it was computed from.
    ///
    /// The caret has had a cache for this reason since large files first got
    /// slow; the selection did not, so every emit with a selection paid two
    /// more walks from the buffer's start. Two slots rather than one pair,
    /// because a drag moves one end and leaves the other alone — the still
    /// end should cost nothing at all, not be recomputed because its partner
    /// moved.
    ///
    /// Keyed on `revision` as well as the index, and it has to be: an edit
    /// can leave a `String.Index` comparing equal to the one cached here while
    /// the character offset at that position has moved, because text was
    /// inserted before it.
    private var cachedSelectionOffsets: (
        lower: (revision: UInt64, index: String.Index, offset: Int)?,
        upper: (revision: UInt64, index: String.Index, offset: Int)?
    ) = (nil, nil)

    /// Character offsets of `range`, both ends cached. `nil` when there is no
    /// selection to measure.
    func selectionOffsets(_ range: Range<String.Index>?) -> (from: Int, to: Int)? {
        guard let range else { return nil }
        let from = cachedSelectionOffset(
            range.lowerBound, cache: \.lower, name: "sel.start"
        )
        let to = cachedSelectionOffset(
            range.upperBound, cache: \.upper, name: "sel.end"
        )
        return (from, to)
    }

    private func cachedSelectionOffset(
        _ index: String.Index,
        cache: WritableKeyPath<
            (lower: (revision: UInt64, index: String.Index, offset: Int)?,
             upper: (revision: UInt64, index: String.Index, offset: Int)?),
            (revision: UInt64, index: String.Index, offset: Int)?
        >,
        name: String
    ) -> Int {
        if let hit = cachedSelectionOffsets[keyPath: cache],
           hit.revision == editing.revision, hit.index == index
        {
            EditorProbe.count("\(name).cacheHit")
            return hit.offset
        }
        let offset = EditorProbe.measureOffset(name) { charOffset(of: index) }
        cachedSelectionOffsets[keyPath: cache] = (editing.revision, index, offset)
        return offset
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
    /// Logical line each visual row belongs to, and where in that line the row
    /// starts. Empty while not wrapping, where a row *is* a logical line and
    /// both answers are `row` and `0` — see `logicalLine(ofRow:)`.
    ///
    /// The gutter, the go-to-line jump and a stateful highlighter's spans are
    /// all stated in logical lines; only the drawing is stated in rows. Built
    /// alongside the rows themselves, in the one pass that already knows both.
    var rowLogicalLine: [Int] = []
    var rowColumnStart: [Int] = []
    /// Per-logical-line wrap results from the last pass: the line as it was,
    /// and the rows it broke into (offsets within that line).
    ///
    /// Wrapping is the one text operation whose cost is the whole buffer —
    /// every line has to be shaped to know where it breaks — and it re-runs
    /// on every edit. A keystroke changes one line, so re-wrapping the file
    /// meant a 100 KB document paid ~100ms per key and a 1 MB one ~1s. Lines
    /// whose text is unchanged keep the rows they already had.
    ///
    /// `Substring`s, sharing the previous buffer's storage rather than
    /// copying it, the same as `SyntaxHighlighter.Cache` holds its lines.
    var wrapCacheRows: [[Range<Int>]] = []
    /// The buffer the current plan was built from, for the diff that finds
    /// which lines an edit touched.
    ///
    /// Not `lastWrappedText`, which looks like the same thing and is not:
    /// that one is a staleness flag, and `afterEdit` *clears* it to force the
    /// next pass to run. Diffing against it would compare the new buffer with
    /// an empty one on exactly the pass that follows an edit — every line
    /// different, the whole file re-broken, which is the case this plan
    /// exists to avoid.
    var wrapPlanText: String = ""
    /// Logical line to bring back to the top of the box once the row table
    /// has been rebuilt under it.
    ///
    /// `scrollY` is pixels over *row* indices, and a row is not a fixed thing:
    /// turn wrapping off and row 6,000 stops being the six-thousandth wrapped
    /// row and becomes line 6,000, four times further down the file — far
    /// enough on a long one that the clamp lands on the end of it. A line
    /// number survives the change; an offset does not.
    var pendingTopLine: Int?
    /// False where `wrapCacheRows[i]` is that provisional row rather than a
    /// real break. See `refreshVisualRows`.
    var wrapMeasured: [Bool] = []
    /// Lines still provisional, and where the background refinement has got
    /// to. Zero unmeasured means the plan is complete and no further frames
    /// are asked for.
    var wrapUnmeasured = 0
    var wrapCursor = 0
    /// Line boundaries the plan is stated against, in characters and bytes.
    ///
    /// Every line the plan touches is reached through this: its character
    /// length (what a provisional row covers, and what turns a line index
    /// into a buffer offset) and its bytes (what the diff against the
    /// previous buffer works in, and what a line is sliced out of the buffer
    /// with). Holding it is what lets the wrap pass avoid splitting the
    /// buffer into `Substring`s at all.
    var logicalLineIndex = LineIndex()
    /// Rows from the last `seedLogicalRows`, valid while `lastLogicalRowsText`
    /// still matches the buffer. The wrap planner needs exactly this scan, and
    /// on an edit `afterEdit` has just done it — so without somewhere to keep
    /// it, a wrapping editor scanned the buffer twice for every keystroke.
    /// Click handler receiving node-local coordinates *and* the node's
    /// absolute origin. The caret needs the former; a drag needs the latter,
    /// because pointer capture delivers window coordinates long after the hit
    /// test that knew where this node was. `mods` is whatever was held at the
    /// moment of the press — a drag can't ask again mid-flight, only a fresh
    /// press reflects current modifier state.
    var onClickLocal: ((_ localX: Float, _ localY: Float,
                        _ originX: Float, _ originY: Float,
                        _ mods: Int32, _ button: Int32) -> Void)?
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
        if kind == .text, let limit = textLineLimit {
            let constrained = width > 0 && (
                widthMode == YGMeasureModeExactly || widthMode == YGMeasureModeAtMost
            )
            var visible = Array(entry.lines.prefix(max(1, limit)))
            // `lines.count > limit` is a wrap that ran past the cap. A
            // *single* long line in a `.frame(width:)` never wraps — there
            // is nothing to prefix — and used to paint the whole string
            // past the box. Ellipsize that case too.
            let overflowed = entry.lines.count > limit
                || (constrained && entry.width > width)
            if overflowed, let last = visible.indices.last {
                visible[last] = font.ellipsized(
                    visible[last], availWidth: max(0, width - 8)
                )
            }
            cachedLines = visible
            if overflowed {
                return YGSize(
                    width: entry.width + 8,
                    height: font.lineHeight * Float(visible.count) + 4
                )
            }
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

// MARK: - What the renderer treats as a control

// One definition of "this node is a thing the pointer can be *on*", used by
// the two places that must agree about it: `DrawList`, which decides whether
// to emit a hit-testable scene node, and `hitTestSceneHover`, which answers
// the same question locally when no renderer is going to.
//
// They disagreed before, and only for buttons — a `Button` has no local hover
// fill because its tint is the renderer's job, so a walk keyed on `hoverFill`
// skipped the one control every app is made of.

// A stated cursor is part of that definition, and has to be: the pointer image
// changes when the pointer *enters* the view, and nothing learns about an entry
// into a node the renderer was never told to watch.

extension LeafNode {
    /// True when `DrawList` would emit this leaf as a hit-testable node.
    var isRendererInteractive: Bool {
        if kind == .button, buttonStyle != nil, isEnabled { return true }
        return hoverFill != nil || hoverColor != nil || onHover != nil
            || cursor != nil
    }
}

extension StackNode {
    var isRendererInteractive: Bool {
        hoverFill != nil || onHover != nil || onClick != nil || onPointer != nil
            || cursor != nil
    }
}

extension StyleBoxNode {
    var isRendererInteractive: Bool { hoverFill != nil || cursor != nil }
}

// MARK: - Stack container (HStack / VStack only)

final class StackNode: YogaBoxNode {
    private(set) var contentNode: any AnyViewNode
    let direction: FlexDirection
    /// Panel background (Phase 3 draw list).
    var fillColor: Color?
    /// Two-stop linear fill; wins over `fillColor` when set.
    var fillGradient: Gradient?
    var hoverFill: Color?
    var onClick: (() -> Void)?
    /// Button-aware press (tray right-click, etc.). Prefer over `onClick` when
    /// both are set — see `hitWalk`.
    var onPointer: ((_ mods: Int32, _ button: Int32) -> Void)?
    var onHover: ((Bool) -> Void)?
    var onWheel: ((Float, Float) -> Void)?
    /// Corner radius for `fillColor`. Set via `.cornerRadius()` modifiers.
    var cornerRadius: Float = 0

    /// Yoga children currently inserted (flattened leaves under content).
    private var insertedLeaves: [any AnyViewNode] = []

    init(
        label: String, direction: FlexDirection, style: StackStyle,
        content: any AnyViewNode, onClick: (() -> Void)?,
        onPointer: ((_ mods: Int32, _ button: Int32) -> Void)?,
        onHover: ((Bool) -> Void)?,
        onWheel: ((Float, Float) -> Void)? = nil
    ) {
        self.direction = direction
        self.contentNode = content
        self.onClick = onClick
        self.onPointer = onPointer
        self.onHover = onHover
        self.onWheel = onWheel
        super.init(label: label)
        YGNodeStyleSetFlexDirection(yogaStorage, direction.yoga)
        apply(style)
        configureHover()
        configureWheel()
        relinkYogaChildren()
    }

    override var childNodes: [any AnyViewNode] { [contentNode] }

    func update(
        style: StackStyle, contentView: some View,
        onClick: (() -> Void)?,
        onPointer: ((_ mods: Int32, _ button: Int32) -> Void)?,
        onHover: ((Bool) -> Void)?,
        onWheel: ((Float, Float) -> Void)? = nil
    ) {
        apply(style)
        self.onClick = onClick
        self.onPointer = onPointer
        self.onHover = onHover
        self.onWheel = onWheel
        configureHover()
        configureWheel()
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

    private func configureWheel() {
        if let onWheel {
            ScrollRouter.register(id, handler: onWheel)
        } else {
            ScrollRouter.unregister(id)
        }
    }

    private func apply(_ style: StackStyle) {
        flexGrow = style.flexGrow
        width = style.width
        height = style.height
        padding = .all(style.padding)
        YGNodeStyleSetAlignItems(yogaStorage, style.alignment.yoga)
        YGNodeStyleSetFlexWrap(yogaStorage, style.wraps ? YGWrapWrap : YGWrapNoWrap)
        let spacing = max(0, style.spacing ?? Environment.current.theme.stackSpacing)
        switch direction {
        case .row:
            YGNodeStyleSetGap(yogaStorage, YGGutterColumn, spacing)
        case .column:
            YGNodeStyleSetGap(yogaStorage, YGGutterRow, spacing)
        }
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
        let leaves = contentNode.flattenedLayoutNodes()
        guard childrenChanged(leaves) else { return }
        YGNodeRemoveAllChildren(yogaStorage)
        insertedLeaves = leaves
        for (i, leaf) in leaves.enumerated() {
            guard let y = leaf.yoga else { continue }
            YGNodeInsertChild(yogaStorage, y, i)
        }
    }

    private func childrenChanged(_ leaves: [any AnyViewNode]) -> Bool {
        yogaChildrenChanged(leaves, insertedLeaves)
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
/// The observation callback captures this non-generic sendable token rather
/// than `CompositeNode<V>`, avoiding the generic metatype Sendable warning.
private final class BodyInvalidationToken: @unchecked Sendable {
    weak var node: (any BodyRecomputable)?

    init(_ node: any BodyRecomputable) {
        self.node = node
    }
}

final class CompositeNode<V: View>: FragmentNode, BodyRecomputable, @unchecked Sendable {
    var view: V

    /// The window this node was mounted into. Captured here rather than read
    /// at invalidation time because the write that dirties this node can come
    /// from any window — see `BodyRecomputable.invalidationScope`. Mounting
    /// always happens inside the owning window's frame phase, so the ambient
    /// scope is correct exactly once: now.
    let invalidationScope: WindowScope?

    /// Override stack in force when this node last mounted or was reconciled
    /// from a parent. Targeted `recomputeBody` has no ancestor wrappers left
    /// on the call stack — `.font()` / `.theme()` live only there — so we
    /// replay this. An empty snapshot is the live globals, not a frozen copy.
    private var capturedEnvironmentStack: [EnvironmentValues]

    init(_ view: V) {
        self.view = view
        self.invalidationScope = WindowScope.currentOrMain
        self.capturedEnvironmentStack = Environment.stackSnapshot
        super.init(label: String(describing: V.self))
        setChildren([ViewGraph.mount(computeBody())])
    }

    func update(_ newView: V) {
        // The parent handed us a freshly built struct, so its `@State` is new.
        // Re-attach the storage the old copy owned before anything reads it —
        // reading `newView.body` first would observe reset state.
        StateTransfer.adopt(into: newView, from: view)
        view = newView
        // Parent reconcile runs inside whatever `.font()` / `.theme()`
        // wrapped us this pass; keep that, not the stack from last time.
        capturedEnvironmentStack = Environment.stackSnapshot
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
        // No `EnvironmentModifiedView` on this path: the dirty node is
        // invoked directly. Replay the stack captured when a parent last
        // mounted or reconciled us, or `.font()` on a wrapper evaporates
        // the first time this view's own `@Observable` ticks.
        Environment.withRestoredStack(capturedEnvironmentStack) {
            reconcileBody()
        }
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
        let invalidation = BodyInvalidationToken(self)
        withObservationTracking {
            body = view.body
        } onChange: { [invalidation] in
            guard let node = invalidation.node else { return }
            ViewInvalidation.markBodyDirty(node)
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

    /// Takes children already built by `ForEach.init`, which ran inside the
    /// parent body's observation-tracking scope. Nothing is evaluated here —
    /// see `ForEach` for why that matters.
    func update<Content: View>(rows: [(id: ID, content: Content)]) {
        var oldMap = Dictionary(uniqueKeysWithValues: keyed.map { ($0.id, $0.node) })
        var next: [(id: ID, node: any AnyViewNode)] = []
        next.reserveCapacity(rows.count)

        for row in rows {
            let key = row.id
            let childView = row.content
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
        // The viewport, and nothing else.
        //
        // This used to include `!layoutValid`, which every `.body` pass sets
        // — `setRoot` clears it to stop hit-tests running against stale
        // frames. Folding the two together meant a body pass re-measured
        // every leaf in the tree, and since dirtying a leaf propagates to
        // every ancestor, Yoga was handed a fully dirty tree and had nothing
        // to skip. Measured on a 560-row list where one label changed: 2249
        // of 2813 nodes dirty, and 4 ms in `YGNodeCalculateLayout`.
        //
        // "Layout is stale" and "every measurement is stale" are different
        // claims, and only the second one justifies this. The cases that
        // genuinely need a global re-measure ask for it directly:
        // `invalidateTextMetrics` after a content-scale change, and the first
        // pass, which is covered because `lastLayoutWidth` starts at 0.
        let sizeChanged =
            abs(w - lastLayoutWidth) > 0.5
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
        mods: Int32 = 0, button: Int32 = 0
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
                    ox: originX + att.origin.x, oy: originY + att.origin.y,
                    mods: mods, button: button
                ) {
                    return hit
                }
                // Inside the panel but on an inert part: swallow, so the click
                // neither dismisses nor reaches the content below.
                if att.contains(x - originX, y - originY) { return {} }
            }
            // Outside the popup but still on this window: prefer a real target
            // in the main tree (menu bar titles especially) over a blind
            // dismiss. A native menubar switches on the same click that leaves
            // the previous menu; dismissing first then re-running the title
            // handler used to reopen the same menu (blink) or require two
            // clicks to change menus. Title handlers toggle presentation
            // themselves — no second dismiss needed when they fire.
            if let hit = hitWalk(
                root, x: x, y: y, ox: originX, oy: originY,
                mods: mods, button: button
            ) {
                return hit
            }
            return { for att in overlays { att.dismiss() } }
        }

        return hitWalk(root, x: x, y: y, ox: originX, oy: originY,
                       mods: mods, button: button)
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

    /// What the *renderer* would call hovered at this point.
    ///
    /// Deliberately not `hitTestHover`. That one answers a local question —
    /// which node should highlight, which container a wheel notch belongs to,
    /// what a file was dropped on — and it counts scrollables and drop targets
    /// as hover targets because those are the things it exists to find. The
    /// renderer counts something narrower: the nodes it was handed a hit-test
    /// flag for, which is `isRendererInteractive` and nothing else.
    ///
    /// The distinction matters exactly once, and it is enough: an injected
    /// pointer in a client has no renderer to answer `.nodeHover`, so this is
    /// what stands in for it, and it has to give the same answer the renderer
    /// would or a `Button` will not believe the pointer is on it.
    ///
    /// Deepest wins, matching `RenderWindow::updateSceneHover`, which walks a
    /// pre-order list and keeps the last node containing the point.
    public func hitTestSceneHover(
        x: Float, y: Float, originX: Float = 0, originY: Float = 0
    ) -> NodeID? {
        guard layoutValid, let root else { return nil }

        for att in OverlayScan.presented(in: root).reversed() {
            guard let overlayRoot = att.root else { continue }
            if let id = sceneHoverWalk(
                overlayRoot, x: x, y: y,
                ox: originX + att.origin.x, oy: originY + att.origin.y
            ) {
                return id
            }
            if att.contains(x - originX, y - originY) { return nil }
        }

        return sceneHoverWalk(root, x: x, y: y, ox: originX, oy: originY)
    }

    private func sceneHoverWalk(
        _ node: any AnyViewNode, x: Float, y: Float, ox: Float, oy: Float
    ) -> NodeID? {
        if let box = node as? YogaBoxNode, box.transitionState?.isLeaving == true {
            return nil
        }
        guard let box = node as? YogaBoxNode, let yref = box.yoga else {
            for child in node.childNodes.reversed() {
                if let h = sceneHoverWalk(child, x: x, y: y, ox: ox, oy: oy) {
                    return h
                }
            }
            return nil
        }

        let nx = ox + YGNodeLayoutGetLeft(yref)
        let ny = oy + YGNodeLayoutGetTop(yref)
        let nw = YGNodeLayoutGetWidth(yref)
        let nh = YGNodeLayoutGetHeight(yref)

        // Children first: deepest wins, as it does in the renderer.
        for child in node.childNodes.reversed() {
            let shift = box.childOffset
            if let h = sceneHoverWalk(
                child, x: x, y: y, ox: nx - shift.x, oy: ny - shift.y
            ) { return h }
        }

        guard x >= nx, x < nx + nw, y >= ny, y < ny + nh else { return nil }
        if let leaf = node as? LeafNode, leaf.isRendererInteractive { return leaf.id }
        if let stack = node as? StackNode, stack.isRendererInteractive { return stack.id }
        if let styled = node as? StyleBoxNode, styled.isRendererInteractive {
            return styled.id
        }
        return nil
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
        // tree, so it must not answer for input on the way out. A hidden one
        // is the mirror image — still in the tree, not on screen — and must
        // not answer either, or a pane nobody can see takes the clicks meant
        // for the one in front of it.
        if let box = node as? YogaBoxNode,
           box.transitionState?.isLeaving == true || box.isHidden
        {
            return nil
        }
        if let box = node as? YogaBoxNode, let yref = box.yoga {
            let nx = ox + YGNodeLayoutGetLeft(yref)
            let ny = oy + YGNodeLayoutGetTop(yref)
            let nw = YGNodeLayoutGetWidth(yref)
            let nh = YGNodeLayoutGetHeight(yref)
            // Outside a scissored box is off screen; see `clipsChildren`.
            if box.clipsChildren,
               x < nx || x >= nx + nw || y < ny || y >= ny + nh
            {
                return nil
            }
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
                if let styled = node as? StyleBoxNode, styled.hoverFill != nil {
                    return styled.id
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
        if let box = node as? YogaBoxNode,
           box.transitionState?.isLeaving == true || box.isHidden
        {
            return false
        }
        if let box = node as? YogaBoxNode, let yref = box.yoga {
            let nx = ox + YGNodeLayoutGetLeft(yref)
            let ny = oy + YGNodeLayoutGetTop(yref)
            let nw = YGNodeLayoutGetWidth(yref)
            let nh = YGNodeLayoutGetHeight(yref)
            // Outside a scissored box is off screen; see `clipsChildren`. The
            // allowance below is for content overflowing a container that
            // does *not* clip — a wheel over a row that has been scrolled out
            // of sight belongs to whatever is drawn in its place.
            if box.clipsChildren,
               x < nx || x >= nx + nw || y < ny || y >= ny + nh
            {
                return false
            }
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
        mods: Int32, button: Int32
    ) -> (() -> Void)? {
        // Clicking something that is fading out would run an action the view
        // tree no longer describes; clicking through to something hidden runs
        // one the user cannot see.
        if let box = node as? YogaBoxNode,
           box.transitionState?.isLeaving == true || box.isHidden
        {
            return nil
        }
        if let box = node as? YogaBoxNode, let yref = box.yoga {
            let nx = ox + YGNodeLayoutGetLeft(yref)
            let ny = oy + YGNodeLayoutGetTop(yref)
            let nw = YGNodeLayoutGetWidth(yref)
            let nh = YGNodeLayoutGetHeight(yref)
            // Outside a scissored box is off screen; see `clipsChildren`.
            if box.clipsChildren,
               x < nx || x >= nx + nw || y < ny || y >= ny + nh
            {
                return nil
            }
            // Before the children, and only this: see `onOverlayPress`.
            if let overlay = box.onOverlayPress,
               x >= nx, x < nx + nw, y >= ny, y < ny + nh,
               let action = overlay(x - nx, y - ny, nx, ny)
            {
                return action
            }
            // Children front-to-back.
            for child in node.childNodes.reversed() {
                let shift = box.childOffset
                if let h = hitWalk(
                    child, x: x, y: y, ox: nx - shift.x, oy: ny - shift.y,
                    mods: mods, button: button
                ) { return h }
            }
            if let leaf = node as? LeafNode,
               x >= nx, x < nx + nw, y >= ny, y < ny + nh
            {
                if let local = leaf.onClickLocal {
                    let lx = x - nx
                    let ly = y - ny
                    return { local(lx, ly, nx, ny, mods, button) }
                }
                if let click = leaf.onClick, leaf.kind == .text || leaf.kind == .image {
                    return click
                }
            }
            if let stack = node as? StackNode,
               x >= nx, x < nx + nw, y >= ny, y < ny + nh
            {
                // Pointer first: tray icons need right-click → ContextMenu
                // without losing left-click Activate.
                if let pointer = stack.onPointer {
                    return { pointer(mods, button) }
                }
                if let click = stack.onClick {
                    return click
                }
            }
            if let press = box.onBoxPress,
               x >= nx, x < nx + nw, y >= ny, y < ny + nh
            {
                let lx = x - nx
                let ly = y - ny
                return { press(lx, ly, mods) }
            }
            return nil
        }
        for child in node.childNodes.reversed() {
            if let h = hitWalk(child, x: x, y: y, ox: ox, oy: oy,
                               mods: mods, button: button) { return h }
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
    /// Two-stop linear fill; wins over `fillColor` when set.
    var fillGradient: Gradient?
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
    /// Two-stop linear fill; wins over `fillColor` when set.
    var fillGradient: Gradient?
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
    func update<Content: View>(rows: [(id: ID, content: Content)]) {}
    func collectFrames(originX: Float, originY: Float, into frames: inout [LayoutFrame]) {}
    func flattenedLayoutNodes() -> [any AnyViewNode] { childNodes.flatMap { $0.flattenedLayoutNodes() } }
}

#endif
