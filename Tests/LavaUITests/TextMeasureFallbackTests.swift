import CxxCanvas
import XCTest

@testable import LavaUI

/// A text's box is its glyphs, so the box has to be measured from the glyphs
/// that are drawn — fallback faces included. `Font::measure` sees the primary
/// face alone; until the measure took the shaped width too, a label with an
/// arrow in it drew past its own box, which an 8pt margin used to hide.
final class TextMeasureFallbackTests: XCTestCase {
    private func font() throws -> UIFont {
        let editor = try XCTUnwrap(
            Editor.openClient(width: 200, height: 60), "client engine failed to open"
        )
        _ = FontStore.bootstrap(assetsRoot: LavaResources.root, pixelSize: 16, into: editor)
        return try XCTUnwrap(FontStore.default)
    }

    func testABoxIsAsWideAsTheGlyphsDrawnInIt() throws {
        let font = try font()
        for text in ["↑↓ move   ↵  open", "Pause ⏸ →", "✓ Show", "Hello, World!"] {
            let entry = TextLayoutCache.shared.layout(font: font, text: text, availWidth: 0, mode: 0)
            XCTAssertEqual(entry.width, font.shapedRun(text).width, accuracy: 0.01, text)
        }
    }

    func testAConstrainedMeasureStillStaysWithinWhatItWasOffered() throws {
        let font = try font()
        let entry = TextLayoutCache.shared.layout(
            font: font, text: "↑↓ move ↵ open ↑↓ move ↵ open", availWidth: 60, mode: 2
        )
        XCTAssertLessThanOrEqual(entry.width, 60.01)
    }
}
