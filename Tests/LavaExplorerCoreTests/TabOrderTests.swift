import Foundation
import Testing

@testable import LavaExplorerCore

// Reordering tabs, within a strip and into a place in another pane's strip.
// Mutating calls are made first and asserted on after: `#expect` takes its
// expression as a closure, and a mutating call cannot happen inside one.

private func tab(_ id: Int) -> ExplorerTab {
    ExplorerTab(id: id, history: FolderHistory(path: "/tmp"), listing: FolderListing(path: "/tmp"))
}

private func strip(_ ids: Int...) -> ExplorerTabs {
    var tabs = ExplorerTabs(tab: tab(ids[0]))
    for id in ids.dropFirst() { tabs.insert(tab(id), at: tabs.tabs.count) }
    return tabs
}

@Suite("Reordering a strip")
struct StripOrderTests {
    @Test("A tab moves into the gap it was dropped in, counted before it moved")
    func gaps() {
        var right = strip(1, 2, 3, 4)
        let movedRight = right.move(id: 1, toGap: 3)
        #expect(movedRight)
        #expect(right.tabs.map(\.id) == [2, 3, 1, 4])
        #expect(right.current.id == 1)

        var left = strip(1, 2, 3, 4)
        let movedLeft = left.move(id: 4, toGap: 0)
        #expect(movedLeft)
        #expect(left.tabs.map(\.id) == [4, 1, 2, 3])

        var end = strip(1, 2, 3)
        let movedToEnd = end.move(id: 1, toGap: 3)
        #expect(movedToEnd)
        #expect(end.tabs.map(\.id) == [2, 3, 1])
    }

    @Test("The gaps either side of a tab leave it where it is")
    func stayPut() {
        var tabs = strip(1, 2, 3)
        let before = tabs.move(id: 2, toGap: 1)
        let after = tabs.move(id: 2, toGap: 2)
        #expect(!before)
        #expect(!after)
        #expect(tabs.tabs.map(\.id) == [1, 2, 3])
    }
}

@Suite("Moving tabs to a place")
struct PaneGapTests {
    @Test("Within a pane, a gap is a reorder")
    func reorder() {
        var layout = PaneLayout(tabs: strip(1, 2, 3))
        #expect(layout.canDrop(tab: 1, on: 1, side: nil, gap: 3))
        #expect(!layout.canDrop(tab: 1, on: 1, side: nil, gap: 1))
        let moved = layout.moveTab(1, to: 1, gap: 3)
        #expect(moved)
        #expect(layout.panes[0].tabs.tabs.map(\.id) == [2, 3, 1])
    }

    @Test("Into another pane, a gap is where the tab goes")
    func intoAnotherPane() {
        var layout = PaneLayout(tabs: strip(1, 2, 3, 4))
        layout.splitTab(4, beside: 1, on: .right)
        let right = layout.activePaneID
        layout.moveTab(3, to: right)
        #expect(layout.pane(id: right)?.tabs.tabs.map(\.id) == [4, 3])

        let moved = layout.moveTab(1, to: right, gap: 0)
        #expect(moved)
        #expect(layout.pane(id: right)?.tabs.tabs.map(\.id) == [1, 4, 3])
        #expect(layout.activePane.tabs.current.id == 1)
    }
}

@Suite("Where in a strip")
struct StripGapTests {
    private let spans: [(x: Float, w: Float)] = [(10, 100), (114, 80), (198, 120)]

    @Test("A tab counts as passed once the pointer is beyond its middle")
    func middles() {
        #expect(PaneDropZone.gap(atX: 0, tabSpans: spans) == 0)
        #expect(PaneDropZone.gap(atX: 59, tabSpans: spans) == 0)
        #expect(PaneDropZone.gap(atX: 61, tabSpans: spans) == 1)
        #expect(PaneDropZone.gap(atX: 160, tabSpans: spans) == 2)
        #expect(PaneDropZone.gap(atX: 900, tabSpans: spans) == 3)
    }

    @Test("An empty strip has one gap")
    func empty() {
        #expect(PaneDropZone.gap(atX: 50, tabSpans: []) == 0)
    }
}
