import XCTest
@testable import LavaPlayerCore

final class PlaylistTests: XCTestCase {
    private func scanner(_ folders: [String: [String]]) -> MediaScanner {
        MediaScanner(
            isDirectory: { folders[$0] != nil },
            mediaNames: { folders[$0] ?? [] }
        )
    }

    func testOneFileLandsInItsFolderInNaturalOrder() {
        let fs = scanner(["/s": ["Ep 10.mkv", "Ep 2.mkv", "Ep 1.mkv"]])
        let list = Playlist.from(paths: ["/s/Ep 2.mkv"], using: fs)
        XCTAssertEqual(list.entries, ["/s/Ep 1.mkv", "/s/Ep 2.mkv", "/s/Ep 10.mkv"])
        XCTAssertEqual(list.current, "/s/Ep 2.mkv")
        XCTAssertFalse(list.playsThrough)
    }

    func testAFileTheScanMissedIsSplicedInNotReplaced() {
        let fs = scanner(["/s": ["a.mkv", "c.mkv"]])
        let list = Playlist.from(paths: ["/s/b.weird"], using: fs)
        XCTAssertEqual(list.entries, ["/s/a.mkv", "/s/b.weird", "/s/c.mkv"])
        XCTAssertEqual(list.current, "/s/b.weird")
    }

    func testSeveralPathsAreTheListAndPlayThrough() {
        let list = Playlist.from(paths: ["/x/b.mp4", "/y/a.mp4"], using: scanner([:]))
        XCTAssertEqual(list.entries, ["/x/b.mp4", "/y/a.mp4"])
        XCTAssertTrue(list.playsThrough)
    }

    func testADirectoryOpensItsFirstFile() {
        let fs = scanner(["/d": ["2.mp4", "1.mp4"]])
        XCTAssertEqual(Playlist.from(paths: ["/d"], using: fs).current, "/d/1.mp4")
    }

    func testSteppingStopsAtTheEnds() {
        let list = Playlist(entries: ["a", "b"], index: 1)
        XCTAssertEqual(list.stepped(by: 1).current, "b")
        XCTAssertEqual(list.stepped(by: -1).current, "a")
        XCTAssertEqual(list.stepped(by: -1).stepped(by: -1).current, "a")
        XCTAssertFalse(list.hasNext)
        XCTAssertTrue(list.hasPrevious)
    }

    func testURLsArePassedThrough() {
        let list = Playlist.from(paths: ["https://e.org/v.mp4", "/a.mp4"], using: scanner([:]))
        XCTAssertEqual(list.entries.first, "https://e.org/v.mp4")
    }
}

final class ClockTests: XCTestCase {
    func testFormats() {
        XCTAssertEqual(Clock.format(0), "0:00")
        XCTAssertEqual(Clock.format(65.9), "1:05")
        XCTAssertEqual(Clock.format(3723), "1:02:03")
        XCTAssertEqual(Clock.format(nil), "--:--")
        XCTAssertEqual(Clock.format(.nan), "--:--")
    }

    func testPairKeepsOneShapeForAnHourLongFile() {
        XCTAssertEqual(Clock.pair(position: 7, duration: 3723), "0:00:07 / 1:02:03")
        XCTAssertEqual(Clock.pair(position: 7, duration: 125), "0:07 / 2:05")
        XCTAssertEqual(Clock.pair(position: nil, duration: nil), "--:-- / --:--")
    }
}
