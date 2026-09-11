import Foundation

// A window split into panes, each with its own tabs, and the moves that
// rearrange them: a tab into another pane, or into a new pane beside one.
//
// Kept apart from the view for the reason the rest of this module is: the
// tree surgery is where the bugs live — a pane left empty, a split left with
// one child, two tabs answering to one id after a move — and none of it needs
// a window to get wrong.

/// Which way two panes share their space.
public enum PaneAxis: Equatable, Sendable {
    /// Side by side, the divider running top to bottom.
    case horizontal
    /// One above the other.
    case vertical
}

/// Where a new pane goes, relative to the pane it splits.
public enum PaneSide: Equatable, Sendable, CaseIterable {
    case left
    case right
    case top
    case bottom

    public var axis: PaneAxis {
        self == .left || self == .right ? .horizontal : .vertical
    }

    /// Whether the new pane comes first in its split.
    public var leads: Bool { self == .left || self == .top }
}

public struct ExplorerPane: Equatable, Sendable, Identifiable {
    public let id: Int
    public var tabs: ExplorerTabs

    public init(id: Int, tabs: ExplorerTabs) {
        self.id = id
        self.tabs = tabs
    }
}

public struct PaneSplit: Equatable, Sendable {
    public let id: Int
    public var axis: PaneAxis
    /// The first child's share of the space, between 0 and 1.
    public var fraction: Float
    public var first: PaneNode
    public var second: PaneNode
}

public indirect enum PaneNode: Equatable, Sendable {
    case pane(ExplorerPane)
    case split(PaneSplit)
}

public struct PaneLayout: Equatable, Sendable {
    public private(set) var root: PaneNode
    public private(set) var activePaneID: Int
    private var nextPaneID: Int
    private var nextSplitID = 1
    /// Tab ids are handed out here, for every pane. A tab keeps its id when it
    /// moves, so two panes numbering their own tabs would sooner or later put
    /// two tabs with one id in the same strip.
    private var nextTabID: Int

    public init(tabs: ExplorerTabs) {
        root = .pane(ExplorerPane(id: 1, tabs: tabs))
        activePaneID = 1
        nextPaneID = 2
        nextTabID = (tabs.tabs.map(\.id).max() ?? 0) + 1
    }

    // MARK: - Reading

    /// Every pane, in reading order: left before right, top before bottom.
    public var panes: [ExplorerPane] { Self.leaves(root) }

    public func pane(id: Int) -> ExplorerPane? {
        panes.first { $0.id == id }
    }

    public var activePane: ExplorerPane {
        pane(id: activePaneID) ?? panes[0]
    }

    /// The active pane's tabs — what every command without a pane of its own
    /// (a key, a menu item) acts on.
    public var activeTabs: ExplorerTabs {
        get { activePane.tabs }
        set { updatePane(id: activePaneID) { $0.tabs = newValue } }
    }

    public func tab(id: Int) -> ExplorerTab? {
        for pane in panes {
            if let tab = pane.tabs.tab(id: id) { return tab }
        }
        return nil
    }

    public func paneID(containingTab id: Int) -> Int? {
        panes.first { $0.tabs.tab(id: id) != nil }?.id
    }

    public func fraction(split id: Int) -> Float? {
        Self.findSplit(root, id: id)?.fraction
    }

    // MARK: - Tabs and panes

    public mutating func activate(pane id: Int) {
        guard pane(id: id) != nil else { return }
        activePaneID = id
    }

    /// Selects a tab wherever it is, and makes its pane the active one.
    public mutating func selectTab(_ tabID: Int) {
        guard let paneID = paneID(containingTab: tabID) else { return }
        activePaneID = paneID
        updatePane(id: paneID) { $0.tabs.select(id: tabID) }
    }

    /// A new tab on `path` in the active pane.
    public mutating func openTab(path: String, source: any FileSource) {
        let id = nextTabID
        nextTabID += 1
        updatePane(id: activePaneID) { $0.tabs.open(path: path, source: source, id: id) }
    }

    public mutating func updatePane(id: Int, _ body: (inout ExplorerPane) -> Void) {
        root = Self.mapPane(root, id: id, body)
    }

    /// Every tab in every pane that shows `directory`.
    public mutating func updateTabs(
        showing directory: String, _ body: (inout ExplorerTab) -> Void
    ) {
        for pane in panes {
            updatePane(id: pane.id) { $0.tabs.updateTabs(showing: directory, body) }
        }
    }

    public mutating func setFraction(split id: Int, _ value: Float) {
        root = Self.mapSplit(root, id: id) { $0.fraction = min(max(value, 0.05), 0.95) }
    }

    /// Whether dropping `tabID` on `target` would do anything: into it when
    /// `side` is nil, beside it otherwise.
    ///
    /// Into the pane it is already in is nothing. Beside its own pane needs a
    /// second tab there to stay behind — splitting a pane by its only tab
    /// would leave an empty pane next to the one it came from.
    ///
    /// `gap` is a place in the target's strip (see `ExplorerTabs.move`). With
    /// one, the pane a tab is already in is a fair target — that is a reorder
    /// — unless the gap is either side of the tab itself.
    public func canDrop(
        tab tabID: Int, on target: Int, side: PaneSide?, gap: Int? = nil
    ) -> Bool {
        guard let source = paneID(containingTab: tabID), let targetPane = pane(id: target)
        else { return false }
        if side != nil {
            if source == target {
                return targetPane.tabs.tabs.count > 1
            }
            return true
        }
        if let gap, source == target {
            guard let from = targetPane.tabs.tabs.firstIndex(where: { $0.id == tabID })
            else { return false }
            return gap != from && gap != from + 1
        }
        return source != target
    }

    /// Moves a tab into a pane — at `gap` in its strip, or after its current
    /// tab — selected, and activates that pane. Within one pane that is a
    /// reorder. A pane left with no tabs closes. False when nothing changed.
    @discardableResult
    public mutating func moveTab(_ tabID: Int, to target: Int, gap: Int? = nil) -> Bool {
        guard canDrop(tab: tabID, on: target, side: nil, gap: gap),
              let source = paneID(containingTab: tabID)
        else { return false }
        if source == target, let gap {
            updatePane(id: target) { $0.tabs.move(id: tabID, toGap: gap) }
            activePaneID = target
            return true
        }
        guard let tab = takeTab(tabID, from: source) else { return false }
        updatePane(id: target) { pane in
            if let gap {
                pane.tabs.insert(tab, at: gap)
            } else {
                pane.tabs.insert(tab)
            }
        }
        activePaneID = target
        return true
    }

    /// Moves a tab into a new pane on `side` of `target`, splitting it in
    /// half, and activates the new pane. A pane left with no tabs closes.
    /// False when nothing changed.
    @discardableResult
    public mutating func splitTab(_ tabID: Int, beside target: Int, on side: PaneSide) -> Bool {
        guard canDrop(tab: tabID, on: target, side: side),
              let source = paneID(containingTab: tabID),
              let tab = takeTab(tabID, from: source)
        else { return false }
        let fresh = ExplorerPane(id: nextPaneID, tabs: ExplorerTabs(tab: tab))
        nextPaneID += 1
        let splitID = nextSplitID
        nextSplitID += 1
        // Found by id, after the take: removing the source may have collapsed
        // the split `target` was in and moved it up the tree.
        root = Self.replacePane(root, id: target) { existing in
            .split(PaneSplit(
                id: splitID, axis: side.axis, fraction: 0.5,
                first: side.leads ? .pane(fresh) : existing,
                second: side.leads ? existing : .pane(fresh)
            ))
        }
        activePaneID = fresh.id
        return true
    }

    /// Closes a tab, and its pane with it if it was that pane's last. False
    /// when it was the window's last tab, which is the window's to close.
    public mutating func closeTab(_ tabID: Int) -> Bool {
        guard let paneID = paneID(containingTab: tabID) else { return true }
        if panes.count == 1, (pane(id: paneID)?.tabs.tabs.count ?? 0) <= 1 {
            return false
        }
        _ = takeTab(tabID, from: paneID)
        return true
    }

    // MARK: - Tree surgery

    /// Takes a tab out of its pane, and removes the pane if that emptied it.
    private mutating func takeTab(_ tabID: Int, from paneID: Int) -> ExplorerTab? {
        var taken: ExplorerTab?
        updatePane(id: paneID) { taken = $0.tabs.remove(id: tabID) }
        guard taken != nil else { return nil }
        if pane(id: paneID)?.tabs.tabs.isEmpty == true { removePane(paneID) }
        return taken
    }

    /// Removes a pane; its sibling takes the whole of the split they shared.
    private mutating func removePane(_ id: Int) {
        guard panes.count > 1, let remaining = Self.removing(root, id: id) else { return }
        root = remaining
        if pane(id: activePaneID) == nil { activePaneID = panes[0].id }
    }

    static func leaves(_ node: PaneNode) -> [ExplorerPane] {
        switch node {
        case .pane(let pane): return [pane]
        case .split(let split): return leaves(split.first) + leaves(split.second)
        }
    }

    static func mapPane(
        _ node: PaneNode, id: Int, _ body: (inout ExplorerPane) -> Void
    ) -> PaneNode {
        switch node {
        case .pane(var pane):
            if pane.id == id { body(&pane) }
            return .pane(pane)
        case .split(var split):
            split.first = mapPane(split.first, id: id, body)
            split.second = mapPane(split.second, id: id, body)
            return .split(split)
        }
    }

    static func replacePane(
        _ node: PaneNode, id: Int, _ transform: (PaneNode) -> PaneNode
    ) -> PaneNode {
        switch node {
        case .pane(let pane):
            return pane.id == id ? transform(node) : node
        case .split(var split):
            split.first = replacePane(split.first, id: id, transform)
            split.second = replacePane(split.second, id: id, transform)
            return .split(split)
        }
    }

    static func mapSplit(
        _ node: PaneNode, id: Int, _ body: (inout PaneSplit) -> Void
    ) -> PaneNode {
        guard case .split(var split) = node else { return node }
        if split.id == id { body(&split) }
        split.first = mapSplit(split.first, id: id, body)
        split.second = mapSplit(split.second, id: id, body)
        return .split(split)
    }

    static func findSplit(_ node: PaneNode, id: Int) -> PaneSplit? {
        guard case .split(let split) = node else { return nil }
        if split.id == id { return split }
        return findSplit(split.first, id: id) ?? findSplit(split.second, id: id)
    }

    /// `node` without pane `id`, or nil when `node` *is* that pane. A split
    /// that loses a child becomes the child it has left.
    static func removing(_ node: PaneNode, id: Int) -> PaneNode? {
        switch node {
        case .pane(let pane):
            return pane.id == id ? nil : node
        case .split(var split):
            guard let first = removing(split.first, id: id) else { return split.second }
            guard let second = removing(split.second, id: id) else { return split.first }
            split.first = first
            split.second = second
            return .split(split)
        }
    }
}

/// A rectangle, in whatever coordinates the caller works in.
public struct PaneRect: Equatable, Sendable {
    public var x: Float
    public var y: Float
    public var w: Float
    public var h: Float

    public init(x: Float, y: Float, w: Float, h: Float) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }

    public func contains(x px: Float, y py: Float) -> Bool {
        px >= x && px < x + w && py >= y && py < y + h
    }
}

/// Where a tab dragged over a pane would land.
public enum PaneDropZone {
    /// How far in from an edge, as a share of the pane, still means "a new
    /// pane on that side". Past it, the middle, is "into this pane" — the
    /// bigger target, because it is the more common intent.
    public static let edgeShare: Float = 0.25

    /// The side a drop at `x`,`y` splits `rect` on, or nil for into the pane.
    ///
    /// Over the pane's tab strip is always into: that is where its tabs are,
    /// and a drop among them means "one more of these".
    public static func side(
        atX x: Float, y: Float, in rect: PaneRect, stripHeight: Float
    ) -> PaneSide? {
        if y < rect.y + stripHeight { return nil }
        let u = (x - rect.x) / max(rect.w, 1)
        let v = (y - rect.y) / max(rect.h, 1)
        let nearest = [
            (PaneSide.left, u), (.right, 1 - u), (.top, v), (.bottom, 1 - v),
        ].min { $0.1 < $1.1 }!
        return nearest.1 <= edgeShare ? nearest.0 : nil
    }

    /// The gap in a strip a tab let go of at `x` goes into: 0 before the
    /// first tab, `spans.count` after the last. A tab counts as passed once
    /// the pointer is beyond its middle, which is where every browser puts
    /// the line. `spans` are the tabs in strip order.
    public static func gap(atX x: Float, tabSpans spans: [(x: Float, w: Float)]) -> Int {
        spans.filter { x > $0.x + $0.w / 2 }.count
    }

    /// The part of `rect` a drop on `side` would occupy — what to highlight.
    public static func preview(for side: PaneSide?, in rect: PaneRect) -> PaneRect {
        switch side {
        case nil: return rect
        case .left?: return PaneRect(x: rect.x, y: rect.y, w: rect.w / 2, h: rect.h)
        case .right?: return PaneRect(x: rect.x + rect.w / 2, y: rect.y, w: rect.w / 2, h: rect.h)
        case .top?: return PaneRect(x: rect.x, y: rect.y, w: rect.w, h: rect.h / 2)
        case .bottom?: return PaneRect(x: rect.x, y: rect.y + rect.h / 2, w: rect.w, h: rect.h / 2)
        }
    }
}
