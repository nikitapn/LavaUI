import XCTest

@testable import LavaFindCore

final class IndexConfigTests: XCTestCase {
    let home = "/home/u"

    func testRootsAreReadAbsoluteInFileOrder() {
        let config = IndexConfig(text: """
        # mine
        root = ~/Documents
        exclude = Steam
        root = /mnt/windows/Learning/
        #root = ~/Old
        """)
        XCTAssertEqual(config.roots(home: home), ["/home/u/Documents", "/mnt/windows/Learning"])
    }

    func testAddingGoesAfterTheLastRootAndKeepsEverythingElse() {
        var config = IndexConfig(text: """
        # mine
        root = ~/Documents
        exclude = Steam

        hidden = no
        """)
        XCTAssertTrue(config.add(root: "/home/u/Music/", home: home))
        XCTAssertEqual(config.text, """
        # mine
        root = ~/Documents
        root = ~/Music
        exclude = Steam

        hidden = no

        """)
        XCTAssertFalse(config.add(root: "~/Music", home: home), "already there, by either spelling")
        XCTAssertTrue(config.add(root: "/mnt/data", home: home))
        XCTAssertEqual(config.roots(home: home), ["/home/u/Documents", "/home/u/Music", "/mnt/data"])
    }

    func testAddingToAFileWithNoRootsAppends() {
        var config = IndexConfig(text: "# nothing yet\n")
        config.add(root: "/srv", home: home)
        XCTAssertEqual(config.text, "# nothing yet\nroot = /srv\n")
    }

    func testRemovingTakesOutOnlyThatRoot() {
        var config = IndexConfig(text: """
        root = ~/Documents
        # keep me
        root = /home/u/Documents/
        root = ~/Pictures
        """)
        XCTAssertTrue(config.remove(root: "/home/u/Documents", home: home), "both spellings go")
        XCTAssertEqual(config.text, "# keep me\nroot = ~/Pictures\n")
        XCTAssertFalse(config.remove(root: "/nope", home: home))
    }

    func testDefaultsAreTheFoldersThatExist() {
        let config = IndexConfig.defaults(home: home) { $0 == "/home/u/Documents" || $0 == "/home/u/Music" }
        XCTAssertEqual(config.roots(home: home), ["/home/u/Documents", "/home/u/Music"])
    }

    func testHidden() {
        XCTAssertFalse(IndexConfig(text: "root = /a\n").indexesHidden)
        XCTAssertTrue(IndexConfig(text: "hidden = yes\n").indexesHidden)
        XCTAssertFalse(IndexConfig(text: "hidden = yes\nhidden = no\n").indexesHidden, "last wins")
    }
}
