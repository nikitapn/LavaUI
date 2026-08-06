import XCTest

@testable import LavaUI

/// Registering an image that never had a path.
///
/// Two halves, and only one of them can be tested without a GPU. The decode is
/// pure — stb reading bytes, no device — so it is checked here against a real
/// file's contents. The upload is not, and is exercised live against a running
/// compositor instead; see docs/client-server-gaps.md.
///
/// The key is the part worth pinning hardest. A client derives it from the
/// bytes it sent and the compositor derives it from the bytes it received, and
/// nothing sends it across — so if the two implementations ever drift, every
/// registration silently becomes a cache miss on the client and a leak on the
/// renderer. There is only one implementation for exactly that reason, and
/// these tests are what say it must stay that way.
final class InMemoryImageTests: XCTestCase {
    /// A real PNG from the demo's resources, as bytes.
    private func samplePNG(
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> [UInt8] {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // LavaUITests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent(
                "Sources/HelloWorld/Resources/football-157930.svg_64.png"
            )
        let data = try Data(contentsOf: path)
        return [UInt8](data)
    }

    // ─── Decode ──────────────────────────────────────────────────────────────

    func testDecodesAPNGFromMemory() throws {
        let bytes = try samplePNG()
        let decoded = try XCTUnwrap(
            Editor.decodeImageData(bytes: bytes),
            "a valid PNG in memory should decode"
        )
        XCTAssertEqual(decoded.width, 64)
        XCTAssertEqual(decoded.height, 64)
        // RGBA8, which is what the upload expects — a decode that quietly
        // handed back three channels would be a corrupt texture, not a failure.
        XCTAssertEqual(decoded.pixels.count, 64 * 64 * 4)
    }

    func testMemoryDecodeMatchesFileDecode() throws {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(
                "Sources/HelloWorld/Resources/football-157930.svg_64.png"
            ).path

        let fromFile = try XCTUnwrap(Editor.decodeImage(path: path))
        let fromMemory = try XCTUnwrap(
            Editor.decodeImageData(bytes: try samplePNG())
        )
        // The same bytes through the same decoder: identical, or one of the
        // two entry points is doing something the other is not.
        XCTAssertEqual(fromFile.width, fromMemory.width)
        XCTAssertEqual(fromFile.height, fromMemory.height)
        XCTAssertEqual(fromFile.pixels, fromMemory.pixels)
    }

    func testCapAppliesToMemoryDecode() throws {
        let decoded = try XCTUnwrap(
            Editor.decodeImageData(bytes: try samplePNG(), maxPixelSize: 32)
        )
        XCTAssertEqual(decoded.width, 32)
        XCTAssertEqual(decoded.height, 32)
    }

    func testGarbageDoesNotDecode() {
        // Not a crash and not an empty image that would upload as a black
        // rectangle: the caller has to be able to tell.
        XCTAssertNil(Editor.decodeImageData(bytes: [0x00, 0x01, 0x02, 0x03]))
        XCTAssertNil(Editor.decodeImageData(bytes: []))
    }

    // ─── Identity ────────────────────────────────────────────────────────────

    func testSameBytesGiveTheSameKey() throws {
        let bytes = try samplePNG()
        XCTAssertEqual(
            ImageStore.contentKey(data: bytes, maxPixelSize: 0),
            ImageStore.contentKey(data: bytes, maxPixelSize: 0)
        )
    }

    func testDifferentBytesGiveDifferentKeys() throws {
        var mutated = try samplePNG()
        // One byte deep in the pixel data, so both remain decodable PNGs of
        // the same length — the length alone must not be carrying the key.
        mutated[mutated.count - 8] ^= 0xff
        XCTAssertNotEqual(
            ImageStore.contentKey(data: try samplePNG(), maxPixelSize: 0),
            ImageStore.contentKey(data: mutated, maxPixelSize: 0)
        )
    }

    func testCapIsPartOfTheIdentity() throws {
        // The same reason `key(path:maxPixelSize:)` includes it: one file
        // wanted at two sizes is two textures, and sharing them would either
        // blur one or waste the other's memory.
        let bytes = try samplePNG()
        XCTAssertNotEqual(
            ImageStore.contentKey(data: bytes, maxPixelSize: 0),
            ImageStore.contentKey(data: bytes, maxPixelSize: 32)
        )
    }

    func testKeyDoesNotCollideWithAPath() throws {
        // `ImageStore` is one namespace, and a file called `mem:…` is not
        // something to rule out — but the prefix plus a hash makes an
        // accidental meeting implausible rather than merely unlikely.
        let key = ImageStore.contentKey(data: try samplePNG(), maxPixelSize: 0)
        XCTAssertTrue(key.hasPrefix("mem:"))
        XCTAssertNotEqual(key, ImageStore.key(path: key, maxPixelSize: 0) + "x")
    }
}
