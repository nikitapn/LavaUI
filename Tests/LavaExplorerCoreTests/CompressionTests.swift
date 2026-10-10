import Foundation
import LavaArchive
import Testing

@testable import LavaExplorerCore

@Suite struct CompressTests {
    @Test func oneThingIsNamedAfterItselfSeveralAfterTheirFolder() throws {
        let folder = NSTemporaryDirectory() + "lava-pack-" + UUID().uuidString.prefix(8)
        try FileManager.default.createDirectory(
            atPath: folder + "/Photos", withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(atPath: folder) }

        #expect(ArchivePacker.suggestedName(for: [folder + "/report.pdf"]) == "report")
        #expect(ArchivePacker.suggestedName(for: [folder + "/backup.tar.gz"]) == "backup")
        #expect(ArchivePacker.suggestedName(for: [folder + "/Photos"]) == "Photos",
                "a folder's dots are part of its name, but it has none here either way")
        #expect(ArchivePacker.suggestedName(for: ["/home/me/a.txt", "/home/me/b.txt"]) == "me")
        #expect(ArchivePacker.suggestedName(for: ["/a", "/b"]) == "Archive")
    }

    @Test func aTakenNameIsNumberedBeforeTheWholeExtension() {
        let taken: Set = ["/d/photos.tar.gz", "/d/photos (2).tar.gz", "/d/x.zip"]
        let exists = { (path: String) in taken.contains(path) }
        #expect(ArchivePacker.destination(named: "photos", format: .tarGzip, in: "/d", exists: exists)
                == "/d/photos (3).tar.gz")
        #expect(ArchivePacker.destination(named: "new", format: .zip, in: "/d", exists: exists)
                == "/d/new.zip")
        #expect(ArchivePacker.destination(named: "x.ZIP", format: .zip, in: "/d", exists: exists)
                == "/d/x (2).zip", "an extension typed in is not doubled")
        #expect(ArchivePacker.destination(named: "  ", format: .sevenZip, in: "/d", exists: exists)
                == "/d/Archive.7z")
    }

    @Test func aNameIsOneFileName() {
        #expect(ArchivePacker.isUsableName("photos"))
        #expect(!ArchivePacker.isUsableName(" "))
        #expect(!ArchivePacker.isUsableName("a/b"))
        #expect(!ArchivePacker.isUsableName(".."))
    }
}
