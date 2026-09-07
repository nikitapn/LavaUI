import XCTest

@testable import LavaViewCore

/// Which picture is "next", and what happens at the ends.
final class ImageFolderTests: XCTestCase {
    /// A directory of names, answered from a table rather than from disk — a
    /// real temp folder would make the ordering tests depend on what the
    /// filesystem happened to hand back.
    private func scanner(
        _ contents: [String: [String]], files: Set<String> = []
    ) -> FileScanner {
        FileScanner(
            isDirectory: { contents[$0] != nil },
            exists: { files.contains($0) || contents[$0] != nil },
            imageNames: { contents[$0]?.filter(ImageFormats.isImage(path:)) ?? [] }
        )
    }

    // MARK: - Ordering

    func testDigitRunsCompareAsNumbers() {
        let names = ["IMG_10.jpg", "IMG_9.jpg", "IMG_100.jpg", "IMG_2.jpg"]
        XCTAssertEqual(
            names.sorted(by: NaturalOrder.compare),
            ["IMG_2.jpg", "IMG_9.jpg", "IMG_10.jpg", "IMG_100.jpg"]
        )
    }

    func testLeadingZerosDoNotChangeTheOrder() {
        XCTAssertEqual(
            ["a007.png", "a8.png", "a06.png"].sorted(by: NaturalOrder.compare),
            ["a06.png", "a007.png", "a8.png"]
        )
    }

    func testCaseDoesNotSplitTheFolderIntoTwoBlocks() {
        XCTAssertEqual(
            ["beta.png", "Alpha.png", "alpha2.png"].sorted(by: NaturalOrder.compare),
            ["Alpha.png", "alpha2.png", "beta.png"]
        )
    }

    func testOrderIsTotalOnNamesThatFoldTogether() {
        // Neither ordering is more correct; what matters is that it is stable
        // and that both directions agree.
        XCTAssertNotEqual(
            NaturalOrder.compare("Photo.png", "photo.png"),
            NaturalOrder.compare("photo.png", "Photo.png")
        )
    }

    // MARK: - Building

    func testOpeningAFileTakesItsNeighboursWithIt() {
        let fs = scanner(
            ["/pics": ["b.png", "a.png", "notes.txt", "c.jpg"]],
            files: ["/pics/b.png"]
        )
        let folder = ImageFolder.around(path: "/pics/b.png", using: fs)
        XCTAssertEqual(
            folder.entries, ["/pics/a.png", "/pics/b.png", "/pics/c.jpg"]
        )
        XCTAssertEqual(folder.current, "/pics/b.png")
        XCTAssertEqual(folder.position, 2)
    }

    func testNonImagesAreNotInTheCollection() {
        let fs = scanner(["/pics": ["a.png", "readme.md", "clip.mp4"]])
        XCTAssertEqual(ImageFolder.around(path: "/pics", using: fs).entries, ["/pics/a.png"])
    }

    func testOpeningADirectoryLandsOnTheFirstPicture() {
        let fs = scanner(["/pics": ["z.png", "a.png"]])
        let folder = ImageFolder.around(path: "/pics", using: fs)
        XCTAssertEqual(folder.current, "/pics/a.png")
    }

    /// The named file wins over the listing. Losing your place because a scan
    /// disagreed would be the worst possible answer to "open this".
    func testAFileMissingFromTheListingIsStillOpened() {
        let fs = scanner(["/pics": ["a.png", "c.png"]], files: ["/pics/b.png"])
        let folder = ImageFolder.around(path: "/pics/b.png", using: fs)
        XCTAssertEqual(folder.entries, ["/pics/a.png", "/pics/b.png", "/pics/c.png"])
        XCTAssertEqual(folder.current, "/pics/b.png")
    }

    func testExplicitArgumentsAreTheWholeCollection() {
        let folder = ImageFolder.explicit(paths: ["/a/one.png", "/b/two.jpg", "/c/notes.txt"])
        XCTAssertEqual(folder.entries, ["/a/one.png", "/b/two.jpg"])
        XCTAssertEqual(folder.current, "/a/one.png")
    }

    // MARK: - Moving

    func testNextWrapsAtTheEnd() {
        let folder = ImageFolder(entries: ["/a.png", "/b.png", "/c.png"], index: 2)
        XCTAssertEqual(folder.advanced(by: 1).current, "/a.png")
    }

    func testPreviousWrapsAtTheStart() {
        let folder = ImageFolder(entries: ["/a.png", "/b.png"], index: 0)
        XCTAssertEqual(folder.advanced(by: -1).current, "/b.png")
    }

    func testASinglePictureStaysPut() {
        let folder = ImageFolder(entries: ["/a.png"], index: 0)
        XCTAssertEqual(folder.advanced(by: 1), folder)
    }

    func testAnEmptyFolderHasNoCurrent() {
        let folder = ImageFolder()
        XCTAssertNil(folder.current)
        XCTAssertEqual(folder.position, 0)
        XCTAssertEqual(folder.advanced(by: 1), folder)
    }

    func testJumpIsClamped() {
        let folder = ImageFolder(entries: ["/a.png", "/b.png"], index: 0)
        XCTAssertEqual(folder.jumped(to: 99).current, "/b.png")
        XCTAssertEqual(folder.jumped(to: -5).current, "/a.png")
    }

    /// A folder with one unreadable file in it must not become a dead end.
    func testDroppingABadFileLandsOnWhatWouldHaveBeenNext() {
        let folder = ImageFolder(entries: ["/a.png", "/bad.png", "/c.png"], index: 1)
        let after = folder.removing("/bad.png")
        XCTAssertEqual(after.entries, ["/a.png", "/c.png"])
        XCTAssertEqual(after.current, "/c.png")
    }

    func testDroppingTheLastFileLeavesNothing() {
        XCTAssertTrue(
            ImageFolder(entries: ["/only.png"], index: 0).removing("/only.png").isEmpty
        )
    }

    func testAnIndexOutOfRangeIsRefusedAtConstruction() {
        XCTAssertNil(ImageFolder(entries: ["/a.png"], index: 9).current)
    }
}
