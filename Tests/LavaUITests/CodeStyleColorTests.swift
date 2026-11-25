import XCTest

@testable import LavaUI

final class CodeStyleColorTests: XCTestCase {
    private let red = Color(r: 1, g: 0, b: 0)
    private let green = Color(r: 0, g: 1, b: 0)
    private let blue = Color(r: 0, g: 0, b: 1)
    private let plain = Color(r: 0.5, g: 0.5, b: 0.5)

    func testANameTakesTheColourOfItsNearestColouredAncestor() {
        let style = CodeStyle(text: plain, colors: ["function": red, "function.builtin": green])
        XCTAssertEqual(style.color(for: HighlightName.function), red)
        XCTAssertEqual(style.color(for: HighlightName.index(of: "function.method")), red)
        XCTAssertEqual(style.color(for: HighlightName.index(of: "function.builtin")), green)
        XCTAssertEqual(style.color(for: HighlightName.index(of: "function.builtin.deep")), green)
    }

    func testANameWithNothingColouredAboveItIsPlainText() {
        let style = CodeStyle(text: plain, colors: ["keyword": red])
        XCTAssertEqual(style.color(for: HighlightName.index(of: "variable")), plain)
        XCTAssertEqual(style.color(for: HighlightName.string), plain)
        XCTAssertEqual(style.color(for: 1_000_000), plain, "an index never handed out")
    }

    func testANameRegisteredAfterTheStyleWasMadeStillResolves() {
        let style = CodeStyle(text: plain, colors: ["punctuation": blue])
        let late = HighlightName.index(of: "punctuation.registered.after.\(UUID().uuidString)")
        XCTAssertEqual(style.color(for: late), blue)
    }

    func testAPositionalPaletteStillMeansWhatItsCallerMeant() {
        // TraceLoom's and the demo's palettes: indices are their own positions.
        let style = CodeStyle(text: plain, palette: [red, green])
        XCTAssertEqual(style.color(for: 0), red)
        XCTAssertEqual(style.color(for: 1), green)
        XCTAssertEqual(style.color(for: 2), plain)
        let both = CodeStyle(text: plain, palette: [red], colors: ["string": blue])
        XCTAssertEqual(both.color(for: 0), red, "the palette wins where it has an entry")
        XCTAssertEqual(both.color(for: HighlightName.string), blue)
    }

    func testChangingColoursResolvesAgain() {
        var style = CodeStyle(text: plain, colors: ["keyword": red])
        style.colors["keyword"] = green
        XCTAssertEqual(style.color(for: HighlightName.keyword), green)
    }
}
