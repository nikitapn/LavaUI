import Testing

@testable import LavaExplorerCore

@Suite struct FileIconTests {
    let home = "/home/u"

    @Test func homeAndItsXdgFoldersAreSpecial() {
        #expect(FileIcon.folderNames("/home/u", home: home) == ["user-home", "folder"])
        #expect(FileIcon.folderNames("/home/u/", home: home) == ["user-home", "folder"])
        #expect(FileIcon.folderNames("/home/u/Downloads", home: home)
            == ["folder-download", "folder"])
        #expect(FileIcon.folderNames("/home/u/Desktop", home: home)
            == ["user-desktop", "folder"])
    }

    @Test func aSpecialNameDeeperDownIsAnOrdinaryFolder() {
        #expect(FileIcon.folderNames("/home/u/projects/Music", home: home) == ["folder"])
        #expect(FileIcon.folderNames("/srv/Documents", home: home) == ["folder"])
    }

    @Test func trashIsTheTrash() {
        #expect(FileIcon.folderNames(TrashPath.uri, home: home).first == "user-trash")
    }

    @Test func filesGoByExtensionCaseBlindAndEndGeneric() {
        #expect(FileIcon.fileNames("a.PNG") == ["image-x-generic", "text-x-generic"])
        #expect(FileIcon.fileNames("b.pdf")
            == ["application-pdf", "x-office-document", "text-x-generic"])
        #expect(FileIcon.fileNames("Makefile") == ["text-x-generic"])
        #expect(FileIcon.fileNames("x.unknownext") == ["text-x-generic"])
    }

    @Test func entriesPickTheirContext() {
        let dir = FileEntry(path: "/home/u/Music", isDirectory: true)
        #expect(FileIcon.candidates(for: dir, home: home)
            == [.init(.places, "folder-music"), .init(.places, "folder")])
        let file = FileEntry(path: "/home/u/song.flac", isDirectory: false)
        #expect(FileIcon.candidates(for: file, home: home).allSatisfy { $0.context == .mimetypes })
    }

    @Test func theRootIsADiskThatFallsBackToAFolder() {
        let root = FileIcon.folder("/", home: home)
        #expect(root.first == .init(.devices, "drive-harddisk"))
        #expect(root.last == .init(.places, "folder"))
    }
}
