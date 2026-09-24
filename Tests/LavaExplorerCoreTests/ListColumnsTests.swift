import Testing

@testable import LavaExplorerCore

@Suite struct ListColumnsTests {
    @Test func theEdgeBeforeSizeFollowsThePointer() {
        let columns = ListColumns(size: 88, modified: 148)
        let wider = columns.dragging(.nameSize, by: -40, nameRoom: 600)
        #expect(wider.size == 128)
        #expect(wider.modified == 148)
        let narrower = columns.dragging(.nameSize, by: 20, nameRoom: 600)
        #expect(narrower.size == 68)
    }

    @Test func theEdgeBeforeModifiedTradesBetweenTheTwo() {
        let columns = ListColumns(size: 88, modified: 148)
        let moved = columns.dragging(.sizeModified, by: 30, nameRoom: 600)
        #expect(moved.size == 118)
        #expect(moved.modified == 118)
        #expect(moved.size + moved.modified == columns.size + columns.modified)
    }

    @Test func noColumnGoesBelowItsMinimum() {
        let columns = ListColumns(size: 88, modified: 148)
        #expect(columns.dragging(.nameSize, by: 500, nameRoom: 600).size == ListColumns.minimumWidth)
        let right = columns.dragging(.sizeModified, by: 500, nameRoom: 600)
        #expect(right.modified == ListColumns.minimumWidth)
        #expect(right.size == 88 + 148 - ListColumns.minimumWidth)
        let left = columns.dragging(.sizeModified, by: -500, nameRoom: 600)
        #expect(left.size == ListColumns.minimumWidth)
    }

    @Test func sizeCannotSqueezeNameOut() {
        let columns = ListColumns(size: 88, modified: 148)
        let grown = columns.dragging(.nameSize, by: -1000, nameRoom: 400)
        #expect(grown.size == 400 - 148 - ListColumns.minimumNameWidth)
        let unknown = columns.dragging(.nameSize, by: -1000, nameRoom: nil)
        #expect(unknown.size == 1088)
    }
}
