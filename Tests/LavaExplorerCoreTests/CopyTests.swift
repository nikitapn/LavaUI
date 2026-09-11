import Foundation
import Testing

@testable import LavaExplorerCore

// A drop is the first thing in Explorer that writes to the disk, so these run
// against a real one — a temporary directory per test — rather than a fake
// source. What goes wrong with copies is what `FileManager` does, not what a
// model of it does.

private final class Scratch {
    let root: String

    init() throws {
        root = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("lava-copy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            atPath: root, withIntermediateDirectories: true
        )
    }

    deinit { try? FileManager.default.removeItem(atPath: root) }

    func path(_ relative: String) -> String {
        (root as NSString).appendingPathComponent(relative)
    }

    func folder(_ relative: String) throws {
        try FileManager.default.createDirectory(
            atPath: path(relative), withIntermediateDirectories: true
        )
    }

    func file(_ relative: String, _ text: String) throws {
        try Data(text.utf8).write(to: URL(fileURLWithPath: path(relative)))
    }

    func read(_ relative: String) -> String? {
        FileManager.default.contents(atPath: path(relative)).map { String(decoding: $0, as: UTF8.self) }
    }

    func names(_ relative: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: path(relative))) ?? []).sorted()
    }
}

@Suite("Planning a drop")
struct CopyPlanTests {
    @Test("A name already in the folder is a clash, found before anything is copied")
    func clashes() throws {
        let disk = try Scratch()
        try disk.folder("from")
        try disk.folder("to")
        try disk.file("from/a.txt", "new")
        try disk.file("from/b.txt", "new")
        try disk.file("to/a.txt", "old")

        let plan = CopyPlan.make(
            sources: [disk.path("from/a.txt"), disk.path("from/b.txt")],
            into: disk.path("to"), source: LocalFileSource()
        )
        #expect(plan.items.count == 2)
        #expect(plan.clashes.map(\.name) == ["a.txt"])
        #expect(disk.read("to/a.txt") == "old")
    }

    @Test("Two dropped files with one name clash with each other")
    func clashWithinTheDrop() throws {
        let disk = try Scratch()
        try disk.folder("x")
        try disk.folder("y")
        try disk.folder("to")
        try disk.file("x/same.txt", "1")
        try disk.file("y/same.txt", "2")

        let plan = CopyPlan.make(
            sources: [disk.path("x/same.txt"), disk.path("y/same.txt")],
            into: disk.path("to"), source: LocalFileSource()
        )
        #expect(plan.items.map(\.clashes) == [false, true])
    }

    @Test("A file let go of in its own folder is nothing to do")
    func alreadyThere() throws {
        let disk = try Scratch()
        try disk.folder("here")
        try disk.file("here/a.txt", "a")
        let plan = CopyPlan.make(
            sources: [disk.path("here/a.txt")], into: disk.path("here"),
            source: LocalFileSource()
        )
        #expect(plan.items.isEmpty)
        #expect(plan.refused == [.alreadyThere(disk.path("here/a.txt"))])
    }

    @Test("A folder cannot be copied into itself or anything inside it")
    func intoItself() throws {
        let disk = try Scratch()
        try disk.folder("photos/2026")
        let source = LocalFileSource()
        let onItself = CopyPlan.make(
            sources: [disk.path("photos")], into: disk.path("photos"), source: source
        )
        let beneath = CopyPlan.make(
            sources: [disk.path("photos")], into: disk.path("photos/2026"), source: source
        )
        #expect(onItself.items.isEmpty)
        #expect(beneath.refused == [.intoItself(disk.path("photos"))])
    }

    @Test("A sibling whose name starts the same is not inside")
    func prefixIsNotContainment() throws {
        let disk = try Scratch()
        try disk.folder("photos")
        try disk.folder("photos-old")
        let plan = CopyPlan.make(
            sources: [disk.path("photos")], into: disk.path("photos-old"),
            source: LocalFileSource()
        )
        #expect(plan.items.map(\.name) == ["photos"])
    }
}

@Suite("Free names")
struct CopyNamingTests {
    @Test("The number goes before the extension, and counts past what is taken")
    func numbering() {
        let taken: Set<String> = ["/d/report (2).pdf"]
        #expect(
            CopyNaming.keepBoth("report.pdf", isDirectory: false, in: "/d") {
                taken.contains($0)
            } == "report (3).pdf"
        )
    }

    @Test("Folders and dotfiles have no extension to keep")
    func noExtension() {
        let free: (String) -> Bool = { _ in false }
        #expect(CopyNaming.keepBoth("v1.2", isDirectory: true, in: "/d", exists: free) == "v1.2 (2)")
        #expect(CopyNaming.keepBoth(".bashrc", isDirectory: false, in: "/d", exists: free) == ".bashrc (2)")
        #expect(CopyNaming.keepBoth("Makefile", isDirectory: false, in: "/d", exists: free) == "Makefile (2)")
    }
}

@Suite("Copying")
struct FileCopierTests {
    private func plan(_ disk: Scratch, _ names: [String], from: String = "from", to: String = "to") -> CopyPlan {
        CopyPlan.make(
            sources: names.map { disk.path("\(from)/\($0)") },
            into: disk.path(to), source: LocalFileSource()
        )
    }

    @Test("Replace overwrites a file, and the rest of the drop still lands")
    func replace() throws {
        let disk = try Scratch()
        try disk.folder("from")
        try disk.folder("to")
        try disk.file("from/a.txt", "new")
        try disk.file("from/b.txt", "b")
        try disk.file("to/a.txt", "old")

        let outcome = FileCopier.run(plan(disk, ["a.txt", "b.txt"]), clashes: .replace)
        #expect(outcome.copied == 2)
        #expect(outcome.failures.isEmpty)
        #expect(disk.read("to/a.txt") == "new")
        #expect(disk.read("to/b.txt") == "b")
        // The temporary copy the rename came from is gone, not left beside it.
        #expect(disk.names("to") == ["a.txt", "b.txt"])
    }

    @Test("Keep both copies beside the original under a free name")
    func keepBoth() throws {
        let disk = try Scratch()
        try disk.folder("from")
        try disk.folder("to")
        try disk.file("from/a.txt", "new")
        try disk.file("to/a.txt", "old")

        let outcome = FileCopier.run(plan(disk, ["a.txt"]), clashes: .keepBoth)
        #expect(outcome.copied == 1)
        #expect(disk.read("to/a.txt") == "old")
        #expect(disk.read("to/a (2).txt") == "new")
    }

    @Test("Skip leaves the clash alone and copies what does not clash")
    func skip() throws {
        let disk = try Scratch()
        try disk.folder("from")
        try disk.folder("to")
        try disk.file("from/a.txt", "new")
        try disk.file("from/b.txt", "b")
        try disk.file("to/a.txt", "old")

        let outcome = FileCopier.run(plan(disk, ["a.txt", "b.txt"]), clashes: .skip)
        #expect(outcome.copied == 1)
        #expect(outcome.skipped == 1)
        #expect(disk.read("to/a.txt") == "old")
        #expect(disk.read("to/b.txt") == "b")
    }

    @Test("Replacing a folder merges into it rather than deleting what it held")
    func folderMerge() throws {
        let disk = try Scratch()
        try disk.folder("from/pics")
        try disk.folder("to/pics")
        try disk.file("from/pics/new.png", "new")
        try disk.file("from/pics/both.png", "fresh")
        try disk.file("to/pics/kept.png", "kept")
        try disk.file("to/pics/both.png", "stale")

        let outcome = FileCopier.run(plan(disk, ["pics"]), clashes: .replace)
        #expect(outcome.failures.isEmpty)
        #expect(disk.names("to/pics") == ["both.png", "kept.png", "new.png"])
        #expect(disk.read("to/pics/both.png") == "fresh")
        #expect(disk.read("to/pics/kept.png") == "kept")
    }

    @Test("A file will not replace a folder of the same name")
    func kindMismatch() throws {
        let disk = try Scratch()
        try disk.folder("from")
        try disk.folder("to/thing")
        try disk.file("from/thing", "file")
        try disk.file("to/thing/inside", "safe")

        let outcome = FileCopier.run(plan(disk, ["thing"]), clashes: .replace)
        #expect(outcome.copied == 0)
        #expect(outcome.failures.count == 1)
        #expect(disk.read("to/thing/inside") == "safe")
    }

    @Test("A whole folder copies with its contents")
    func folderCopy() throws {
        let disk = try Scratch()
        try disk.folder("from/album/raw")
        try disk.folder("to")
        try disk.file("from/album/raw/1.cr2", "r")

        let outcome = FileCopier.run(plan(disk, ["album"]), clashes: .skip)
        #expect(outcome.copied == 1)
        #expect(disk.read("to/album/raw/1.cr2") == "r")
    }
}
