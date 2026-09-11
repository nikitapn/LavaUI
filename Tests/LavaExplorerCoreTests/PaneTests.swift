import Foundation
import Testing

@testable import LavaExplorerCore

// The pane tree without a window. Every test builds tabs directly rather than
// through a file source: what is under test is where tabs and panes end up,
// not what is in the folders they show.
//
// Mutating calls are made first and asserted on after: `#expect` takes its
// expression as a closure, and a mutating call cannot happen inside one.

private func tab(_ id: Int, _ path: String = "/tmp") -> ExplorerTab {
    ExplorerTab(
        id: id, history: FolderHistory(path: path), listing: FolderListing(path: path)
    )
}

private func strip(_ ids: Int...) -> ExplorerTabs {
    var tabs = ExplorerTabs(tab: tab(ids[0]))
    for id in ids.dropFirst() { tabs.insert(tab(id)) }
    return tabs
}

private func tabIDs(_ layout: PaneLayout) -> [[Int]] {
    layout.panes.map { $0.tabs.tabs.map(\.id) }
}

@Suite("Splitting panes")
struct PaneSplitTests {
    @Test("Each side puts the new pane first or second, on the right axis")
    func sides() {
        for side in PaneSide.allCases {
            var layout = PaneLayout(tabs: strip(1, 2))
            let split = layout.splitTab(2, beside: 1, on: side)
            #expect(split, "\(side)")
            guard case .split(let node) = layout.root else {
                Issue.record("\(side): no split")
                continue
            }
            #expect(node.axis == side.axis)
            var newFirst = false
            if case .pane(let pane) = node.first {
                newFirst = pane.tabs.tabs.map(\.id) == [2]
            }
            #expect(newFirst == side.leads, "\(side)")
            #expect(layout.activePane.tabs.current.id == 2)
        }
    }

    @Test("A pane cannot be split by its only tab")
    func onlyTab() {
        var layout = PaneLayout(tabs: strip(1))
        let before = layout
        #expect(!layout.canDrop(tab: 1, on: 1, side: .right))
        let split = layout.splitTab(1, beside: 1, on: .right)
        #expect(!split)
        #expect(layout == before)
    }

    @Test("Splitting a pane inside a split nests rather than replacing")
    func nesting() {
        var layout = PaneLayout(tabs: strip(1, 2, 3))
        layout.splitTab(2, beside: 1, on: .right)
        let right = layout.activePaneID
        layout.splitTab(3, beside: right, on: .bottom)
        #expect(layout.panes.count == 3)
        #expect(tabIDs(layout) == [[1], [2], [3]])
        guard case .split(let outer) = layout.root, case .split(let inner) = outer.second else {
            Issue.record("expected a vertical split inside the right half")
            return
        }
        #expect(outer.axis == .horizontal)
        #expect(inner.axis == .vertical)
    }

    @Test("Fractions are addressed by split and kept off the edges")
    func fractions() {
        var layout = PaneLayout(tabs: strip(1, 2))
        layout.splitTab(2, beside: 1, on: .left)
        guard case .split(let split) = layout.root else {
            Issue.record("no split")
            return
        }
        layout.setFraction(split: split.id, 0.3)
        #expect(layout.fraction(split: split.id) == 0.3)
        layout.setFraction(split: split.id, 2)
        #expect(layout.fraction(split: split.id) == 0.95)
    }
}

@Suite("Moving tabs")
struct PaneMoveTests {
    @Test("A tab moved into another pane is selected there, and that pane is active")
    func move() {
        var layout = PaneLayout(tabs: strip(1, 2, 3))
        layout.splitTab(3, beside: 1, on: .right)
        let right = layout.activePaneID
        layout.activate(pane: layout.panes[0].id)

        let moved = layout.moveTab(2, to: right)
        #expect(moved)
        #expect(tabIDs(layout) == [[1], [3, 2]])
        #expect(layout.activePaneID == right)
        #expect(layout.activePane.tabs.current.id == 2)
    }

    @Test("A pane that loses its last tab closes, and its neighbour takes the space")
    func collapse() {
        var layout = PaneLayout(tabs: strip(1, 2))
        layout.splitTab(2, beside: 1, on: .right)
        let moved = layout.moveTab(2, to: layout.panes[0].id)
        #expect(moved)
        guard case .pane(let pane) = layout.root else {
            Issue.record("the split should have gone with its empty pane")
            return
        }
        #expect(pane.tabs.tabs.map(\.id) == [1, 2])
        #expect(layout.activePaneID == pane.id)
    }

    @Test("A tab dropped into the pane it is already in does nothing")
    func intoItsOwnPane() {
        var layout = PaneLayout(tabs: strip(1, 2))
        #expect(!layout.canDrop(tab: 2, on: 1, side: nil))
        let moved = layout.moveTab(2, to: 1)
        #expect(!moved)
    }

    @Test("Splitting beside a pane whose sibling empties still finds the target")
    func targetMovesUpTheTree() {
        // [1] | [2]; drag the only tab of the right pane to the bottom of the
        // left one. Taking it collapses the root split, so pane 1 is the root
        // by the time the new split goes in.
        var layout = PaneLayout(tabs: strip(1, 2))
        layout.splitTab(2, beside: 1, on: .right)
        let left = layout.panes[0].id
        let split = layout.splitTab(2, beside: left, on: .bottom)
        #expect(split)
        #expect(tabIDs(layout) == [[1], [2]])
        guard case .split(let node) = layout.root else {
            Issue.record("no split")
            return
        }
        #expect(node.axis == .vertical)
    }

    @Test("Closing the last tab of the last pane is the window's decision")
    func lastTab() {
        var layout = PaneLayout(tabs: strip(1, 2))
        layout.splitTab(2, beside: 1, on: .right)
        let closedSecond = layout.closeTab(2)
        #expect(closedSecond)
        #expect(layout.panes.count == 1)
        let closedLast = layout.closeTab(1)
        #expect(!closedLast)
        #expect(tabIDs(layout) == [[1]])
    }

    @Test("Tab ids stay unique across panes after moves")
    func uniqueIDs() {
        let folder = NSTemporaryDirectory()
        var layout = PaneLayout(tabs: strip(1, 2))
        layout.splitTab(2, beside: 1, on: .right)
        layout.openTab(path: folder, source: LocalFileSource())
        layout.activate(pane: layout.panes[0].id)
        layout.openTab(path: folder, source: LocalFileSource())
        let ids = layout.panes.flatMap { $0.tabs.tabs.map(\.id) }
        #expect(Set(ids).count == ids.count)
    }

    @Test("Selecting a tab in another pane activates that pane")
    func selectAcrossPanes() {
        var layout = PaneLayout(tabs: strip(1, 2, 3))
        layout.splitTab(3, beside: 1, on: .right)
        layout.selectTab(1)
        #expect(layout.activePaneID == layout.panes[0].id)
        #expect(layout.activePane.tabs.current.id == 1)
    }
}

@Suite("Drop zones")
struct PaneDropZoneTests {
    private let rect = PaneRect(x: 100, y: 50, w: 400, h: 300)

    @Test("Over the tab strip is always into the pane")
    func strip() {
        #expect(PaneDropZone.side(atX: 105, y: 60, in: rect, stripHeight: 36) == nil)
    }

    @Test("Near an edge splits on that side; the middle is into")
    func edges() {
        #expect(PaneDropZone.side(atX: 110, y: 200, in: rect, stripHeight: 36) == .left)
        #expect(PaneDropZone.side(atX: 490, y: 200, in: rect, stripHeight: 36) == .right)
        #expect(PaneDropZone.side(atX: 300, y: 340, in: rect, stripHeight: 36) == .bottom)
        #expect(PaneDropZone.side(atX: 300, y: 100, in: rect, stripHeight: 36) == .top)
        #expect(PaneDropZone.side(atX: 300, y: 200, in: rect, stripHeight: 36) == nil)
    }

    @Test("The preview covers the half a new pane would take")
    func preview() {
        #expect(PaneDropZone.preview(for: .right, in: rect) == PaneRect(x: 300, y: 50, w: 200, h: 300))
        #expect(PaneDropZone.preview(for: .top, in: rect) == PaneRect(x: 100, y: 50, w: 400, h: 150))
        #expect(PaneDropZone.preview(for: nil, in: rect) == rect)
    }
}
