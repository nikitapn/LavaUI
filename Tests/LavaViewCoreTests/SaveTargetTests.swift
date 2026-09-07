import XCTest

@testable import LavaViewCore

/// What a rotated picture is written back as.
///
/// The decisions here are the ones a user cannot check afterwards without
/// opening the file again, so they are made once, in one place, and stated in
/// the confirmation before anything is written.
final class SaveTargetTests: XCTestCase {
    func testAJpegStaysAJpegAndSaysItIsLossy() {
        let target = SaveTarget.inPlace(path: "/pics/holiday.JPG", hasAlpha: false)
        XCTAssertEqual(target.path, "/pics/holiday.JPG")
        XCTAssertEqual(target.encoding, .jpeg(quality: SaveTarget.jpegQuality))
        XCTAssertTrue(target.isLossy)
        XCTAssertFalse(target.isFormatChange)
    }

    func testAPngStaysAPngAndIsLossless() {
        let target = SaveTarget.inPlace(path: "/pics/diagram.png", hasAlpha: true)
        XCTAssertEqual(target.encoding, .png)
        XCTAssertFalse(target.isLossy)
        XCTAssertFalse(target.isFormatChange)
    }

    /// JPEG has no alpha channel. A file named `.jpg` that decoded with one —
    /// it happens, files get renamed — must not be written back with black
    /// where the transparency was.
    func testAJpegCarryingAlphaIsRedirectedToPng() {
        let target = SaveTarget.inPlace(path: "/pics/logo.jpg", hasAlpha: true)
        XCTAssertEqual(target.path, "/pics/logo.png")
        XCTAssertEqual(target.encoding, .png)
        XCTAssertTrue(target.isFormatChange)
    }

    /// The engine writes PNG and baseline JPEG and nothing else. Everything
    /// else gets a new name rather than a rasterised PNG written over it.
    func testFormatsWeCannotWriteBecomeAPngBesideTheOriginal() {
        for path in ["/pics/scan.gif", "/pics/old.bmp", "/pics/mark.svg"] {
            let target = SaveTarget.inPlace(path: path, hasAlpha: false)
            XCTAssertEqual(target.encoding, .png)
            XCTAssertTrue(target.isFormatChange, "\(path) should be reported as renamed")
            XCTAssertTrue(target.path.hasSuffix(".png"))
            XCTAssertNotEqual(target.path, path)
        }
    }

    func testSaveAsTrustsTheNameTheUserTyped() {
        let target = SaveTarget.explicit(path: "/out/copy.jpeg", hasAlpha: false)
        XCTAssertEqual(target.path, "/out/copy.jpeg")
        XCTAssertTrue(target.isLossy)
        // Nothing to report — the picker already showed where it is going.
        XCTAssertFalse(target.isFormatChange)
    }

    // MARK: - What the confirmation says

    func testTheLossyCaseIsSaidOutLoud() {
        let message = SaveTarget.inPlace(path: "/pics/a.jpg", hasAlpha: false)
            .confirmation(originalPath: "/pics/a.jpg")
        XCTAssertTrue(message.contains("a.jpg"))
        XCTAssertTrue(message.lowercased().contains("quality"))
    }

    func testTheRenameIsSaidOutLoud() {
        let message = SaveTarget.inPlace(path: "/pics/mark.svg", hasAlpha: false)
            .confirmation(originalPath: "/pics/mark.svg")
        XCTAssertTrue(message.contains("mark.svg"))
        XCTAssertTrue(message.contains("mark.png"))
    }

    func testALosslessOverwriteIsJustAQuestion() {
        let message = SaveTarget.inPlace(path: "/pics/a.png", hasAlpha: false)
            .confirmation(originalPath: "/pics/a.png")
        XCTAssertEqual(message, "Overwrite a.png?")
    }

    // MARK: - What counts as a picture

    func testExtensionsAreMatchedWithoutRegardToCase() {
        XCTAssertTrue(ImageFormats.isImage(path: "/a/B.PNG"))
        XCTAssertTrue(ImageFormats.isImage(path: "holiday.JpEg"))
        XCTAssertFalse(ImageFormats.isImage(path: "/a/notes.txt"))
        XCTAssertFalse(ImageFormats.isImage(path: "/a/no-extension"))
    }
}
