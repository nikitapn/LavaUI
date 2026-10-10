import Foundation
import XCTest

@testable import LavaFindCore

final class FindFormatTests: XCTestCase {
    func testSizesReadTheWayTheDesignDoes() {
        XCTAssertEqual(FindFormat.size(512), "512 B")
        XCTAssertEqual(FindFormat.size(120 * 1024), "120 KB")
        XCTAssertEqual(FindFormat.size(UInt64(2.4 * 1024 * 1024)), "2.4 MB")
        XCTAssertEqual(FindFormat.size(412 * 1024 * 1024), "412 MB")
        XCTAssertEqual(FindFormat.size(UInt64(9.96 * 1024 * 1024)), "10 MB", "rounding never reads 10.0")
        XCTAssertEqual(FindFormat.size(3 * 1024 * 1024 * 1024), "3.0 GB")
    }

    func testDatesDropTheYearOnlyWhenItIsThisOne() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_791_000_000)  // Oct 2026
        XCTAssertEqual(FindFormat.date(1_790_933_400, now: now, calendar: utc), "Oct 2")
        XCTAssertEqual(FindFormat.date(1_727_827_200, now: now, calendar: utc), "Oct 2, 2024")
        XCTAssertEqual(FindFormat.date(0, now: now, calendar: utc), "", "unknown is blank, not 1970")
        XCTAssertEqual(
            FindFormat.detail(size: 2_516_582, mtime: 1_790_933_400, isDirectory: false,
                              now: now, calendar: utc),
            "2.4 MB · Oct 2")
        XCTAssertEqual(
            FindFormat.detail(size: 0, mtime: 1_790_933_400, isDirectory: true,
                              now: now, calendar: utc),
            "Oct 2", "a folder has no size")
    }

    func testBadges() {
        XCTAssertEqual(FindFormat.badge(ext: "pdf", isDirectory: false), "PDF")
        XCTAssertEqual(FindFormat.badge(ext: "", isDirectory: false), "FILE")
        XCTAssertEqual(FindFormat.badge(ext: "anything", isDirectory: true), "DIR")
        XCTAssertEqual(FindFormat.badge(ext: "torrent", isDirectory: false), "TORR")
    }

    func testPathsUnderHomeUseTilde() {
        let home = "/home/u"
        XCTAssertEqual(FindFormat.tilde("/home/u/Documents", home: home), "~/Documents")
        XCTAssertEqual(FindFormat.tilde("/home/user2/x", home: home), "/home/user2/x",
                       "a prefix is a path prefix, not a string one")
        let (name, folder) = FindFormat.split("/home/u/Documents/Work/Finance/Quarterly Report Q3.pdf", home: home)
        XCTAssertEqual(name, "Quarterly Report Q3.pdf")
        XCTAssertEqual(folder, "~/Documents/Work/Finance")
        XCTAssertEqual(FindFormat.split("/etc", home: home).folder, "/")
        XCTAssertEqual(FindFormat.split("/", home: home).folder, "", "the root is not in itself")
    }

    func testHighlightCutsAtTheDaemonsBytes() {
        let h = FindFormat.highlight("Quarterly Report Q3.pdf", start: 10, length: 6)
        XCTAssertEqual(h.before, "Quarterly ")
        XCTAssertEqual(h.match, "Report")
        XCTAssertEqual(h.after, " Q3.pdf")
        // "é" is two bytes: offsets count those, not characters.
        let accented = FindFormat.highlight("Résumé final.pdf", start: 9, length: 5)
        XCTAssertEqual(accented.match, "final")
        let broken = FindFormat.highlight("Résumé.pdf", start: 2, length: 3)
        XCTAssertEqual(broken.before, "Résumé.pdf", "inside a character: no highlight")
        XCTAssertEqual(broken.match, "")
        XCTAssertEqual(FindFormat.highlight("a.txt", start: 3, length: 9).match, "",
                       "out of range: no highlight")
    }

    func testRootsSummary() {
        let home = "/home/u"
        XCTAssertEqual(
            FindFormat.roots(["/home/u/Documents", "/home/u/Videos", "/home/u/Pictures", "/home/u/Downloads"], home: home),
            "~ (Documents, Videos, Pictures, Downloads)")
        XCTAssertEqual(
            FindFormat.roots(["/home/u/Documents", "/mnt/windows/Learning"], home: home),
            "~ (Documents), /mnt/windows/Learning")
        XCTAssertEqual(FindFormat.roots(["/home/u", "/home/u/Documents"], home: home), "~",
                       "home itself covers its folders")
        XCTAssertEqual(FindFormat.roots([], home: home), "")
    }
}
