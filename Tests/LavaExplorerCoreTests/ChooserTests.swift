import Foundation
import Testing

@testable import LavaExplorerCore

@Suite struct ChooserTests {
    @Test func theCommandLineFileDialogWritesIsReadBack() throws {
        let request = try #require(ChooserRequest.parse([
            "--choose=save", "--title=Export Image", "--output=/tmp/answer",
            "--filter=PNG image|png", "--filter=JPEG|jpg, .JPEG ,*.jpe",
            "--filter=All files|", "--filename=shot.png", "/home/me",
        ]))
        #expect(request.mode == .save)
        #expect(request.title == "Export Image")
        #expect(request.output == "/tmp/answer")
        #expect(request.suggestedName == "shot.png")
        #expect(request.filters.map(\.name) == ["PNG image", "JPEG", "All files"])
        #expect(request.filters[1].extensions == ["jpg", "jpeg", "jpe"])
        #expect(request.filters[2].extensions.isEmpty)
        #expect(ChooserRequest.parse(["/home/me"]) == nil, "no --choose is the explorer itself")
    }

    @Test func aFilterShowsFoldersAndMatchingFilesInAnyCase() {
        let images = ChooserRequest.Filter(name: "Images", extensions: ["png", "jpg"])
        #expect(images.shows(FileEntry(path: "/a/Holiday.JPG", isDirectory: false)))
        #expect(!images.shows(FileEntry(path: "/a/notes.txt", isDirectory: false)))
        #expect(images.shows(FileEntry(path: "/a/raw.txt", isDirectory: true)))
        #expect(ChooserRequest.Filter(name: "All", extensions: [])
            .shows(FileEntry(path: "/a/anything", isDirectory: false)))
    }

    @Test func openAnswersWithFilesNeverFolders() {
        let single = ChooserRequest(mode: .open)
        let many = ChooserRequest(mode: .openMultiple)
        let rows = [
            FileEntry(path: "/d/sub", isDirectory: true),
            FileEntry(path: "/d/a.txt", isDirectory: false),
            FileEntry(path: "/d/b.txt", isDirectory: false),
        ]
        #expect(single.openAnswer(selected: rows) == ["/d/a.txt"])
        #expect(many.openAnswer(selected: rows) == ["/d/a.txt", "/d/b.txt"])
        #expect(single.openAnswer(selected: [rows[0]]) == nil)
    }

    @Test func aSaveNameIsCheckedLikeAnyOther() throws {
        let save = ChooserRequest(mode: .save)
        #expect(try save.saveTarget(name: " out.png ", in: "/d") == "/d/out.png")
        #expect(throws: FileAccessError.self) { try save.saveTarget(name: "a/b.png", in: "/d") }
        #expect(throws: FileAccessError.self) { try save.saveTarget(name: "x", in: "trash:///") }
    }

    @Test func theAnswerGoesToTheFileTheCallerNamed() throws {
        let output = NSTemporaryDirectory() + "lava-answer-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: output) }
        try ChooserRequest(mode: .openMultiple, output: output).deliver(["/a b/c.txt", "/d.txt"])
        #expect(try String(contentsOfFile: output, encoding: .utf8) == "/a b/c.txt\n/d.txt\n")
    }

    @Test func aFilteredListingKeepsFoldersAndDropsOtherFiles() throws {
        let root = NSTemporaryDirectory() + "lava-filter-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: root + "/sub", withIntermediateDirectories: true)
        for name in ["a.png", "b.txt", "C.PNG"] {
            FileManager.default.createFile(atPath: root + "/" + name, contents: Data())
        }
        let filter = FilteredSource.Filter(ChooserRequest.Filter(name: "PNG", extensions: ["png"]))
        let source = FilteredSource(base: LocalFileSource(), filter: filter)
        #expect(FolderListing.load(path: root, source: source).entries.map(\.name) == ["sub", "a.png", "C.PNG"])
        filter.current = nil
        #expect(FolderListing.load(path: root, source: source).entries.count == 4)
    }
}
