import LavaText
import XCTest

final class TextChangeLogTests: XCTestCase {
    func testEditsAreRecordedInOrderAsByteSplices() {
        var state = TextEditingState("café")
        state.setCursor(state.text.endIndex)
        let start = state.revision
        state.insert("!")
        state.setCursor(state.index(atOffset: 3))
        state.setCursor(state.index(atOffset: 4), extending: true)
        state.insert("e")
        XCTAssertEqual(state.changes(since: start), [
            TextChange(offset: 5, removedLength: 0, inserted: "!"),
            TextChange(offset: 3, removedLength: 2, inserted: "e"),
        ])
        XCTAssertEqual(state.changes(since: state.revision), [])
    }

    func testUndoAndRedoAreChangesLikeAnyOther() {
        var state = TextEditingState("ab")
        state.setCursor(state.text.endIndex)
        state.insert("c")
        let afterInsert = state.revision
        state.undo()
        state.redo()
        XCTAssertEqual(state.changes(since: afterInsert), [
            TextChange(offset: 2, removedLength: 1, inserted: ""),
            TextChange(offset: 2, removedLength: 0, inserted: "c"),
        ])
    }

    func testReplacingTheBufferForgetsTheHistory() {
        var state = TextEditingState("one")
        let start = state.revision
        state.insert("two")
        state.setText("three")
        XCTAssertNil(state.changes(since: start))
        XCTAssertNil(TextEditingState("one").changes(since: start), "another state's revision is not on record")
    }

    func testTheLogForgetsPastItsBounds() {
        var state = TextEditingState()
        let start = state.revision
        for _ in 0..<300 { state.insert("x") }
        XCTAssertNil(state.changes(since: start))

        var large = TextEditingState()
        let before = large.revision
        large.insert(String(repeating: "y", count: (1 << 20) + 1))
        XCTAssertNil(large.changes(since: before), "an insert past the byte budget is not kept")
    }
}
