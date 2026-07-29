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
    var needsBodyRecompute = false

    var flexGrow: Float = 0
    var flexShrink: Float = 1
    var width: Dimension = .auto
    var height: Dimension = .auto
    var padding: Float = 0
    var minWidth: Float = 0
    var minHeight: Float = 0

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
        YGNodeStyleSetFlexShrink(yogaStorage, flexShrink)
        applyDimension(width, setPoint: YGNodeStyleSetWidth, setAuto: YGNodeStyleSetWidthAuto)
        applyDimension(height, setPoint: YGNodeStyleSetHeight, setAuto: YGNodeStyleSetHeightAuto)
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
        setAuto: (YGNodeRef?) -> Void
    ) {
        switch dim {
        case .undefined:
            setPoint(yogaStorage, .nan)
        case .auto:
            setAuto(yogaStorage)
        case .point(let v):
            setPoint(yogaStorage, v)
        }
    }

    func collectFrames(originX: Float, originY: Float, into frames: inout [LayoutFrame]) {
        let x = originX + YGNodeLayoutGetLeft(yogaStorage)
        let y = originY + YGNodeLayoutGetTop(yogaStorage)
        let w = YGNodeLayoutGetWidth(yogaStorage)
        let h = YGNodeLayoutGetHeight(yogaStorage)
        frames.append(LayoutFrame(label: label, x: x, y: y, w: w, h: h))
        collectChildFrames(originX: x, originY: y, into: &frames)
    }

    func collectChildFrames(originX: Float, originY: Float, into frames: inout [LayoutFrame]) {}
}

// MARK: - Leaf (Text / Spacer / DiagramHost / Empty)

enum LeafKind: Equatable {
    case text
    case spacer
    case diagramHost
    case empty
    case image
    case textField
    case editor
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
    /// Last layout lines from Font measure cache (for multi-line emit).
    var cachedLines: [String] = []
    var usesTextMeasure = false
    /// Editable payload (textField leaves). Lives on the node because a
    /// PrimitiveView has no body, so it never goes through CompositeNode's
    /// @State transplant — the node's own lifetime is the persistence.
    var editing = TextEditingState("")
    var placeholder: String = ""
    var isMultiline = false
    var maxLines = 8
    var wraps = false
    /// Editor-only payload.
    var highlighter: SyntaxHighlighter?
    var codeStyle: CodeStyle?
    var showsGutter = false
    var gutterWidth: Float = 0
    var search = TextSearch()
    /// Last width Yoga gave this leaf, used to wrap on the next pass.
    var lastMeasuredWidth: Float = 0
    /// Click handler receiving node-local coordinates *and* the node's
    /// absolute origin. The caret needs the former; a drag needs the latter,
    /// because pointer capture delivers window coordinates long after the hit
    /// test that knew where this node was.
    var onClickLocal: ((_ localX: Float, _ localY: Float,
                        _ originX: Float, _ originY: Float) -> Void)?
    /// Called when hover enters/leaves, for views wanting more than a fill.
    var onHover: ((Bool) -> Void)?

    /// Fill drawn when the pointer is over this leaf (nil = no hover effect).
    var hoverFill: Color?
    /// Corner radius for `fillColor`/`hoverFill`.
    var cornerRadius: Float = 0

    /// Raster image leaf payload.
    var image: UIImage?
    var imageTint: Color = Color(r: 1, g: 1, b: 1)
    var imageContentMode: ImageContentMode = .stretch

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
        if kind == .diagramHost {
            fillColor = Theme.current.canvas
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
        // Yoga tells us the width here and nowhere else, so this is where a
        // wrapping field learns how wide it may be.
        if kind == .textField || kind == .editor, wraps, width > 0, width != lastMeasuredWidth {
            lastMeasuredWidth = width
            refreshVisualRows(availableWidth: width)
        }
        guard let font = font ?? FontStore.default else {
            // Fallback estimate if font not bootstrapped yet.
            let w = max(8, Float(text.count) * 8 + 8)
            return YGSize(width: w, height: 22)
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

    /// Yoga children currently inserted (flattened leaves under content).
    private var insertedLeaves: [any AnyViewNode] = []

    init(label: String, direction: FlexDirection, style: StackStyle, content: any AnyViewNode) {
        self.direction = direction
        self.contentNode = content
        super.init(label: label)
        // Side columns get a solid panel fill; main HStack stays transparent.
        if direction == .column, case .point = style.width {
            fillColor = Color(r: 0.14, g: 0.15, b: 0.18)
        }
        YGNodeStyleSetFlexDirection(yogaStorage, direction.yoga)
        YGNodeStyleSetAlignItems(yogaStorage, YGAlignStretch)
        apply(style)
        relinkYogaChildren()
    }

    override var childNodes: [any AnyViewNode] { [contentNode] }

    func update(style: StackStyle, contentView: some View) {
        apply(style)
        contentNode = ViewGraph.reconcile(contentNode, with: contentView)
        relinkYogaChildren()
    }

    private func apply(_ style: StackStyle) {
        flexGrow = style.flexGrow
        width = style.width
        height = style.height
        padding = style.padding
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
    var needsBodyRecompute = false
    var childNodes: [any AnyViewNode] = []

    var yoga: YGNodeRef? { nil }

    init(label: String, children: [any AnyViewNode] = []) {
        self.id = .generate()
        self.label = label
        self.childNodes = children
    }

    func collectFrames(originX: Float, originY: Float, into frames: inout [LayoutFrame]) {
        // No box of our own — children already laid out by an ancestor stack.
        for child in childNodes {
            child.collectFrames(originX: originX, originY: originY, into: &frames)
        }
    }
}

/// Composite user view (`EditorChrome`): forwards to `body` node.
final class CompositeNode<V: View>: FragmentNode {
    var view: V

    init(_ view: V) {
        self.view = view
        super.init(label: String(describing: V.self))
        childNodes = [ViewGraph.mount(computeBody())]
    }

    func update(_ newView: V) {
        // The parent handed us a freshly built struct, so its `@State` is new.
        // Re-attach the storage the old copy owned before anything reads it —
        // reading `newView.body` first would observe reset state.
        StateTransfer.adopt(into: newView, from: view)
        view = newView

        needsBodyRecompute = true
        let body = computeBody()
        if let existing = childNodes.first {
            childNodes = [ViewGraph.reconcile(existing, with: body)]
        } else {
            childNodes = [ViewGraph.mount(body)]
        }
        needsBodyRecompute = false
    }

    /// Evaluates `body` while recording which observable properties it read.
    ///
    /// Two things about `withObservationTracking` that shape this:
    ///
    /// - `onChange` fires *before* the new value is written, so it must never
    ///   read state. Setting a dirty flag is all it does.
    /// - It fires at most once per registration. Re-registration happens
    ///   implicitly here, because every re-render recomputes bodies. A path
    ///   that skips `computeBody()` would silently unsubscribe that node.
    private func computeBody() -> V.Body {
        var body: V.Body!
        withObservationTracking {
            body = view.body
        } onChange: {
            ViewInvalidation.markDirty()
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
            childNodes = [n]
        } else {
            let n = ViewGraph.mount(view)
            active = .first(n)
            childNodes = [n]
        }
    }

    func updateSecond<B: View>(_ view: B) {
        label = "EitherView.second"
        if case .second(let node) = active {
            let n = ViewGraph.reconcile(node, with: view)
            active = .second(n)
            childNodes = [n]
        } else {
            let n = ViewGraph.mount(view)
            active = .second(n)
            childNodes = [n]
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
        if let existing = childNodes.first {
            childNodes = [ViewGraph.reconcile(existing, with: view)]
        } else {
            childNodes = [ViewGraph.mount(view)]
        }
    }

    func updateNone() {
        label = "OptionalView.none"
        childNodes = []
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
            if let existing = oldMap.removeValue(forKey: key) {
                next.append((key, ViewGraph.reconcile(existing, with: childView)))
            } else {
                next.append((key, ViewGraph.mount(childView)))
            }
        }
        // Remaining oldMap entries drop out of `keyed` → ARC frees nodes.
        keyed = next
        childNodes = next.map(\.node)
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

        var frames: [LayoutFrame] = []
        boxes[0].collectFrames(originX: 0, originY: 0, into: &frames)
        lastFrames = frames
        lastLayoutWidth = w
        lastLayoutHeight = h
        layoutValid = true
        return frames
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

    /// Diagram host from **committed** layout — does not re-run Yoga.
    public func diagramHostFrame() -> LayoutFrame? {
        guard layoutValid else { return nil }
        return lastFrames.first(where: { $0.label == "DiagramHost" })
    }

    /// Reverse-z hit test against **committed** Yoga geometry (no re-layout).
    /// `originY` matches emit offset (menu bar). Window-pixel coordinates.
    public func hitTestClick(
        x: Float, y: Float,
        originX: Float = 0, originY: Float = 0
    ) -> (() -> Void)? {
        guard layoutValid, let root else { return nil }
        return hitWalk(root, x: x, y: y, ox: originX, oy: originY)
    }

    /// Topmost interactive node under the pointer, for hover highlighting.
    public func hitTestHover(
        x: Float, y: Float, originX: Float = 0, originY: Float = 0
    ) -> NodeID? {
        guard layoutValid, let root else { return nil }
        return hoverWalk(root, x: x, y: y, ox: originX, oy: originY)
    }

    private func hoverWalk(
        _ node: any AnyViewNode, x: Float, y: Float, ox: Float, oy: Float
    ) -> NodeID? {
        if let box = node as? YogaBoxNode, let yref = box.yoga {
            let nx = ox + YGNodeLayoutGetLeft(yref)
            let ny = oy + YGNodeLayoutGetTop(yref)
            let nw = YGNodeLayoutGetWidth(yref)
            let nh = YGNodeLayoutGetHeight(yref)
            for child in node.childNodes.reversed() {
                if let h = hoverWalk(child, x: x, y: y, ox: nx, oy: ny) { return h }
            }
            if let leaf = node as? LeafNode,
               leaf.hoverFill != nil || leaf.onHover != nil,
               x >= nx, x < nx + nw, y >= ny, y < ny + nh
            {
                return leaf.id
            }
            return nil
        }
        for child in node.childNodes.reversed() {
            if let h = hoverWalk(child, x: x, y: y, ox: ox, oy: oy) { return h }
        }
        return nil
    }

    private func hitWalk(
        _ node: any AnyViewNode,
        x: Float, y: Float,
        ox: Float, oy: Float
    ) -> (() -> Void)? {
        if let box = node as? YogaBoxNode, let yref = box.yoga {
            let nx = ox + YGNodeLayoutGetLeft(yref)
            let ny = oy + YGNodeLayoutGetTop(yref)
            let nw = YGNodeLayoutGetWidth(yref)
            let nh = YGNodeLayoutGetHeight(yref)
            // Children front-to-back.
            for child in node.childNodes.reversed() {
                if let h = hitWalk(child, x: x, y: y, ox: nx, oy: ny) { return h }
            }
            if let leaf = node as? LeafNode,
               x >= nx, x < nx + nw, y >= ny, y < ny + nh
            {
                if let local = leaf.onClickLocal {
                    let lx = x - nx
                    let ly = y - ny
                    return { local(lx, ly, nx, ny) }
                }
                if let click = leaf.onClick, leaf.kind == .text || leaf.kind == .image {
                    return click
                }
            }
            return nil
        }
        for child in node.childNodes.reversed() {
            if let h = hitWalk(child, x: x, y: y, ox: ox, oy: oy) { return h }
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
enum LeafKind: Equatable { case text, spacer, diagramHost, empty, image, textField, editor }

final class LeafNode: AnyViewNode {
    let id = NodeID.generate()
    let kind: LeafKind
    var label: String
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
    var needsBodyRecompute = false
    var childNodes: [any AnyViewNode]
    init(children: [any AnyViewNode]) { self.childNodes = children }
    func collectFrames(originX: Float, originY: Float, into frames: inout [LayoutFrame]) {}
    func flattenedLayoutNodes() -> [any AnyViewNode] { childNodes.flatMap { $0.flattenedLayoutNodes() } }
}

final class EitherFragmentNode: AnyViewNode {
    let id = NodeID.generate()
    var label = "EitherView"
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
    var needsBodyRecompute = false
    var childNodes: [any AnyViewNode] = []
    func update<Data: RandomAccessCollection, Content: View>(
        data: Data, idKeyPath: KeyPath<Data.Element, ID>, content: (Data.Element) -> Content
    ) {}
    func collectFrames(originX: Float, originY: Float, into frames: inout [LayoutFrame]) {}
    func flattenedLayoutNodes() -> [any AnyViewNode] { childNodes.flatMap { $0.flattenedLayoutNodes() } }
}

#endif
