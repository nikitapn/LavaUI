import Foundation
import XCTest

@testable import LavaPDFCore

/// Encrypted files, made by encrypting a `TestPDF` with qpdf — AES-256, the
/// kind a current word processor writes. Skipped where qpdf is not installed.
final class PasswordTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/qpdf"), "no qpdf")
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lavapdf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    /// A two-page document with text and an outline, locked with `user` to
    /// open and `owner` to change.
    private func lockedFile() throws -> String {
        let plain = directory.appendingPathComponent("plain.pdf")
        let locked = directory.appendingPathComponent("locked.pdf")
        try TestPDF.write(
            [TestPDF.Page(lines: [(72, 700, 24, "Secret page")]), TestPDF.Page()],
            outline: [TestPDF.Entry(title: "Second", depth: 0, target: .page(1, top: 792))],
            to: plain
        )
        let qpdf = Process()
        qpdf.executableURL = URL(fileURLWithPath: "/usr/bin/qpdf")
        qpdf.arguments = ["--encrypt", "user-pw", "owner-pw", "256", "--", plain.path, locked.path]
        try qpdf.run()
        qpdf.waitUntilExit()
        XCTAssertEqual(qpdf.terminationStatus, 0)
        return locked.path
    }

    func testLockedWithoutOrWithTheWrongPassword() throws {
        let path = try lockedFile()
        XCTAssertThrowsError(try PDFDocument(path: path)) {
            XCTAssertEqual($0 as? PDFOpenError, .locked)
        }
        XCTAssertThrowsError(try PDFDocument(path: path, password: "nope")) {
            XCTAssertEqual($0 as? PDFOpenError, .locked, "wrong is still locked, not unreadable")
        }
    }

    /// Either password opens it, and everything works through it — the text
    /// and the render on poppler-cpp, the outline on the glib handle, which
    /// opens the file a second time and needs the password again.
    func testEitherPasswordOpensEverything() throws {
        let path = try lockedFile()
        for password in ["user-pw", "owner-pw"] {
            let document = try PDFDocument(path: path, password: password)
            XCTAssertEqual(document.pageCount, 2, password)
            XCTAssertEqual(document.text(page: 0).string, "Secret page", password)
            XCTAssertNotNil(document.render(page: 0, scale: 0.5, x: 0, y: 0, width: 64, height: 64), password)
            XCTAssertEqual(document.outline().items.map(\.title), ["Second"], password)
        }
    }
}
