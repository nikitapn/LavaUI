import Foundation
import Glibc
import XCTest
@testable import LavaProjectCore

final class FindFileTests: XCTestCase {
    func testEditablePathsAndRestarts() {
        let home = "/home/editor"
        let base = URL(fileURLWithPath: home + "/src", isDirectory: true)
        XCTAssertEqual(FindFilePath.directoryText(base, home: home), "~/src/")
        XCTAssertEqual(FindFilePath.abbreviated("/home/editor2/src", home: home), "/home/editor2/src")
        let path = FindFilePath("~/src/Lib")
        XCTAssertEqual(path.prefix, "~/src/")
        XCTAssertEqual(path.query, "Lib")
        XCTAssertEqual(path.completing("Library", directory: true), "~/src/Library/")
        XCTAssertEqual(path.completing("Library.swift", directory: false), "~/src/Library.swift")
        XCTAssertEqual(FindFilePath("~/src/Library/").parentText(home: home), "~/src/")
        XCTAssertEqual(FindFilePath("~/").parentText(home: home), "/home/")
        XCTAssertNil(FindFilePath("/").parentText(home: home))
        XCTAssertNil(path.parentText(home: home))

        XCTAssertEqual(FindFilePath.restarting("~/src//etc/"), "/etc/")
        XCTAssertEqual(FindFilePath.restarting("/etc/~/Downloads/"), "~/Downloads/")
        XCTAssertEqual(FindFilePath.restarting("/tmp/~/Downloads//var/"), "/var/")
        XCTAssertEqual(FindFilePath.restarting("/etc/"), "/etc/")
        XCTAssertEqual(FindFilePath.restarting("~/src/.git/"), "~/src/.git/")
        XCTAssertEqual(FindFilePath.restarting("/tmp/archive~/file", after: "/tmp/archive~/"), "/tmp/archive~/file")
        XCTAssertEqual(path.directory(relativeTo: base, home: home).path, base.path)
        XCTAssertEqual(FindFilePath("/etc/passwd").destination(relativeTo: base, home: home).path, "/etc/passwd")
        XCTAssertEqual(FindFilePath("one/two").destination(relativeTo: base, home: home).path, base.path + "/one/two")
    }

    func testDirectoryEntriesIncludeHiddenAndSortDirectoriesFirst() throws {
        let files = FileManager.default
        let directory = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try files.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: directory) }

        for path in ["Zulu", ".git"] {
            try files.createDirectory(at: directory.appendingPathComponent(path), withIntermediateDirectories: false)
        }
        for path in ["alpha.txt", ".hidden"] {
            try Data().write(to: directory.appendingPathComponent(path))
        }
        try files.createSymbolicLink(at: directory.appendingPathComponent("link"), withDestinationURL:
            directory.appendingPathComponent("Zulu"))

        let entries = try FindFileEntry.list(in: directory)
        XCTAssertEqual(entries.map(\.name), [".git", "link", "Zulu", ".hidden", "alpha.txt"])
        XCTAssertEqual(entries.map(\.isDirectory), [true, true, true, false, false])
        XCTAssertTrue(FindFileDetails.read(directory.appendingPathComponent("link"))?.permissions.hasPrefix("l") == true)
    }

    func testDetailsFormatting() {
        XCTAssertEqual(FindFileDetails.permissionText(S_IFDIR | 0o755), "drwxr-xr-x")
        XCTAssertEqual(FindFileDetails.permissionText(S_IFREG | 0o4644), "-rwSr--r--")
        XCTAssertEqual(FindFileDetails.permissionText(S_IFDIR | 0o1777), "drwxrwxrwt")
        XCTAssertEqual(FindFileDetails.sizeText(4_096), "4k")
        XCTAssertEqual(FindFileDetails.sizeText(12_288), "12k")
        XCTAssertEqual(FindFileDetails.sizeText(5_662_310), "5.4M")

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
            calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 14, minute: 38))!
        }
        let now = date(2026, 11, 30)
        XCTAssertEqual(FindFileDetails.modifiedText(date(2026, 11, 8), now: now, calendar: calendar), "Nov 08 14:38")
        XCTAssertEqual(FindFileDetails.modifiedText(date(2026, 11, 22), now: now, calendar: calendar), "8 days ago")
        XCTAssertEqual(FindFileDetails.modifiedText(date(2025, 12, 12), now: now, calendar: calendar), "2025 Dec 12")
    }

    func testPathRankingAndHighlights() {
        let filter = FilePathFilter([
            "build/lava/file.swift",
            "src/LavaFile.swift",
            "src/LoadArchivedVersionAutomatically.swift",
            "a/lava.swift",
            "longer/lava.swift",
        ])
        let matches = filter.rank("lava")
        XCTAssertEqual(matches.matches.map(\.index), [3, 4, 1, 2, 0])
        XCTAssertEqual(matches.matches[2].ranges, [4..<8])
        XCTAssertEqual(filter.rank("file src").matches.map(\.index), [1])
        XCTAssertEqual(filter.rank("lf").matches.first(where: { $0.index == 1 })?.ranges, [4..<5, 8..<9])
        XCTAssertEqual(filter.rank("file nope").total, 0)
        XCTAssertEqual(filter.rank("", limit: 2).matches.map(\.index), [0, 1])
        XCTAssertEqual(filter.rank("lava", limit: 2).total, 5)
    }

    func testWordStartsAndUnicodeOffsets() {
        let filter = FilePathFilter(["scat.swift", "older/cat.swift", "✌️/ÄBC.swift", "ab a.txt"])
        XCTAssertEqual(filter.rank("cat").matches.map(\.index), [1, 0])
        XCTAssertEqual(filter.rank("äc").matches.first?.ranges, [2..<3, 4..<5])
        XCTAssertEqual(filter.rank("abt").matches.map(\.index), [3])
    }

    func testChordDispatchAndCancellation() {
        typealias Chord = EditorKeyChord<String>
        let prefix = Chord.Stroke(88, modifiers: 2)
        let directory = Chord.Stroke(70, modifiers: 2)
        let project = Chord.Stroke(70)
        let escape = Chord.Stroke(256)
        let quit = Chord.Stroke(71, modifiers: 2)
        let unknown = Chord.Stroke(81)
        var chord = Chord(prefix: prefix, bindings: [directory: "directory", project: "project"],
                          cancelKeys: [escape, quit])

        XCTAssertEqual(chord.press(prefix, prefixAvailable: false), .pass)
        XCTAssertFalse(chord.isPending)
        XCTAssertEqual(chord.press(prefix, isRepeat: true), .pass)
        XCTAssertEqual(chord.press(prefix), .prefix)
        XCTAssertEqual(chord.press(prefix, isRepeat: true), .prefix)
        XCTAssertEqual(chord.press(Chord.Stroke(341, modifiers: 2), isModifier: true), .pass)
        XCTAssertTrue(chord.isPending)
        XCTAssertEqual(chord.press(directory), .action("directory"))
        XCTAssertFalse(chord.isPending)
        XCTAssertEqual(chord.press(project), .pass)
        XCTAssertEqual(chord.press(prefix), .prefix)
        XCTAssertEqual(chord.press(project), .action("project"))
        for cancel in [escape, quit] {
            XCTAssertEqual(chord.press(prefix), .prefix)
            XCTAssertEqual(chord.press(cancel), .cancel)
            XCTAssertFalse(chord.isPending)
        }
        XCTAssertEqual(chord.press(prefix), .prefix)
        XCTAssertEqual(chord.press(unknown), .undefined(unknown))
        XCTAssertFalse(chord.isPending)
    }
}
