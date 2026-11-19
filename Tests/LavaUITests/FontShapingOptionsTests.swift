import XCTest

@testable import LavaUI

/// OpenType features and letter-spacing are applied in the client's shaper,
/// so every path that measures — width, glyph run, word wrap — has to see
/// them, or a box is laid out for one string and drawn for another.
final class FontShapingOptionsTests: XCTestCase {
    private func figtree(_ features: [String] = [], letterSpacing: Float = 0) throws -> UIFont {
        let path = try XCTUnwrap(BundledFont.path("Figtree-Regular"))
        return try XCTUnwrap(UIFont(path: path, pixelSize: 14, features: features,
                                    letterSpacing: letterSpacing))
    }

    /// Figtree's figures are proportional by default — a `1` is narrower than
    /// a `0`, which is what makes a seconds clock shake. `tnum` evens them.
    func testTabularFiguresShareOneAdvance() throws {
        let proportional = try figtree()
        let tabular = try figtree(["tnum"])
        let digits = (0...9).map(String.init)
        XCTAssertGreaterThan(Set(digits.map { proportional.measure($0).width }).count, 1)
        XCTAssertEqual(Set(digits.map { tabular.measure($0).width }).count, 1)
        XCTAssertEqual(tabular.measure("11:11:11").width, tabular.measure("00:00:00").width)
    }

    /// Letter-spacing follows every letter, the last included, as CSS's does,
    /// and the glyph run agrees with the measured width.
    func testLetterSpacingWidensByOneStepPerLetter() throws {
        let plain = try figtree()
        let spaced = try figtree(letterSpacing: 0.1)
        let text = "OUTPUT"
        let step: Float = 0.1 * 14
        XCTAssertEqual(spaced.measure(text).width,
                       plain.measure(text).width + step * Float(text.count), accuracy: 0.05)
        let run = spaced.shape(text)
        let last = try XCTUnwrap(run.last)
        XCTAssertEqual(last.x + last.advance, spaced.measure(text).width, accuracy: 0.05)
    }

    func testOptionsAreInTheIdentity() throws {
        XCTAssertNotEqual(try figtree().identity, try figtree(["tnum"]).identity)
        XCTAssertNotEqual(try figtree().identity, try figtree(letterSpacing: 0.1).identity)
    }

    func testUnparseableFeatureRefusesTheFont() throws {
        let path = try XCTUnwrap(BundledFont.path("Figtree-Regular"))
        XCTAssertNil(UIFont(path: path, pixelSize: 14, features: ["not a feature!"]))
    }
}
