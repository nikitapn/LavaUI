import Foundation
import Testing

@testable import LavaExplorerCore

// The planner is tested against a closure, the applier against a real
// folder: what matters about the second is what `rename(2)` does, and the
// interesting cases — swaps, cycles, a failure halfway — are exactly the
// ones a fake would get right by construction.

private final class Folder {
    let path: String

    init(_ files: [String: String] = [:]) throws {
        path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("lava-bulk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        for (name, contents) in files { try write(name, contents) }
    }

    deinit { try? FileManager.default.removeItem(atPath: path) }

    func write(_ name: String, _ contents: String) throws {
        try contents.write(toFile: self[name], atomically: false, encoding: .utf8)
    }

    subscript(name: String) -> String { CopyPaths.join(path, name) }

    func contents(_ name: String) -> String? {
        try? String(contentsOfFile: self[name], encoding: .utf8)
    }

    /// Name → contents for everything in the folder, temporaries included,
    /// so a stray one fails the comparison.
    var snapshot: [String: String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        return Dictionary(uniqueKeysWithValues: names.map { ($0, contents($0) ?? "<dir>") })
    }
}

private func plan(
    _ names: [String], _ text: String, taken: Set<String> = []
) -> BulkRename.Plan {
    BulkRename.plan(directory: "/d", names: names, text: text) { name, _ in taken.contains(name) }
}

private func outcomes(_ plan: BulkRename.Plan) -> [BulkRename.Outcome] { plan.rows.map(\.outcome) }

@Suite struct BulkRenameBufferTests {
    @Test func theBufferIsTheNamesOneALine() {
        #expect(BulkRename.text(of: ["a", "b c", "d"]) == "a\nb c\nd")
        #expect(BulkRename.lines(of: "a\nb c\nd") == ["a", "b c", "d"])
    }

    @Test func aTrailingNewlineAndCRLFAreNotNames() {
        #expect(BulkRename.lines(of: "a\nb\n") == ["a", "b"])
        #expect(BulkRename.lines(of: "a\r\nb\r\n") == ["a", "b"])
        // Only one: a blank last line before it is somebody's empty name.
        #expect(BulkRename.lines(of: "a\n\n") == ["a", ""])
    }
}

@Suite struct BulkRenamePlanTests {
    @Test func unchangedLinesDoNothing() {
        let plan = plan(["a", "b"], "a\nc")
        #expect(outcomes(plan) == [.unchanged, .renamed])
        #expect(plan.moves == [FileMove(from: "/d/b", to: "/d/c")])
        #expect(plan.canApply)
    }

    @Test func nothingChangedIsNothingToApply() {
        let plan = plan(["a", "b"], "a\nb\n")
        #expect(plan.moves.isEmpty)
        #expect(!plan.canApply)
    }

    @Test func spacesAtTheEndsAreTrimmedLikeASingleRename() {
        let plan = plan(["a"], "  b \t")
        #expect(plan.rows[0].newName == "b")
        #expect(outcomes(plan) == [.renamed])
    }

    @Test func theWrongNumberOfLinesBlocksEverything() {
        let short = plan(["a", "b", "c"], "x\ny")
        #expect(short.problem == "2 names for 3 items")
        #expect(outcomes(short)[2] == .problem("No line for this item"))
        #expect(!short.canApply)

        let long = plan(["a"], "x\ny")
        #expect(long.problem == "2 names for 1 item")
        #expect(!long.canApply)
    }

    @Test func aNameTheFilesystemRefusesIsAProblemOnItsRow() {
        let plan = plan(["a", "b", "c", "d"], "x/y\n\n..\nok")
        #expect(outcomes(plan) == [
            .problem("A name cannot contain \u{201C}/\u{201D}"),
            .problem("A name cannot be empty"),
            .problem("\u{201C}..\u{201D} is taken by the system"),
            .renamed,
        ])
        #expect(!plan.canApply)
    }

    @Test func twoLinesWithOneNameAreBothMarked() {
        let plan = plan(["a", "b", "c"], "x\nx\nc")
        #expect(outcomes(plan) == [
            .problem("\u{201C}x\u{201D} is on another line too"),
            .problem("\u{201C}x\u{201D} is on another line too"),
            .unchanged,
        ])
    }

    @Test func aNameARowKeepsIsNotFree() {
        // c stays c, so a cannot become c.
        let plan = plan(["a", "c"], "c\nc")
        #expect(outcomes(plan) == [.problem("\u{201C}c\u{201D} is on another line too"), .unchanged])
    }

    @Test func aNameARowLeavesIsFree() {
        let swap = plan(["a", "b"], "b\na")
        #expect(outcomes(swap) == [.renamed, .renamed])
        #expect(swap.canApply)

        let chain = plan(["a", "b"], "b\nc", taken: ["c"])
        #expect(outcomes(chain) == [.renamed, .problem("\u{201C}c\u{201D} is already here")])
    }

    @Test func aNameSomethingElseHasIsRefused() {
        // Renaming a selection: "z" is in the folder but not in the list.
        let plan = plan(["a", "b"], "z\nb", taken: ["z"])
        #expect(outcomes(plan) == [.problem("\u{201C}z\u{201D} is already here"), .unchanged])
    }

    @Test func againstTheDiskACaseOnlyChangeIsNotAClash() throws {
        let folder = try Folder(["a": "1", "b": "2"])
        let plan = BulkRename.plan(directory: folder.path, names: ["a"], text: "b")
        #expect(outcomes(plan) == [.problem("\u{201C}b\u{201D} is already here")])

        let fine = BulkRename.plan(directory: folder.path, names: ["a", "b"], text: "A\nb")
        #expect(fine.canApply)
    }
}

@Suite struct BulkRenameApplyTests {
    @Test func renamesInPlace() throws {
        let folder = try Folder(["a.txt": "A", "b.txt": "B"])
        let plan = BulkRename.plan(
            directory: folder.path, names: ["a.txt", "b.txt"], text: "001.txt\n002.txt\n"
        )
        try BulkRename.apply(plan.moves)
        #expect(folder.snapshot == ["001.txt": "A", "002.txt": "B"])
    }

    @Test func aSwapTradesContentsNotOverwrites() throws {
        let folder = try Folder(["a": "A", "b": "B"])
        let plan = BulkRename.plan(directory: folder.path, names: ["a", "b"], text: "b\na")
        try BulkRename.apply(plan.moves)
        #expect(folder.snapshot == ["a": "B", "b": "A"])
    }

    @Test func aCycleOfThreeAndAChainBesideIt() throws {
        let folder = try Folder(["a": "A", "b": "B", "c": "C", "d": "D", "e": "E"])
        // a→b→c→a is a cycle; d→e, e→f is a chain that must go e first.
        let plan = BulkRename.plan(
            directory: folder.path, names: ["a", "b", "c", "d", "e"], text: "b\nc\na\ne\nf"
        )
        #expect(plan.canApply)
        try BulkRename.apply(plan.moves)
        #expect(folder.snapshot == ["b": "A", "c": "B", "a": "C", "e": "D", "f": "E"])
    }

    @Test func foldersAreRenamedToo() throws {
        let folder = try Folder()
        try FileManager.default.createDirectory(atPath: folder["one"], withIntermediateDirectories: false)
        try folder.write("one/inside", "x")
        let plan = BulkRename.plan(directory: folder.path, names: ["one"], text: "two")
        try BulkRename.apply(plan.moves)
        #expect(folder.contents("two/inside") == "x")
    }

    @Test func aFileThatAppearedSinceThePlanStopsItBeforeAnythingMoves() throws {
        let folder = try Folder(["a": "A", "b": "B"])
        let plan = BulkRename.plan(directory: folder.path, names: ["a", "b"], text: "x\ny")
        try folder.write("y", "new")
        #expect(throws: FileAccessError(path: folder["y"], message: "\u{201C}y\u{201D} is already here")) {
            try BulkRename.apply(plan.moves)
        }
        #expect(folder.snapshot == ["a": "A", "b": "B", "y": "new"])
    }

    @Test func aSourceThatWentAwayStopsIt() throws {
        let folder = try Folder(["a": "A", "b": "B"])
        let plan = BulkRename.plan(directory: folder.path, names: ["a", "b"], text: "x\ny")
        try FileManager.default.removeItem(atPath: folder["b"])
        #expect(throws: FileAccessError(path: folder["b"], message: "\u{201C}b\u{201D} is no longer here")) {
            try BulkRename.apply(plan.moves)
        }
        #expect(folder.snapshot == ["a": "A"])
    }

    @Test func aFailureHalfwayPutsBackWhatWasDone() throws {
        let folder = try Folder(["a": "A", "b": "B", "c": "C"])
        // The check passes; the third step fails because its target is
        // inside a folder that does not exist — the cheapest real failure.
        let moves = [
            FileMove(from: folder["a"], to: folder["b"]),
            FileMove(from: folder["b"], to: folder["a"]),
            FileMove(from: folder["c"], to: folder["missing/c"]),
        ]
        #expect(throws: FileAccessError.self) { try BulkRename.apply(moves) }
        #expect(folder.snapshot == ["a": "A", "b": "B", "c": "C"])
    }

    @Test func aStepNeverReplaces() throws {
        // glibc has had renameat2 since 2.28; without it every step falls
        // back to a check and a plain rename.
        #expect(BulkRename.renameat2 != nil)
        let folder = try Folder(["a": "A", "b": "B"])
        #expect(throws: FileAccessError(path: folder["a"], message: "\u{201C}b\u{201D} is already here")) {
            try BulkRename.step(folder["a"], folder["b"])
        }
        #expect(folder.snapshot == ["a": "A", "b": "B"])
    }

    @Test func movesToThemselvesAreIgnored() throws {
        let folder = try Folder(["a": "A"])
        try BulkRename.apply([FileMove(from: folder["a"], to: folder["a"])])
        #expect(folder.snapshot == ["a": "A"])
    }

    @Test func undoAndRedoTradeBackThroughTheSameSwap() throws {
        let folder = try Folder(["a": "A", "b": "B", "c": "C"])
        let plan = BulkRename.plan(directory: folder.path, names: ["a", "b", "c"], text: "b\na\nd")
        let moves = try BulkRename.apply(plan.moves)
        #expect(folder.snapshot == ["a": "B", "b": "A", "d": "C"])

        let trash = TrashCan(dataHome: folder["share"], uid: getuid())
        var history = FileUndoHistory()
        history.record(.renamedAll(moves))
        #expect(FileChange.renamedAll(moves).count == 3)

        let undo = history.undo(using: trash)
        let undone = try #require(undo)
        #expect(undone.1.failures.isEmpty)
        #expect(undone.1.folders == [folder.path])
        #expect(folder.snapshot == ["a": "A", "b": "B", "c": "C"])

        let redo = history.redo(using: trash)
        #expect(redo?.1.failures.isEmpty == true)
        #expect(folder.snapshot == ["a": "B", "b": "A", "d": "C"])
    }

    @Test func anUndoBlockedBySomethingNewChangesNothing() throws {
        let folder = try Folder(["a": "A", "b": "B"])
        let plan = BulkRename.plan(directory: folder.path, names: ["a", "b"], text: "x\ny")
        let moves = try BulkRename.apply(plan.moves)
        try folder.write("a", "new")

        let reversal = FileChange.renamedAll(moves).reversed(
            using: TrashCan(dataHome: folder["share"], uid: getuid())
        )
        #expect(reversal.inverse == nil)
        #expect(reversal.failures.map(\.message) == ["\u{201C}a\u{201D} is already here"])
        #expect(folder.snapshot == ["a": "new", "x": "A", "y": "B"])
    }

    @Test func relocationsWithoutASwapAreTheMovesThemselves() {
        let moves = [FileMove(from: "/d/a", to: "/d/x"), FileMove(from: "/d/b", to: "/d/y")]
        #expect(FileChange.renamedAll(moves).relocations == moves)
    }

    @Test func relocationsReplayASwapWithoutUndoingIt() {
        let moves = [FileMove(from: "/d/a", to: "/d/b"), FileMove(from: "/d/b", to: "/d/a")]
        let steps = FileChange.renamedAll(moves).relocations
        // A tab in each folder, replayed the way the session replays them.
        let tabs = ["/d/a/deep", "/d/b", "/d/c"].map { path in
            steps.reduce(path) { FolderHistory.rebased($0, from: $1.from, to: $1.to) }
        }
        #expect(tabs == ["/d/b/deep", "/d/a", "/d/c"])
    }
}
