import Foundation
import Testing

@testable import LavaExplorerCore

// Against a real disk, like the copy tests: a trash is renames and exclusive
// creates, and what matters is what those do. Each test gets a home of its
// own with a `.local/share` in it and, where a second drive is wanted, a
// folder that a fake `deviceOf` says is one.

private final class Desk {
    let root: String

    init() throws {
        root = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("lava-trash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            atPath: root + "/home/.local/share", withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            atPath: root + "/drive", withIntermediateDirectories: true
        )
    }

    deinit { try? FileManager.default.removeItem(atPath: root) }

    var home: String { root + "/home" }
    var drive: String { root + "/drive" }

    /// Everything under `drive` is a filesystem of its own.
    func can(mounted: [String] = []) -> TrashCan {
        let drive = self.drive
        return TrashCan(
            dataHome: home + "/.local/share",
            uid: getuid(),
            deviceOf: { path in
                guard TrashCan.lexists(path) else { return nil }
                return path == drive || path.hasPrefix(drive + "/") ? 2 : 1
            },
            mountPoints: { mounted }
        )
    }

    @discardableResult
    func file(_ path: String, _ text: String = "x") throws -> String {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
        return path
    }

    func exists(_ path: String) -> Bool { TrashCan.lexists(path) }

    func read(_ path: String) -> String? {
        FileManager.default.contents(atPath: path).map { String(decoding: $0, as: UTF8.self) }
    }
}

@Suite struct TrashTests {
    @Test func aTrashedFileIsRenamedAndSaysWhereItCameFrom() throws {
        let desk = try Desk()
        let can = desk.can()
        let path = try desk.file(desk.home + "/Documents/report final.pdf", "draft")
        let when = Date(timeIntervalSince1970: 1_790_000_000)

        let item = try can.trash(path, now: when)

        #expect(!desk.exists(path))
        #expect(item.trashedPath == desk.home + "/.local/share/Trash/files/report final.pdf")
        #expect(desk.read(item.trashedPath) == "draft")
        let info = try #require(desk.read(item.infoPath))
        #expect(info.hasPrefix("[Trash Info]\n"))
        #expect(info.contains("Path=\(desk.home)/Documents/report%20final.pdf\n"))
        let stamp = TrashInfo.dateFormatter().string(from: when)
        #expect(info.contains("DeletionDate=\(stamp)\n"))

        let listed = can.items()
        #expect(listed.count == 1)
        #expect(listed.first?.originalPath == path)
        #expect(listed.first?.name == "report final.pdf")
        #expect(listed.first?.deletionDate == when)
    }

    @Test func twoFilesOfOneNameEachKeepTheirOwn() throws {
        let desk = try Desk()
        let can = desk.can()
        let first = try can.trash(try desk.file(desk.home + "/a/notes.txt", "one"))
        let second = try can.trash(try desk.file(desk.home + "/b/notes.txt", "two"))

        #expect(first.trashedPath != second.trashedPath)
        #expect((second.trashedPath as NSString).lastPathComponent == "notes.2.txt")
        let names = can.items().map(\.name)
        #expect(names == ["notes.txt", "notes.txt"])
        let origins = Set(can.items().map(\.originalPath))
        #expect(origins == [desk.home + "/a/notes.txt", desk.home + "/b/notes.txt"])
    }

    @Test func aFolderGoesWholeAndComesBackWhole() throws {
        let desk = try Desk()
        let can = desk.can()
        try desk.file(desk.home + "/Photos/2026/one.jpg", "1")
        try desk.file(desk.home + "/Photos/two.jpg", "2")

        let item = try can.trash(desk.home + "/Photos")
        #expect(item.isDirectory)
        #expect(!desk.exists(desk.home + "/Photos"))

        let back = try can.restore(item)
        #expect(back == desk.home + "/Photos")
        #expect(desk.read(desk.home + "/Photos/2026/one.jpg") == "1")
        #expect(!desk.exists(item.infoPath))
        #expect(can.items().isEmpty)
    }

    @Test func restoringRecreatesAFolderThatWentToo() throws {
        let desk = try Desk()
        let can = desk.can()
        let item = try can.trash(try desk.file(desk.home + "/gone/deeper/keep.txt", "k"))
        try FileManager.default.removeItem(atPath: desk.home + "/gone")

        try can.restore(item)
        #expect(desk.read(desk.home + "/gone/deeper/keep.txt") == "k")
    }

    @Test func restoringNeverOverwrites() throws {
        let desk = try Desk()
        let can = desk.can()
        let path = try desk.file(desk.home + "/todo.txt", "old")
        let item = try can.trash(path)
        try desk.file(path, "new")

        #expect(throws: FileAccessError.self) { try can.restore(item) }
        #expect(desk.read(path) == "new")
        #expect(desk.read(item.trashedPath) == "old", "still in the Trash to try again")
    }

    @Test func erasingAndEmptyingLeaveNothing() throws {
        let desk = try Desk()
        let can = desk.can()
        let one = try can.trash(try desk.file(desk.home + "/one.txt"))
        try can.trash(try desk.file(desk.home + "/two.txt"))
        // A leftover of an interrupted trash from somebody: a file, no info.
        try desk.file(can.home.files + "/orphan.bin")

        try can.erase(one)
        #expect(!desk.exists(one.trashedPath))
        #expect(!desk.exists(one.infoPath))
        #expect(can.items().map(\.name) == ["two.txt"])

        #expect(can.empty().isEmpty)
        let files = try FileManager.default.contentsOfDirectory(atPath: can.home.files)
        let infos = try FileManager.default.contentsOfDirectory(atPath: can.home.info)
        #expect(files.isEmpty)
        #expect(infos.isEmpty)
    }

    @Test func aFileOnAnotherDriveGoesToThatDrivesTrash() throws {
        let desk = try Desk()
        let can = desk.can(mounted: [desk.drive])
        let path = try desk.file(desk.drive + "/music/song one.flac")

        let item = try can.trash(path)

        let own = desk.drive + "/.Trash-\(getuid())"
        #expect(item.trashedPath == own + "/files/song one.flac")
        // Relative, so the drive still makes sense mounted elsewhere.
        #expect(desk.read(item.infoPath)?.contains("Path=music/song%20one.flac\n") == true)
        #expect(!desk.exists(can.home.files + "/song one.flac"))

        let listed = can.items()
        #expect(listed.map(\.originalPath) == [path])
        try can.restore(try #require(listed.first))
        #expect(desk.exists(path))
    }

    @Test func anAdministratorsSharedTrashIsUsedWhenItIsSticky() throws {
        let desk = try Desk()
        let can = desk.can(mounted: [desk.drive])
        let shared = desk.drive + "/.Trash"
        try FileManager.default.createDirectory(atPath: shared, withIntermediateDirectories: true)
        chmod(shared, 0o1777)

        let item = try can.trash(try desk.file(desk.drive + "/clip.mov"))
        #expect(item.trashedPath == shared + "/\(getuid())/files/clip.mov")
        #expect(can.items().count == 1)
    }

    @Test func aSharedTrashThatIsNotStickyIsPassedOver() throws {
        let desk = try Desk()
        let can = desk.can(mounted: [desk.drive])
        try FileManager.default.createDirectory(
            atPath: desk.drive + "/.Trash", withIntermediateDirectories: true
        )

        let item = try can.trash(try desk.file(desk.drive + "/clip.mov"))
        #expect(item.trashedPath == desk.drive + "/.Trash-\(getuid())/files/clip.mov")
    }

    @Test func theTrashCannotBeTrashed() throws {
        let desk = try Desk()
        let can = desk.can()
        let item = try can.trash(try desk.file(desk.home + "/x.txt"))
        #expect(throws: FileAccessError.self) { try can.trash(item.trashedPath) }
        #expect(throws: FileAccessError.self) { try can.trash(desk.home + "/.local") }
        #expect(throws: FileAccessError.self) { try can.trash(desk.home + "/nothing-here") }
    }

    @Test func infoFilesFromOtherImplementationsParse() {
        let text = """
            [Desktop Entry]
            Path=/not/this/one
            [Trash Info]
            Path=/home/me/caf%C3%A9%20menu.txt
            DeletionDate=2026-01-02T03:04:05
            X-Other=1
            """
        let info = TrashInfo.parse(text)
        #expect(info?.path == "/home/me/café menu.txt")
        #expect(info?.deletionDate != nil)
        #expect(TrashInfo.parse("[Trash Info]\nDeletionDate=2026-01-02T03:04:05") == nil)
        let round = TrashInfo(path: "/a b/ü#?.txt", deletionDate: nil)
        #expect(TrashInfo.parse(round.serialized())?.path == "/a b/ü#?.txt")
    }

    @Test func theTrashIsAPlaceWithNothingAboveIt() throws {
        #expect(FolderHistory.normalize("trash:///") == TrashPath.uri)
        #expect(FolderHistory.normalize(" trash: ") == TrashPath.uri)
        var history = FolderHistory(path: TrashPath.uri)
        #expect(!history.canGoUp)
        history.goUp()
        #expect(history.path == TrashPath.uri)
        #expect(Places.standard(home: "/nowhere", userDirs: "", exists: { _ in false }).last?.path
            == TrashPath.uri)
    }

    @Test func theTrashListsAsAFolderOfWhatWasThrownAway() throws {
        let desk = try Desk()
        let can = desk.can()
        try can.trash(try desk.file(desk.home + "/letter.odt", "abc"))
        let source = TrashListingSource(base: LocalFileSource(), trash: can)

        let listing = FolderListing.load(path: "trash:///", source: source)
        #expect(listing.error == nil)
        #expect(listing.entries.map(\.name) == ["letter.odt"])
        #expect(listing.entries.first?.path == can.home.files + "/letter.odt")
        #expect(listing.entries.first?.size == 3)

        var tab = ExplorerTab.open(id: 1, path: "trash:///", source: source)
        #expect(tab.title == "Trash")
        tab.reload(from: source)
        #expect(tab.listing.entries.count == 1)
    }
}

@Suite struct UndoTests {
    @Test func undoingATrashPutsItBackAndRedoThrowsItAwayAgain() throws {
        let desk = try Desk()
        let can = desk.can()
        let path = try desk.file(desk.home + "/plan.txt", "p")
        var history = FileUndoHistory()
        history.record(.trashed([try can.trash(path)]))

        let undoneResult = history.undo(using: can)
        let undone = try #require(undoneResult)
        #expect(undone.1.failures.isEmpty)
        #expect(desk.read(path) == "p")
        #expect(history.canRedo)

        let redoneResult = history.redo(using: can)
        let redone = try #require(redoneResult)
        #expect(redone.1.failures.isEmpty)
        #expect(!desk.exists(path))
        #expect(can.items().map(\.originalPath) == [path])
        #expect(history.canUndo, "and that can be undone in turn")
    }

    @Test func undoingACopyMovesTheCopiesToTheTrashNotAway() throws {
        let desk = try Desk()
        let can = desk.can()
        try desk.file(desk.home + "/from/a.txt", "a")
        try desk.file(desk.home + "/from/b.txt", "b")
        try FileManager.default.createDirectory(
            atPath: desk.home + "/to", withIntermediateDirectories: true
        )
        try desk.file(desk.home + "/to/b.txt", "old b")
        let plan = CopyPlan.make(
            sources: [desk.home + "/from/a.txt", desk.home + "/from/b.txt"],
            into: desk.home + "/to", source: LocalFileSource()
        )
        let outcome = FileCopier.run(plan, clashes: .keepBoth)
        #expect(outcome.created == [desk.home + "/to/a.txt", desk.home + "/to/b (2).txt"])

        var history = FileUndoHistory()
        history.record(.copied(outcome.created))
        let undoneResult = history.undo(using: can)
        let undone = try #require(undoneResult)
        #expect(undone.1.inverse?.count == 2)
        #expect(!desk.exists(desk.home + "/to/a.txt"))
        #expect(!desk.exists(desk.home + "/to/b (2).txt"))
        #expect(desk.read(desk.home + "/to/b.txt") == "old b", "what was there before stays")
        #expect(can.items().count == 2, "the copies are in the Trash, not gone")
    }

    @Test func aReplacedFileIsNotSomethingUndoCanTakeAway() throws {
        let desk = try Desk()
        try desk.file(desk.home + "/from/b.txt", "new")
        try desk.file(desk.home + "/to/b.txt", "old")
        let plan = CopyPlan.make(
            sources: [desk.home + "/from/b.txt"], into: desk.home + "/to",
            source: LocalFileSource()
        )
        let outcome = FileCopier.run(plan, clashes: .replace)
        #expect(outcome.copied == 1)
        #expect(outcome.created.isEmpty)
    }

    @Test func somethingNewClearsRedo() throws {
        let desk = try Desk()
        let can = desk.can()
        var history = FileUndoHistory()
        history.record(.trashed([try can.trash(try desk.file(desk.home + "/1.txt"))]))
        _ = history.undo(using: can)
        #expect(history.canRedo)
        history.record(.trashed([try can.trash(try desk.file(desk.home + "/2.txt"))]))
        #expect(!history.canRedo)
    }

    @Test func anUndoThatCannotHappenSaysWhyAndLeavesNothingToRedo() throws {
        let desk = try Desk()
        let can = desk.can()
        let path = try desk.file(desk.home + "/gone.txt")
        let item = try can.trash(path)
        _ = can.empty()
        var history = FileUndoHistory()
        history.record(.trashed([item]))

        let undoneResult = history.undo(using: can)
        let undone = try #require(undoneResult)
        #expect(undone.1.failures.count == 1)
        #expect(undone.1.inverse == nil)
        #expect(!history.canRedo)
        #expect(!history.canUndo)
    }
}

@Suite struct NewFolderTests {
    @Test func theOfferedNameIsOneThatIsFree() throws {
        let desk = try Desk()
        let dir = desk.home + "/work"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let exists: (String) -> Bool = { TrashCan.lexists($0) }
        #expect(NewFolder.freeName(in: dir, exists: exists) == "New Folder")
        _ = try NewFolder.make(named: "New Folder", in: dir)
        #expect(NewFolder.freeName(in: dir, exists: exists) == "New Folder (2)")
    }

    @Test func aFolderIsMadeAndNothingIsEverMergedInto() throws {
        let desk = try Desk()
        let dir = desk.home
        let path = try NewFolder.make(named: "  Photos 2026 ", in: dir)
        #expect(path == dir + "/Photos 2026", "spaces at the ends are trimmed")
        #expect(TrashCan.isDirectory(path))
        #expect(throws: FileAccessError.self) { try NewFolder.make(named: "Photos 2026", in: dir) }
        try desk.file(dir + "/notes")
        #expect(throws: FileAccessError.self) { try NewFolder.make(named: "notes", in: dir) }
    }

    @Test func namesTheFilesystemRefusesAreRefusedFirst() {
        #expect(NewFolder.problem(with: "") != nil)
        #expect(NewFolder.problem(with: ".") != nil)
        #expect(NewFolder.problem(with: "..") != nil)
        #expect(NewFolder.problem(with: "a/b") != nil)
        #expect(NewFolder.problem(with: String(repeating: "é", count: 128)) != nil)
        #expect(NewFolder.problem(with: ".hidden") == nil)
        #expect(NewFolder.problem(with: "Отчёты 2026") == nil)
    }

    @Test func undoingANewFolderMovesItToTheTrash() throws {
        let desk = try Desk()
        let can = desk.can()
        let path = try NewFolder.make(named: "Scratch", in: desk.home)
        var history = FileUndoHistory()
        history.record(.created([path]))
        let undone = history.undo(using: can)
        #expect(undone?.1.failures.isEmpty == true)
        #expect(!desk.exists(path))
        #expect(can.items().map(\.originalPath) == [path])
    }
}
