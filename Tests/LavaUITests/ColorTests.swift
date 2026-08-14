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

    /// The curve has to be its own inverse or every round trip through
    /// lighting drifts, and the drift is a slow darkening nobody attributes
    /// to a colour conversion.
    func testLinearRoundTrips() {
        for v: Float in [0, 0.002, 0.04, 0.2, 0.5, 0.8, 1] {
            let back = Color.fromLinear(Color(r: v, g: v, b: v).linear)
            XCTAssertEqual(back.r, v, accuracy: 1e-4, "round trip at \(v)")
        }
    }

    /// The endpoints are exact and the midpoint is not: 0.5 authored is a
    /// little over a fifth of the light, which is the whole reason lighting
    /// cannot multiply authored components.
    func testLinearMatchesTheSRGBCurve() {
        XCTAssertEqual(Color(r: 0, g: 0, b: 0).linear.r, 0, accuracy: 1e-6)
        XCTAssertEqual(Color(r: 1, g: 1, b: 1).linear.r, 1, accuracy: 1e-6)
        XCTAssertEqual(Color(r: 0.5, g: 0.5, b: 0.5).linear.r, 0.2140, accuracy: 1e-3)
    }

    /// Alpha is coverage, not light, so neither direction touches it.
    func testAlphaSurvivesBothDirections() {
        let c = Color(r: 0.6, g: 0.3, b: 0.1, a: 0.42)
        XCTAssertEqual(c.linear.a, 0.42, accuracy: 1e-6)
        XCTAssertEqual(Color.fromLinear(c).a, 0.42, accuracy: 1e-6)
    }

    /// Halving the light must halve the light. Multiplying authored
    /// components instead lands at 0.5^2.4 — the bug this replaced, which
    /// made every shaded face in a `Scene3D` far darker than its light asked
    /// for. Stated in linear terms because that is where the claim is true.
    func testHalvingTheLightHalvesTheLight() {
        let base = Color(r: 0.8, g: 0.8, b: 0.8)
        let half = Color.fromLinear(
            Color(r: base.linear.r * 0.5, g: base.linear.g * 0.5,
                  b: base.linear.b * 0.5, a: 1)
        )
        XCTAssertEqual(half.linear.r, base.linear.r * 0.5, accuracy: 1e-4)
        // And is emphatically not the naive answer, which would be 0.4.
        XCTAssertGreaterThan(half.r, 0.55)
    }
}
