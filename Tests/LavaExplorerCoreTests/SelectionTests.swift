import Testing

@testable import LavaExplorerCore

@Suite struct SelectionTests {
    let order = ["a", "b", "c", "d", "e"]

    @Test func aClickSelectsOneRow() {
        var selection = FileSelection()
        selection.select("b")
        selection.select("d")
        #expect(selection.paths == ["d"])
        #expect(selection.lead == "d")
    }

    @Test func controlTogglesWithoutTouchingTheRest() {
        var selection = FileSelection()
        selection.select("a")
        selection.toggle("c")
        selection.toggle("e")
        #expect(selection.ordered(order) == ["a", "c", "e"])
        selection.toggle("c")
        #expect(selection.ordered(order) == ["a", "e"])
        #expect(selection.lead == "c", "the keyboard stays where the click was")
    }

    @Test func shiftSelectsFromTheAnchorAndMovesOnlyTheFarEnd() {
        var selection = FileSelection()
        selection.select("b")
        selection.extend(to: "d", in: order)
        #expect(selection.ordered(order) == ["b", "c", "d"])
        // Shrinking back past the anchor flips the range; the anchor stays.
        selection.extend(to: "a", in: order)
        #expect(selection.ordered(order) == ["a", "b"])
        #expect(selection.anchor == "b")
        #expect(selection.lead == "a")
    }

    @Test func controlShiftAddsASecondRange() {
        var selection = FileSelection()
        selection.select("a")
        selection.toggle("d")
        selection.extend(to: "e", in: order, adding: true)
        #expect(selection.ordered(order) == ["a", "d", "e"])
    }

    @Test func shiftWithNothingToStartFromSelectsTheRow() {
        var selection = FileSelection()
        selection.extend(to: "c", in: order)
        #expect(selection.paths == ["c"])
    }

    @Test func aReloadForgetsWhatWentAway() {
        var selection = FileSelection()
        selection.select("a")
        selection.extend(to: "c", in: order)
        selection.keep(only: ["a", "b", "d"])
        #expect(selection.ordered(order) == ["a", "b"])
        #expect(selection.lead == nil, "c was the lead and is gone")
        selection.keep(only: ["b"])
        #expect(selection.lead == "b", "one row left is the lead again")
    }

    @Test func selectAllKeepsTheLead() {
        var selection = FileSelection()
        selection.select("c")
        selection.selectAll(order)
        #expect(selection.count == 5)
        #expect(selection.lead == "c")
    }

    @Test func aTabsSelectionSurvivesAReloadThatKeepsItsFiles() {
        let source = FakeSource(["/f": ["x.txt", "y.txt", "z.txt"]])
        var tab = ExplorerTab.open(id: 1, path: "/f", source: source)
        tab.selection.select("/f/x.txt")
        tab.selection.extend(to: "/f/z.txt", in: tab.listing.entries.map(\.path))
        #expect(tab.selectedEntries.map(\.name) == ["x.txt", "y.txt", "z.txt"])
        tab.reload(from: FakeSource(["/f": ["x.txt", "z.txt"]]))
        #expect(tab.selectedEntries.map(\.name) == ["x.txt", "z.txt"])
    }
}

private struct FakeSource: FileSource {
    let folders: [String: [String]]

    init(_ folders: [String: [String]]) { self.folders = folders }

    func entries(in directory: String) throws -> [FileEntry] {
        (folders[directory] ?? []).map {
            FileEntry(path: directory + "/" + $0, isDirectory: false)
        }
    }

    func entry(at path: String) throws -> FileEntry {
        FileEntry(path: path, isDirectory: folders[path] != nil)
    }

    func exists(_ path: String) -> Bool { true }
}
