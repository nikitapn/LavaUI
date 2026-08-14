import XCTest

@testable import LavaUI

/// Authoring space is sRGB. The engine linearises at the vertex stage;
/// packing must leave the picker bytes alone or the attachment encodes twice.
final class ColorTests: XCTestCase {
    func testRgba8KeepsAuthoredSRGBBytes() {
        let mid = Color(r: 0.5, g: 0, b: 0, a: 1)
        // 0.5 × 255 = 127.5 → 128. The old pipeline wrote this as linear
        // and the swapchain lifted it to ~188. Packed value must stay 128.
        XCTAssertEqual(mid.rgba8 & 0xFF, 128)
        XCTAssertEqual((mid.rgba8 >> 8) & 0xFF, 0)
        XCTAssertEqual((mid.rgba8 >> 16) & 0xFF, 0)
        XCTAssertEqual((mid.rgba8 >> 24) & 0xFF, 255)
    }

    func testFullRedStays255() {
        let red = Color(r: 1, g: 0, b: 0)
        XCTAssertEqual(red.rgba8 & 0xFF, 255)
    }
}
