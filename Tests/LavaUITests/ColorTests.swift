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

    /// HSV is the picker's square. A pure hue is V = 1, S = 1, and must
    /// come back as the same authored RGB the HSL mid-light form produces.
    func testHSVPureHueMatchesHSLMid() {
        for h: Float in [0, 0.125, 1 / 6, 0.33, 0.5, 0.8] {
            let hsv = Color(hue: h, saturation: 1, value: 1)
            let hsl = Color(hue: h, saturation: 1, lightness: 0.5)
            XCTAssertEqual(hsv.r, hsl.r, accuracy: 1e-5, "h=\(h) r")
            XCTAssertEqual(hsv.g, hsl.g, accuracy: 1e-5, "h=\(h) g")
            XCTAssertEqual(hsv.b, hsl.b, accuracy: 1e-5, "h=\(h) b")
        }
    }

    func testHSVRoundTripOnPrimaries() {
        let red = Color(r: 1, g: 0, b: 0)
        let hsv = red.hsv
        XCTAssertEqual(hsv.hue, 0, accuracy: 1e-5)
        XCTAssertEqual(hsv.saturation, 1, accuracy: 1e-5)
        XCTAssertEqual(hsv.value, 1, accuracy: 1e-5)
        let back = Color(hue: hsv.hue, saturation: hsv.saturation, value: hsv.value)
        XCTAssertEqual(back.r, 1, accuracy: 1e-5)
        XCTAssertEqual(back.g, 0, accuracy: 1e-5)
        XCTAssertEqual(back.b, 0, accuracy: 1e-5)
    }

    func testHexOpaqueAndShortForm() {
        XCTAssertEqual(Color(r: 1, g: 0, b: 0.5).hex, "#FF0080")
        let fromLong = Color(hex: "#ff0080")
        XCTAssertEqual(fromLong?.r ?? 0, 1, accuracy: 1e-5)
        XCTAssertEqual(fromLong?.b ?? 0, 128 / 255, accuracy: 1e-5)
        let fromShort = Color(hex: "#f08")
        XCTAssertEqual(fromShort?.r ?? 0, 1, accuracy: 1e-5)
        XCTAssertEqual(fromShort?.g ?? 1, 0, accuracy: 1e-5)
        XCTAssertEqual(fromShort?.b ?? 0, 136 / 255, accuracy: 1e-5)
        XCTAssertNil(Color(hex: "#gg0000"))
        XCTAssertNil(Color(hex: "#ff00"))
    }

    func testHexKeepsAlpha() {
        let c = Color(hex: "#80ff00aa")
        XCTAssertEqual(c?.a ?? 0, 170 / 255, accuracy: 1e-5)
        XCTAssertEqual(c?.hex, "#80FF00AA")
    }

    func testRgb24MatchesCompositorWallpaperSpelling() {
        let c = Color(r: 14 / 255, g: 19 / 255, b: 31 / 255)
        XCTAssertEqual(c.rgb24, 0x0e_13_1f)
        let back = Color(rgb24: 0x0e_13_1f)
        XCTAssertEqual(back.rgb24, 0x0e_13_1f)
    }
}
