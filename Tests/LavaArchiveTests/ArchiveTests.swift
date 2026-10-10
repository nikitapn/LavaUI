import CArchive
import Foundation
import Testing

@testable import LavaArchive

/// A scratch folder per test, gone afterwards.
private final class Scratch {
    let root: String

    init() throws {
        root = NSTemporaryDirectory() + "lava-archive-" + UUID().uuidString.prefix(8)
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(atPath: root) }

    func path(_ relative: String) -> String { root + "/" + relative }

    func write(_ relative: String, _ text: String, mode: Int = 0o644) throws {
        let full = path(relative)
        try FileManager.default.createDirectory(
            atPath: (full as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: URL(fileURLWithPath: full))
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: full)
    }

    func read(_ relative: String) -> String? {
        FileManager.default.contents(atPath: path(relative)).map { String(decoding: $0, as: UTF8.self) }
    }

    func mkdir(_ relative: String) throws {
        try FileManager.default.createDirectory(atPath: path(relative), withIntermediateDirectories: true)
    }

    func exists(_ relative: String) -> Bool { Archive.lexists(path(relative)) }
}

/// An archive written entry by entry, saying whatever a test wants it to —
/// which is the point: the hostile cases are ones `create` would never make.
private struct RawEntry {
    enum Kind { case file, directory, symlink, hardlink }
    var name: String
    var kind: Kind = .file
    var text = ""
    var link: String?
}

private func writeRawTar(_ path: String, _ entries: [RawEntry]) throws {
    let writer = try #require(archive_write_new())
    defer { archive_write_free(writer) }
    archive_write_set_format_pax_restricted(writer)
    #expect(archive_write_open_filename(writer, path) == ARCHIVE_OK)
    for raw in entries {
        let entry = try #require(archive_entry_new())
        defer { archive_entry_free(entry) }
        archive_entry_set_pathname(entry, raw.name)
        archive_entry_set_perm(entry, 0o644)
        let bytes = Array(raw.text.utf8)
        switch raw.kind {
        case .file:
            archive_entry_set_filetype(entry, UInt32(LAVA_AE_IFREG))
            archive_entry_set_size(entry, Int64(bytes.count))
        case .directory:
            archive_entry_set_filetype(entry, UInt32(LAVA_AE_IFDIR))
            archive_entry_set_perm(entry, 0o755)
        case .symlink:
            archive_entry_set_filetype(entry, UInt32(LAVA_AE_IFLNK))
            archive_entry_set_symlink(entry, raw.link)
        case .hardlink:
            archive_entry_set_filetype(entry, UInt32(LAVA_AE_IFREG))
            archive_entry_set_hardlink(entry, raw.link)
        }
        #expect(archive_write_header(writer, entry) == ARCHIVE_OK)
        if raw.kind == .file, !bytes.isEmpty {
            _ = bytes.withUnsafeBytes { archive_write_data(writer, $0.baseAddress, $0.count) }
        }
    }
    #expect(archive_write_close(writer) == ARCHIVE_OK)
}

@Suite struct ArchiveRoundTripTests {
    /// A tree with the things that go wrong: nesting, an empty folder, a
    /// link, an executable bit and a name that is not ASCII.
    private func makeTree(in scratch: Scratch) throws {
        try scratch.write("src/project/readme.txt", "hello")
        try scratch.write("src/project/bin/run.sh", "#!/bin/sh\necho hi\n", mode: 0o755)
        try scratch.write("src/project/naïve – файл.txt", "unicode")
        try scratch.mkdir("src/project/empty")
        try FileManager.default.createSymbolicLink(
            atPath: scratch.path("src/project/latest"), withDestinationPath: "readme.txt"
        )
        try scratch.write("src/notes.txt", "loose file")
    }

    @Test(arguments: ArchiveFormat.allCases)
    func whatGoesInComesOut(format: ArchiveFormat) throws {
        let scratch = try Scratch()
        try makeTree(in: scratch)
        let archive = scratch.path("out." + format.fileExtension)

        let made = try Archive.create(
            archive, format: format,
            from: [scratch.path("src/project"), scratch.path("src/notes.txt")]
        )
        #expect(made.failures.isEmpty)
        #expect(!made.cancelled)
        #expect(Archive.isArchive(archive))

        let names = Set(try Archive.list(archive).map(\.path))
        #expect(names.isSuperset(of: [
            "project", "project/readme.txt", "project/bin/run.sh",
            "project/naïve – файл.txt", "project/empty", "project/latest", "notes.txt",
        ]))

        try scratch.mkdir("dest")
        let outcome = try Archive.extract(archive, into: scratch.path("dest"))
        #expect(outcome.failures.isEmpty)
        #expect(outcome.skipped.isEmpty)
        #expect(Set(outcome.created) == [scratch.path("dest/project"), scratch.path("dest/notes.txt")])
        #expect(scratch.read("dest/project/readme.txt") == "hello")
        #expect(scratch.read("dest/project/naïve – файл.txt") == "unicode")
        #expect(scratch.read("dest/notes.txt") == "loose file")
        #expect(Archive.isDirectory(scratch.path("dest/project/empty")))
        #expect(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: scratch.path("dest/project/latest")
            ) == "readme.txt"
        )
        let mode = try FileManager.default.attributesOfItem(
            atPath: scratch.path("dest/project/bin/run.sh")
        )[.posixPermissions] as? Int
        #expect((mode ?? 0) & 0o100 != 0, "the executable bit survives")
    }

    @Test func listingReportsKindsSizesAndLinks() throws {
        let scratch = try Scratch()
        try makeTree(in: scratch)
        let archive = scratch.path("out.tar")
        _ = try Archive.create(archive, format: .tar, from: [scratch.path("src/project")])
        let byPath = Dictionary(uniqueKeysWithValues: try Archive.list(archive).map { ($0.path, $0) })
        #expect(byPath["project"]?.kind == .directory)
        #expect(byPath["project/readme.txt"]?.kind == .file)
        #expect(byPath["project/readme.txt"]?.size == 5)
        #expect(byPath["project/latest"]?.kind == .symlink)
        #expect(byPath["project/latest"]?.linkTarget == "readme.txt")
        #expect(byPath["project/bin/run.sh"].map { $0.permissions & 0o111 != 0 } == true)
        #expect(byPath["project/readme.txt"]?.modified != nil)
    }
}

@Suite struct ArchiveExtractTests {
    @Test func aTakenNameIsSkippedUnlessToldToReplace() throws {
        let scratch = try Scratch()
        try writeRawTar(scratch.path("a.tar"), [
            RawEntry(name: "folder/", kind: .directory),
            RawEntry(name: "folder/new.txt", text: "from archive"),
            RawEntry(name: "folder/old.txt", text: "from archive"),
        ])
        try scratch.write("dest/folder/old.txt", "mine")

        let kept = try Archive.extract(scratch.path("a.tar"), into: scratch.path("dest"))
        #expect(kept.skipped == ["folder/old.txt"])
        #expect(kept.created.isEmpty, "the folder was there already: merged, not made")
        #expect(scratch.read("dest/folder/old.txt") == "mine")
        #expect(scratch.read("dest/folder/new.txt") == "from archive")

        let replaced = try Archive.extract(
            scratch.path("a.tar"), into: scratch.path("dest"), replace: true
        )
        #expect(replaced.skipped.isEmpty)
        #expect(scratch.read("dest/folder/old.txt") == "from archive")
    }

    @Test func nothingLandsOutsideTheFolder() throws {
        let scratch = try Scratch()
        try scratch.mkdir("dest")
        try scratch.mkdir("outside")
        try writeRawTar(scratch.path("evil.tar"), [
            RawEntry(name: "../escaped.txt", text: "x"),
            RawEntry(name: "a/../../escaped2.txt", text: "x"),
            RawEntry(name: "/absolute.txt", text: "made relative"),
            // A link out, then a write through it.
            RawEntry(name: "door", kind: .symlink, link: scratch.path("outside")),
            RawEntry(name: "door/pwned.txt", text: "x"),
            // A hard link to something outside.
            RawEntry(name: "hard", kind: .hardlink, link: "../outside/target"),
            RawEntry(name: "fine.txt", text: "ok"),
        ])

        let outcome = try Archive.extract(scratch.path("evil.tar"), into: scratch.path("dest"))
        #expect(!scratch.exists("escaped.txt"))
        #expect(!scratch.exists("escaped2.txt"))
        #expect(!scratch.exists("outside/pwned.txt"))
        #expect(scratch.read("dest/absolute.txt") == "made relative")
        #expect(scratch.read("dest/fine.txt") == "ok")
        let failed = Set(outcome.failures.map(\.path))
        #expect(failed.isSuperset(of: ["../escaped.txt", "a/../../escaped2.txt", "door/pwned.txt", "hard"]))
    }

    @Test func cancellingStopsAndLeavesNoHalfFile() throws {
        let scratch = try Scratch()
        let big = String(repeating: "0123456789abcdef", count: 64 * 1024) // 1 MiB
        try writeRawTar(scratch.path("a.tar"), [
            RawEntry(name: "first.txt", text: "small"),
            RawEntry(name: "big.bin", text: big),
            RawEntry(name: "after.txt", text: "never"),
        ])
        try scratch.mkdir("dest")
        var calls = 0
        let outcome = try Archive.extract(scratch.path("a.tar"), into: scratch.path("dest")) { progress in
            calls += 1
            return progress.entry != "big.bin" || calls < 4
        }
        #expect(outcome.cancelled)
        #expect(scratch.read("dest/first.txt") == "small")
        #expect(!scratch.exists("dest/big.bin"))
        #expect(!scratch.exists("dest/after.txt"))
    }

    @Test func progressRunsToTheArchivesSize() throws {
        let scratch = try Scratch()
        try writeRawTar(scratch.path("a.tar"), [
            RawEntry(name: "x.txt", text: String(repeating: "x", count: 200_000)),
        ])
        try scratch.mkdir("dest")
        var last: ArchiveProgress?
        _ = try Archive.extract(scratch.path("a.tar"), into: scratch.path("dest")) {
            last = $0
            return true
        }
        let size = try FileManager.default.attributesOfItem(atPath: scratch.path("a.tar"))[.size] as? Int64
        #expect(last?.bytesTotal == size)
        #expect((last?.fraction ?? 0) > 0.5)
    }

    @Test func aFileThatIsNotAnArchiveThrows() throws {
        let scratch = try Scratch()
        try scratch.write("plain.txt", "just text, nothing packed")
        try scratch.mkdir("dest")
        #expect(!Archive.isArchive(scratch.path("plain.txt")))
        #expect(!Archive.isArchive(scratch.path("missing.zip")))
        #expect(throws: ArchiveError.self) {
            try Archive.extract(scratch.path("plain.txt"), into: scratch.path("dest"))
        }
        #expect(throws: ArchiveError.self) { try Archive.list(scratch.path("missing.zip")) }
    }
}

@Suite struct ArchiveCreateTests {
    @Test func anExistingDestinationIsRefused() throws {
        let scratch = try Scratch()
        try scratch.write("a.txt", "a")
        try scratch.write("out.zip", "already here")
        #expect(throws: ArchiveError.self) {
            try Archive.create(scratch.path("out.zip"), format: .zip, from: [scratch.path("a.txt")])
        }
        #expect(scratch.read("out.zip") == "already here")
    }

    @Test func cancellingLeavesNoArchiveAndNoTemporary() throws {
        let scratch = try Scratch()
        try scratch.write("src/a.txt", String(repeating: "a", count: 300_000))
        let outcome = try Archive.create(
            scratch.path("out.tar.gz"), format: .tarGzip, from: [scratch.path("src")]
        ) { _ in false }
        #expect(outcome.cancelled)
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.root) == ["src"])
    }

    @Test func anArchiveMadeInsideTheFolderItPacksLeavesItselfOut() throws {
        let scratch = try Scratch()
        try scratch.write("src/a.txt", "a")
        let archive = scratch.path("src/self.zip")
        _ = try Archive.create(archive, format: .zip, from: [scratch.path("src")])
        let names = try Archive.list(archive).map(\.path)
        #expect(names.contains("src/a.txt"))
        #expect(!names.contains { $0.contains("lava-archive") || $0.hasSuffix("self.zip") })
    }

    @Test func progressCountsTheSourcesBytes() throws {
        let scratch = try Scratch()
        try scratch.write("src/a.txt", String(repeating: "a", count: 100_000))
        try scratch.write("src/b.txt", String(repeating: "b", count: 50_000))
        var last: ArchiveProgress?
        _ = try Archive.create(scratch.path("out.zip"), format: .zip, from: [scratch.path("src")]) {
            last = $0
            return true
        }
        #expect(last?.bytesTotal == 150_000)
        #expect(last?.bytesDone == 150_000)
    }
}

@Suite struct ArchiveNamingTests {
    @Test func safeRelativeKeepsInsideNamesAndRefusesTheRest() {
        #expect(ArchivePaths.safeRelative("a/b.txt") == "a/b.txt")
        #expect(ArchivePaths.safeRelative("./a//b/./c") == "a/b/c")
        #expect(ArchivePaths.safeRelative("/etc/passwd") == "etc/passwd")
        #expect(ArchivePaths.safeRelative("../x") == nil)
        #expect(ArchivePaths.safeRelative("a/../b") == nil)
        #expect(ArchivePaths.safeRelative("./") == nil)
        #expect(ArchivePaths.safeRelative("a..b/c..") == "a..b/c..", "dots in a name are a name")
    }

    @Test func formatsAndStemsByName() {
        #expect(ArchiveFormat.forFileName("Photos.TAR.GZ") == .tarGzip)
        #expect(ArchiveFormat.forFileName("x.tgz") == .tarGzip)
        #expect(ArchiveFormat.forFileName("x.tar.zst") == .tarZstd)
        #expect(ArchiveFormat.forFileName("x.zip") == .zip)
        #expect(ArchiveFormat.forFileName("x.rar") == nil, "read, never written")
        #expect(ArchiveFormat.stem(of: "Photos 2024.tar.gz") == "Photos 2024")
        #expect(ArchiveFormat.stem(of: "setup.rar") == "setup")
        #expect(ArchiveFormat.stem(of: "notes.txt") == nil)
        #expect(ArchiveFormat.stem(of: ".zip") == nil)
    }
}
