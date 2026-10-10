import Foundation
import LavaArchive
import Testing

@testable import LavaExplorerCore

private final class Scratch {
    let root: String

    init() throws {
        root = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("lava-extract-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(atPath: root) }

    func path(_ relative: String) -> String {
        (root as NSString).appendingPathComponent(relative)
    }

    func file(_ relative: String, _ text: String) throws {
        let full = path(relative)
        try FileManager.default.createDirectory(
            atPath: (full as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: URL(fileURLWithPath: full))
    }

    func read(_ relative: String) -> String? {
        FileManager.default.contents(atPath: path(relative)).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Hidden names included: a staging folder left behind is the bug.
    func names(_ relative: String = "") -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: path(relative))) ?? []).sorted()
    }

    /// An archive in `out/` of whatever is under `src/` by these names.
    func archive(_ name: String, of sources: [String]) throws -> String {
        let archive = path("out/" + name)
        try FileManager.default.createDirectory(atPath: path("out"), withIntermediateDirectories: true)
        _ = try Archive.create(
            archive, format: try #require(ArchiveFormat.forFileName(name)),
            from: sources.map { path("src/" + $0) }
        )
        return archive
    }
}

@Suite struct ExtractHereTests {
    @Test func oneFolderAtTheTopComesOutUnderItsOwnName() throws {
        let scratch = try Scratch()
        try scratch.file("src/project/a.txt", "a")
        let archive = try scratch.archive("whatever.zip", of: ["project"])

        let outcome = try ArchiveUnpacker.extractHere(archive, into: scratch.path("out"))
        #expect(outcome.result == scratch.path("out/project"))
        #expect(scratch.read("out/project/a.txt") == "a")
        #expect(scratch.names("out") == ["project", "whatever.zip"])
    }

    @Test func oneFileAtTheTopComesOutBesideTheArchive() throws {
        let scratch = try Scratch()
        try scratch.file("src/report.pdf", "pdf")
        let archive = try scratch.archive("report.tar.gz", of: ["report.pdf"])

        let outcome = try ArchiveUnpacker.extractHere(archive, into: scratch.path("out"))
        #expect(outcome.result == scratch.path("out/report.pdf"))
        #expect(scratch.names("out") == ["report.pdf", "report.tar.gz"])
    }

    @Test func severalThingsAtTheTopGoInAFolderNamedAfterTheArchive() throws {
        let scratch = try Scratch()
        try scratch.file("src/a.txt", "a")
        try scratch.file("src/b.txt", "b")
        let archive = try scratch.archive("Photos 2024.tar.xz", of: ["a.txt", "b.txt"])

        let outcome = try ArchiveUnpacker.extractHere(archive, into: scratch.path("out"))
        #expect(outcome.result == scratch.path("out/Photos 2024"))
        #expect(scratch.names("out/Photos 2024") == ["a.txt", "b.txt"])
        #expect(scratch.names("out") == ["Photos 2024", "Photos 2024.tar.xz"])
    }

    @Test func aTakenNameGetsANumberAndNothingIsOverwritten() throws {
        let scratch = try Scratch()
        try scratch.file("src/project/a.txt", "from archive")
        let archive = try scratch.archive("project.zip", of: ["project"])
        try scratch.file("out/project/a.txt", "mine")

        let first = try ArchiveUnpacker.extractHere(archive, into: scratch.path("out"))
        let second = try ArchiveUnpacker.extractHere(archive, into: scratch.path("out"))
        #expect(first.result == scratch.path("out/project (2)"))
        #expect(second.result == scratch.path("out/project (3)"))
        #expect(scratch.read("out/project/a.txt") == "mine")
        #expect(scratch.read("out/project (2)/a.txt") == "from archive")
    }

    @Test func anEmptyArchiveLeavesNothing() throws {
        let scratch = try Scratch()
        let archive = try scratch.archive("empty.tar", of: [])

        let outcome = try ArchiveUnpacker.extractHere(archive, into: scratch.path("out"))
        #expect(outcome.result == nil)
        #expect(scratch.names("out") == ["empty.tar"])
    }

    @Test func cancellingLeavesNothing() throws {
        let scratch = try Scratch()
        try scratch.file("src/a.txt", String(repeating: "a", count: 200_000))
        try scratch.file("src/b.txt", String(repeating: "b", count: 200_000))
        let archive = try scratch.archive("big.zip", of: ["a.txt", "b.txt"])

        var calls = 0
        let outcome = try ArchiveUnpacker.extractHere(archive, into: scratch.path("out")) { _ in
            calls += 1
            return calls < 3
        }
        #expect(outcome.result == nil)
        #expect(outcome.extraction.cancelled)
        #expect(scratch.names("out") == ["big.zip"])
    }

    @Test func somethingThatIsNotAnArchiveThrowsAndLeavesNothing() throws {
        let scratch = try Scratch()
        try scratch.file("out/fake.zip", "not a zip at all")
        #expect(throws: (any Error).self) {
            try ArchiveUnpacker.extractHere(scratch.path("out/fake.zip"), into: scratch.path("out"))
        }
        #expect(scratch.names("out") == ["fake.zip"])
    }

    @Test func anEncryptedZipIsAllOrNothingOnThePassword() throws {
        let scratch = try Scratch()
        try scratch.file("src/plain.txt", "visible")
        try scratch.file("src/secret.txt", "hidden")
        let archive = scratch.path("out/mixed.zip")
        try FileManager.default.createDirectory(atPath: scratch.path("out"), withIntermediateDirectories: true)
        _ = try Archive.create(
            archive, format: .zip,
            from: [scratch.path("src/plain.txt"), scratch.path("src/secret.txt")],
            password: "pw"
        )

        let asked = try ArchiveUnpacker.extractHere(archive, into: scratch.path("out"))
        #expect(asked.result == nil)
        #expect(asked.extraction.needsPassword)
        #expect(scratch.names("out") == ["mixed.zip"], "nothing half-done is left to find")

        let wrong = try ArchiveUnpacker.extractHere(archive, into: scratch.path("out"), password: "no")
        #expect(wrong.result == nil)
        #expect(wrong.extraction.wrongPassword)
        #expect(scratch.names("out") == ["mixed.zip"])

        let right = try ArchiveUnpacker.extractHere(archive, into: scratch.path("out"), password: "pw")
        #expect(right.result == scratch.path("out/mixed"))
        #expect(scratch.read("out/mixed/secret.txt") == "hidden")
    }

    @Test func extractHereIsOfferedByName() {
        #expect(ArchiveUnpacker.looksLikeArchive(FileEntry(path: "/a/x.tar.gz", isDirectory: false)))
        #expect(ArchiveUnpacker.looksLikeArchive(FileEntry(path: "/a/X.ZIP", isDirectory: false)))
        #expect(!ArchiveUnpacker.looksLikeArchive(FileEntry(path: "/a/x.txt", isDirectory: false)))
        #expect(!ArchiveUnpacker.looksLikeArchive(FileEntry(path: "/a/x.zip", isDirectory: true)))
    }

    @Test func undoingAnExtractionTrashesWhatItMade() throws {
        let scratch = try Scratch()
        try scratch.file("src/project/a.txt", "a")
        let archive = try scratch.archive("project.zip", of: ["project"])
        let outcome = try ArchiveUnpacker.extractHere(archive, into: scratch.path("out"))
        let made = try #require(outcome.result)

        try FileManager.default.createDirectory(
            atPath: scratch.path("data"), withIntermediateDirectories: true
        )
        let trash = TrashCan(
            dataHome: scratch.path("data"), deviceOf: { _ in 1 }, mountPoints: { [] }
        )
        let reversal = FileChange.extracted([made]).reversed(using: trash)
        #expect(reversal.failures.isEmpty)
        #expect(scratch.names("out") == ["project.zip"])
    }
}
