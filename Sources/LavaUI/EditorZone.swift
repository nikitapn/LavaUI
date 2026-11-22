import CYoga
import Foundation

/// A place between an editor's lines where the app puts a view of its own —
/// an inline chat, a review comment.
///
/// The space is reserved the way any blank rows are, with an
/// `EditorLineGap` above `line`; this says *which* gap the view belongs to.
/// The editor writes where that gap landed every time it draws, in its own
/// box's coordinates, and `.editorZone(_:)` places the view there.
///
/// Why the editor has to say: it scrolls by itself — it draws only the rows
/// on screen, at its own offset — so no layout pass knows where a line is.
/// The view is drawn at the gap's place in the same frame the text moved,
/// and laid out there on the next, which is when clicks catch up.
public final class EditorZoneAnchor {
    /// The logical line the gap is above, from 0. The line count puts it
    /// below the last line.
    public var line: Int
    /// The gap's rectangle in the editor's box — text area only, the gutter
    /// left out — as last drawn. Nil before the first draw, and while the
    /// editor has no gap at `line`.
    public internal(set) var frame: CGRect?
    /// The editor's row height when it last drew, which turns the zone's
    /// rows into points before the editor has drawn the gap at its new size.
    public internal(set) var lineHeight: Float?

    public init(line: Int) {
        self.line = line
    }
}

/// `content` with `zone` laid over it at the anchor's gap, clipped to
/// `content`'s box. Usually spelled `.editorZone(_:isPresented:_:)`.
///
/// Always in the tree, presented or not: wrapping an editor only while a
/// zone is open would change the view's type, which remounts the editor —
/// and an editor remounted draws a frame at the top before its place is
/// restored.
public struct EditorZoneView<Content: View, Zone: View>: PrimitiveView {
    public var content: Content
    public var zone: Zone
    public var anchor: EditorZoneAnchor
    /// The gap's height in rows, as the app reserved it.
    public var rows: Int
    public var isPresented: Bool

    public init(content: Content, zone: Zone, anchor: EditorZoneAnchor, rows: Int, isPresented: Bool) {
        self.content = content
        self.zone = zone
        self.anchor = anchor
        self.rows = rows
        self.isPresented = isPresented
    }

    public var dumpDetail: String { "editorZone line \(anchor.line)" }

    public func structureLines(indent: Int = 0) -> [String] {
        Dump.structureLines(
            indent: indent, label: "EditorZone",
            childLines: [content.structureLines(indent: indent + 1), zone.structureLines(indent: indent + 1)]
        )
    }

    public func mountPrimitive() -> any AnyViewNode {
        let node = EditorZoneNode(
            content: ViewGraph.mount(content),
            zone: StyleBoxNode(content: ViewGraph.mount(zone)),
            anchor: anchor
        )
        node.rows = rows
        node.setPresented(isPresented)
        node.place()
        return node
    }

    public func reconcilePrimitive(_ node: any AnyViewNode) -> any AnyViewNode {
        guard let box = node as? EditorZoneNode else { return mountPrimitive() }
        box.anchor = anchor
        box.rows = rows
        box.updateContent(ViewGraph.reconcile(box.contentNode, with: content))
        box.zoneBox.updateContent(ViewGraph.reconcile(box.zoneBox.contentNode, with: zone))
        box.setPresented(isPresented)
        box.place()
        return box
    }
}

final class EditorZoneNode: YogaBoxNode {
    private(set) var contentNode: any AnyViewNode
    /// Absolute, at the anchor's frame; hidden while not presented.
    let zoneBox: StyleBoxNode
    var anchor: EditorZoneAnchor
    var rows = 0
    private var insertedLeaves: [any AnyViewNode] = []
    private var linked = false
    /// The frame the zone box was last given, to tell a move from no move.
    private var placed: CGRect?

    init(content: any AnyViewNode, zone: StyleBoxNode, anchor: EditorZoneAnchor) {
        contentNode = content
        zoneBox = zone
        self.anchor = anchor
        super.init(label: "EditorZone")
        YGNodeStyleSetFlexDirection(yogaStorage, YGFlexDirectionColumn)
        YGNodeStyleSetAlignItems(yogaStorage, YGAlignStretch)
        // The zone must not take clicks from outside the editor when it is
        // scrolled half out of it: the hit walks skip a clipping box's
        // children outside its rectangle.
        clipsContent = true
        inheritFlex(from: content)
        applyStyle()
        place()
        relink()
    }

    override var childNodes: [any AnyViewNode] { [contentNode, zoneBox] }

    var isPresented: Bool { !zoneBox.isHidden }

    func setPresented(_ presented: Bool) {
        guard zoneBox.isHidden == presented else { return }
        zoneBox.isHidden = !presented
        if let box = zoneBox.yoga {
            YGNodeStyleSetDisplay(box, presented ? YGDisplayFlex : YGDisplayNone)
        }
        placed = nil
    }

    func updateContent(_ node: any AnyViewNode) {
        contentNode = node
        inheritFlex(from: node)
        relink()
    }

    private func inheritFlex(from node: any AnyViewNode) {
        let leaves = node.flattenedLayoutNodes().compactMap { $0 as? YogaBoxNode }
        flexGrow = leaves.map(\.flexGrow).max() ?? 0
        flexShrink = leaves.map(\.effectiveFlexShrink).min()
    }

    /// Puts the zone box at the anchor's frame for the next layout. True
    /// when that moved it — the caller then asks for the layout.
    @discardableResult
    func place() -> Bool {
        zoneBox.flexGrow = 0
        zoneBox.flexShrink = 0
        zoneBox.applyStyle()
        guard let box = zoneBox.yoga else { return false }
        // Off in the distance until the editor has said where: a zone drawn
        // at the top for one frame would be a flicker.
        var frame = anchor.frame ?? CGRect(x: 0, y: -100_000, width: 1, height: 1)
        // The height the app is asking for now, not the gap's as last drawn:
        // a box that grows (a reply arriving) is then laid out at its new
        // size in the frame the editor makes room, rather than one later.
        if let lineHeight = anchor.lineHeight, rows > 0 { frame.size.height = CGFloat(Float(rows) * lineHeight) }
        YGNodeStyleSetPositionType(box, YGPositionTypeAbsolute)
        YGNodeStyleSetPosition(box, YGEdgeLeft, Float(frame.minX))
        YGNodeStyleSetPosition(box, YGEdgeTop, Float(frame.minY))
        YGNodeStyleSetWidth(box, Float(frame.width))
        YGNodeStyleSetHeight(box, Float(frame.height))
        defer { placed = frame }
        return placed != frame
    }

    /// Where the zone box was laid out, in this node's coordinates.
    var laidOutFrame: (x: Float, y: Float, w: Float, h: Float)? {
        guard let box = zoneBox.yoga else { return nil }
        return (YGNodeLayoutGetLeft(box), YGNodeLayoutGetTop(box),
                YGNodeLayoutGetWidth(box), YGNodeLayoutGetHeight(box))
    }

    private func relink() {
        let leaves = contentNode.flattenedLayoutNodes()
        guard !linked || yogaChildrenChanged(leaves, insertedLeaves) else { return }
        YGNodeRemoveAllChildren(yogaStorage)
        insertedLeaves = leaves
        var index = 0
        for leaf in insertedLeaves {
            guard let y = leaf.yoga else { continue }
            YGNodeInsertChild(yogaStorage, y, index)
            index += 1
        }
        if let y = zoneBox.yoga { YGNodeInsertChild(yogaStorage, y, index) }
        linked = true
    }

    override func collectChildFrames(
        originX: Float, originY: Float, into frames: inout [LayoutFrame]
    ) {
        for child in childNodes {
            child.collectFrames(originX: originX, originY: originY, into: &frames)
        }
    }
}

extension View {
    /// Lays `zone` over this editor at `anchor`'s gap while `isPresented`.
    /// The gap itself is the app's to reserve, as an `EditorLineGap` of
    /// `rows` at `anchor.line`; pass the same anchor to the editor's
    /// `zone:`. See `EditorZoneAnchor`.
    public func editorZone<Zone: View>(
        _ anchor: EditorZoneAnchor, rows: Int, isPresented: Bool, @ViewBuilder _ zone: () -> Zone
    ) -> EditorZoneView<Self, Zone> {
        EditorZoneView(content: self, zone: zone(), anchor: anchor, rows: rows, isPresented: isPresented)
    }
}
