import CYoga
import Foundation

// Virtualized containers.
//
// The draw list has always culled: emitting a 6643-node library costs 0.2ms
// because everything off-screen is skipped. What was never virtualized is the
// half in front of it — mounting the nodes and running Yoga over them. On that
// same library a single `.body` invalidation cost ~46ms (32ms body + 13ms
// layout) to produce a frame that then drew in 0.2ms.
//
// So this does not make drawing faster. It stops *building* what will not be
// drawn: only the rows the viewport can show are mounted, and the container
// reserves the full scroll extent itself so the scrollbar and wheel clamping
// still see the real content size.
//
// Fixed cell size is a deliberate v1 limit, not an oversight. Variable heights
// need either a measure pass over every item — which is the cost being avoided
// — or estimate-and-correct, which makes the scrollbar jitter as estimates are
// replaced by truth. A fixed stride makes offset→index arithmetic exact and
// O(1), and every list these apps actually have (album cards, track rows, log
// lines) is uniform.

/// A vertically scrolling grid that mounts only the cells the viewport shows.
///
/// Must be placed directly inside a `ScrollView(.vertical)` — it needs that
/// container's offset and height to know what is visible. Outside one it still
/// renders correctly, by mounting everything, and says so once on stderr.
///
/// ```swift
/// ScrollView(.vertical) {
///     LazyVGrid(albums, cellWidth: 152, cellHeight: 233, spacing: 8) { album in
///         albumCard(album)
///     }
/// }
/// ```
///
/// Cell state is not preserved across scrolling: a cell scrolled out of the
/// window is unmounted, and `@State` inside it is gone when it returns. Keep
/// anything that must survive in the model, which is where a list's selection
/// and scroll position belong anyway.
public struct LazyVGrid<Data: RandomAccessCollection, Content: View>: PrimitiveView
where Data.Index == Int {
    public var data: Data
    /// Cell width in points. `nil` means one full-width column (`LazyVStack`).
    public var cellWidth: Float?
    public var cellHeight: Float
    public var spacing: Float
    /// Where the columns sit when the container is wider than they need.
    public var alignment: StackAlignment
    public var content: (Data.Element) -> Content

    /// - Parameter alignment: what to do with the width left over after the
    ///   last whole column. Cells have a fixed width, so a container is almost
    ///   never an exact number of them across, and `.start` — the default —
    ///   leaves the remainder as one uneven gap down the right-hand side. That
    ///   reads as a list, which is right for one. `.center` splits it, which
    ///   is right for a wall of cards with nothing to align to.
    public init(
        _ data: Data,
        cellWidth: Float,
        cellHeight: Float,
        spacing: Float = 0,
        alignment: StackAlignment = .start,
        @ViewBuilder content: @escaping (Data.Element) -> Content
    ) {
        self.data = data
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight
        self.spacing = spacing
        self.alignment = alignment
        self.content = content
    }

    init(
        _ data: Data,
        fullWidthRowHeight: Float,
        spacing: Float,
        @ViewBuilder content: @escaping (Data.Element) -> Content
    ) {
        self.data = data
        self.cellWidth = nil
        self.cellHeight = fullWidthRowHeight
        self.spacing = spacing
        // One full-width column leaves nothing over to place.
        self.alignment = .start
        self.content = content
    }

    public var dumpDetail: String {
        let w = cellWidth.map { "\(Int($0))" } ?? "full"
        return "[\(data.count) lazy \(w)×\(Int(cellHeight))]"
    }

    /// Deliberately does **not** expand children. A structure dump of a lazy
    /// container that built every row would defeat the container's whole point,
    /// and on a large list would hang the dump.
    public func structureLines(indent: Int = 0) -> [String] {
        [Dump.line(indent, "LazyVGrid \(dumpDetail)")]
    }

    public func mountPrimitive() -> any AnyViewNode {
        let node = LazyGridNode()
        apply(to: node)
        return node
    }

    public func reconcilePrimitive(_ node: any AnyViewNode) -> any AnyViewNode {
        guard let grid = node as? LazyGridNode else { return mountPrimitive() }
        apply(to: grid)
        return grid
    }

    private func apply(to node: LazyGridNode) {
        let data = self.data
        let content = self.content
        node.configure(
            count: data.count,
            cellWidth: cellWidth,
            cellHeight: cellHeight,
            spacing: spacing,
            alignment: alignment,
            makeCell: { index in content(data[data.startIndex + index]) }
        )
    }
}

/// A vertically scrolling list that mounts only the rows the viewport shows.
///
/// `LazyVGrid` with a single full-width column; the same rules apply — fixed
/// `rowHeight`, must live inside a `ScrollView(.vertical)`, cell state does not
/// survive scrolling.
public struct LazyVStack<Data: RandomAccessCollection, Content: View>: View
where Data.Index == Int {
    public var data: Data
    public var rowHeight: Float
    public var spacing: Float
    public var content: (Data.Element) -> Content

    public init(
        _ data: Data,
        rowHeight: Float,
        spacing: Float = 0,
        @ViewBuilder content: @escaping (Data.Element) -> Content
    ) {
        self.data = data
        self.rowHeight = rowHeight
        self.spacing = spacing
        self.content = content
    }

    public var body: some View {
        LazyVGrid(data, fullWidthRowHeight: rowHeight, spacing: spacing, content: content)
    }
}

// MARK: - Nodes

/// One mounted cell: an absolutely-positioned box holding the item's subtree.
///
/// The item goes *inside* a box this container owns rather than being positioned
/// directly, so the item's own `.frame`/`.padding` cannot fight the placement.
/// Positioning the item itself meant its `applyStyle()` could reset the geometry
/// out from under us — the same way an overlay's padding was reset once.
final class LazyCellNode: YogaBoxNode {
    private(set) var item: any AnyViewNode
    let index: Int

    init(index: Int, item: any AnyViewNode) {
        self.index = index
        self.item = item
        super.init(label: "LazyCell[\(index)]")
        structuralKey = "\(index)"
        YGNodeStyleSetPositionType(yogaStorage, YGPositionTypeAbsolute)
        relink()
    }

    override var childNodes: [any AnyViewNode] { [item] }

    func place(x: Float, y: Float, w: Float, h: Float) {
        YGNodeStyleSetPosition(yogaStorage, YGEdgeLeft, x)
        YGNodeStyleSetPosition(yogaStorage, YGEdgeTop, y)
        YGNodeStyleSetWidth(yogaStorage, w)
        YGNodeStyleSetHeight(yogaStorage, h)
    }

    private func relink() {
        let leaves = item.flattenedLayoutNodes()
        guard yogaChildrenChanged(leaves, insertedLeaves) else { return }
        YGNodeRemoveAllChildren(yogaStorage)
        insertedLeaves = leaves
        for (i, leaf) in leaves.enumerated() {
            guard let y = leaf.yoga else { continue }
            YGNodeInsertChild(yogaStorage, y, i)
        }
    }

    /// What is currently inserted into Yoga, so a relink that would change
    /// nothing can be skipped. See `yogaChildrenChanged`.
    private var insertedLeaves: [any AnyViewNode] = []

    override func collectChildFrames(
        originX: Float, originY: Float, into frames: inout [LayoutFrame]
    ) {
        item.collectFrames(originX: originX, originY: originY, into: &frames)
    }
}

final class LazyGridNode: YogaBoxNode {
    private var count = 0
    private var cellWidth: Float?
    private var cellHeight: Float = 1
    private var spacing: Float = 0
    private var alignment: StackAlignment = .start
    private var makeCell: (Int) -> any View = { _ in EmptyView() }

    /// The scroll container that decides what is visible. Set by
    /// `ScrollNode.relink`; nil means this is not inside one.
    weak var scrollNode: ScrollNode?

    private var cells: [Int: LazyCellNode] = [:]
    private var mounted: Range<Int> = 0..<0
    private var columns = 0
    private var lastWidth: Float = -1
    /// Set when `configure` changed the data: the window's *contents* are stale
    /// even if its index range is not, so it has to be rebuilt.
    private var contentDirty = true

    nonisolated(unsafe) private static var warnedUnscrolled = false

    /// How many of these exist anywhere. `LayoutHost` checks it before walking
    /// the tree looking for them, so an app that uses no lazy container pays
    /// nothing per layout pass rather than a full traversal.
    nonisolated(unsafe) private(set) static var liveCount = 0

    init() {
        super.init(label: "LazyVGrid")
        width = .percent(100)
        height = .point(0)
        applyStyle()
        Self.liveCount += 1
    }

    deinit {
        Self.liveCount -= 1
    }

    override var childNodes: [any AnyViewNode] {
        mounted.compactMap { cells[$0] }
    }

    func configure(
        count: Int,
        cellWidth: Float?,
        cellHeight: Float,
        spacing: Float,
        alignment: StackAlignment,
        makeCell: @escaping (Int) -> any View
    ) {
        let geometryChanged =
            self.cellWidth != cellWidth
            || self.cellHeight != cellHeight
            || self.spacing != spacing
            || self.alignment != alignment
            || self.count != count
        self.count = count
        self.cellWidth = cellWidth
        self.cellHeight = max(1, cellHeight)
        self.spacing = max(0, spacing)
        self.alignment = alignment
        self.makeCell = makeCell
        // Even an identical index range now yields different views, because the
        // closure closed over new data.
        contentDirty = true
        if geometryChanged { lastWidth = -1 }
    }

    var rowStride: Float { cellHeight + spacing }

    /// Recomputes the visible window from the geometry Yoga just produced.
    ///
    /// Returns true when something changed that needs another layout pass —
    /// a different column count, a different content height, or a different
    /// set of mounted cells.
    ///
    /// Called from `LayoutHost.calculateLayout` *after* Yoga has run, because
    /// until then this node has no width to derive columns from and no
    /// position to compare against the scroll offset.
    @discardableResult
    func settleWindow() -> Bool {
        let boxWidth = YGNodeLayoutGetWidth(yogaStorage)
        guard boxWidth > 0 else { return false }

        var changed = false

        let newColumns: Int
        if let cellWidth, cellWidth > 0 {
            newColumns = max(1, Int((boxWidth + spacing) / (cellWidth + spacing)))
        } else {
            newColumns = 1
        }
        if newColumns != columns || boxWidth != lastWidth {
            columns = newColumns
            lastWidth = boxWidth
            changed = true
        }

        let rows = columns > 0 ? (count + columns - 1) / columns : 0
        let total = rows > 0 ? Float(rows) * cellHeight + Float(rows - 1) * spacing : 0
        if case .point(let current) = height, current != total {
            height = .point(total)
            applyStyle()
            changed = true
        }

        let desired = desiredRange(rows: rows)
        if desired != mounted || contentDirty || changed {
            remount(to: desired)
            changed = true
        }
        contentDirty = false
        return changed
    }

    /// Index range the viewport needs, in cells.
    private func desiredRange(rows: Int) -> Range<Int> {
        guard count > 0, columns > 0 else { return 0..<0 }
        guard let scroll = scrollNode, let scrollYoga = scroll.yoga else {
            // No enclosing ScrollView: nothing tells us what is visible, so
            // mount everything. Correct, just not lazy.
            if !Self.warnedUnscrolled {
                Self.warnedUnscrolled = true
                let message = "LavaUI: LazyVGrid outside a ScrollView — mounting all "
                    + "\(count) cells. Wrap it in ScrollView(.vertical).\n"
                FileHandle.standardError.write(Foundation.Data(message.utf8))
            }
            return 0..<count
        }

        // Viewport height comes from Yoga rather than `ScrollNode.viewportLength`,
        // which is only assigned during emit — on the first layout of a frame it
        // still holds the previous frame's value, and on the very first frame it
        // is zero, which would mount an empty window and flash a blank list.
        let viewport = YGNodeLayoutGetHeight(scrollYoga)
        guard viewport > 0 else { return mounted }

        // This node's own offset inside the scrolled content: the container
        // need not be the first thing in the ScrollView.
        let myTop = YGNodeLayoutGetTop(yogaStorage)
        // The container states the band once, for the cull and for this, so
        // the two cannot drift apart — see `ScrollNode.desiredSpan`.
        let band = scroll.desiredSpan(viewport: viewport)
        let visibleTop = band.top - myTop
        let visibleBottom = band.bottom - myTop

        let firstRow = max(0, Int((visibleTop / rowStride).rounded(.down)))
        let lastRow = min(rows - 1, Int((visibleBottom / rowStride).rounded(.down)))
        guard lastRow >= firstRow else { return 0..<0 }

        let lower = firstRow * columns
        let upper = min(count, (lastRow + 1) * columns)
        guard upper > lower else { return 0..<0 }
        return lower..<upper
    }

    private func remount(to range: Range<Int>) {
        // Drop everything outside the new window. On a content change drop the
        // survivors too: same index, different element.
        for (index, cell) in cells where !range.contains(index) || contentDirty {
            YGNodeRemoveChild(yogaStorage, cell.yogaStorage)
            cells.removeValue(forKey: index)
        }

        let cellW = cellWidth ?? max(1, lastWidth)
        for index in range where cells[index] == nil {
            let cell = LazyCellNode(index: index, item: ViewGraph.mount(makeCell(index)))
            cells[index] = cell
            YGNodeInsertChild(yogaStorage, cell.yogaStorage, YGNodeGetChildCount(yogaStorage))
        }

        // Every cell, not only the ones just created. A cell's position is a
        // function of the column count, and the column count changes when the
        // window is resized — so a cell that survives a resize would otherwise
        // keep the place it was given under the old count. It is invisible
        // when the range changes too and the survivors are replaced, and it is
        // the whole bug when the range happens to stay the same: a grid that
        // had 23 columns on a 4K guess and 7 after the compositor said how
        // wide the window really is keeps laying its rows out 23 wide, off the
        // side of a window that only shows the first seven.
        // Where the width left over after the last whole column goes. The
        // partial last row is not centred on its own — it keeps the columns of
        // the rows above it, which is what stops the final row of a card wall
        // from sitting visibly off the grid everything else is on.
        let inset = leftInset(cellW: cellW)

        for index in range {
            guard let cell = cells[index] else { continue }
            let row = columns > 0 ? index / columns : 0
            let col = columns > 0 ? index % columns : 0
            cell.place(
                x: inset + Float(col) * (cellW + spacing),
                y: Float(row) * rowStride,
                w: cellW,
                h: cellHeight
            )
        }

        mounted = range
    }

    /// How far in from the left the first column starts.
    ///
    /// `.stretch` has no meaning for a grid of fixed-width cells — there is
    /// nothing to stretch — so it is read as `.start`.
    private func leftInset(cellW: Float) -> Float {
        guard columns > 0, alignment == .center || alignment == .end else {
            return 0
        }
        let used = Float(columns) * cellW + Float(columns - 1) * spacing
        let slack = max(0, lastWidth - used)
        return alignment == .center ? slack / 2 : slack
    }

    override func collectChildFrames(
        originX: Float, originY: Float, into frames: inout [LayoutFrame]
    ) {
        for cell in childNodes {
            cell.collectFrames(originX: originX, originY: originY, into: &frames)
        }
    }

    /// Vertical span of the mounted cells, in the enclosing scroll's content
    /// coordinates. Nil when nothing is mounted.
    ///
    /// The enclosing `ScrollNode` needs this to tell the renderer how far the
    /// content it drew actually reaches. Culling decides what gets *painted*,
    /// but a cell that was never mounted has nothing to paint at any cull
    /// width — so the drawn extent is whichever of the two is tighter, and
    /// this is the half only this node knows.
    var mountedSpan: (top: Float, bottom: Float)? {
        guard !mounted.isEmpty, columns > 0 else { return nil }
        // Same assumption as `visibleRange`: this node's Yoga top is its
        // offset within the scrolled content.
        let myTop = YGNodeLayoutGetTop(yogaStorage)
        let firstRow = mounted.lowerBound / columns
        let lastRow = (mounted.upperBound - 1) / columns
        return (
            myTop + Float(firstRow) * rowStride,
            myTop + Float(lastRow + 1) * rowStride
        )
    }

    /// Diagnostics: how many cells exist versus how many the data has.
    var mountedCount: Int { cells.count }
    var totalCount: Int { count }
}

// MARK: - Discovery

enum LazyGrid {
    /// Whether any lazy container exists at all, so callers can skip the walk.
    static var isInUse: Bool { LazyGridNode.liveCount > 0 }

    /// Every `LazyGridNode` in a subtree, without descending into nested
    /// scroll containers — those own their own descendants' windows.
    static func nodes(
        in node: any AnyViewNode, stopAtScroll: Bool = false
    ) -> [LazyGridNode] {
        guard isInUse else { return [] }
        var found: [LazyGridNode] = []
        collect(node, stopAtScroll: stopAtScroll, into: &found)
        return found
    }

    private static func collect(
        _ node: any AnyViewNode, stopAtScroll: Bool, into found: inout [LazyGridNode]
    ) {
        if let grid = node as? LazyGridNode {
            found.append(grid)
            // A lazy container's cells cannot themselves contain a lazy
            // container that this scroll view owns: nesting one needs its own
            // ScrollView, which the check below stops at.
            return
        }
        if stopAtScroll, node is ScrollNode { return }
        for child in node.childNodes {
            collect(child, stopAtScroll: stopAtScroll, into: &found)
        }
    }
}
