import CxxCanvas
import XCTest

@testable import LavaUI

/// A tab is in no font's cmap, so it used to shape to `.notdef` and draw a
/// tofu box per indent level — a tab-indented file was unreadable. It now
/// carries a width and a space's glyph.
final class TabShapingTests: XCTestCase {
    private var font: UIFont!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let editor = try XCTUnwrap(
            Editor.openClient(width: 400, height: 200), "client engine failed to open"
        )
        font = try XCTUnwrap(
            FontStore.bootstrap(assetsRoot: LavaResources.root, pixelSize: 16, into: editor),
            "default face failed to load"
        )
    }

    override func tearDown() {
        font = nil
        super.tearDown()
    }

    private var spaceWidth: Float { font.shapedRun(" ").width }
    private var tabWidth: Float { spaceWidth * Float(UIFont.tabColumns) }

    func testATabIsNotNotdef() {
        let tab = font.shape("\t")
        XCTAssertEqual(tab.count, 1)
        XCTAssertNotEqual(tab[0].glyphId, 0, "glyph 0 is .notdef, which draws a tofu box")
        XCTAssertEqual(tab[0].glyphId, font.shape(" ")[0].glyphId, "a tab draws as a space")
    }

    func testATabIsFourSpacesWide() {
        XCTAssertEqual(font.shapedRun("\t").width, tabWidth, accuracy: 0.5)
        XCTAssertEqual(font.shapedRun("\t\t").width, tabWidth * 2, accuracy: 0.5)
    }

    /// One glyph per character, so every offset mapping still lines up.
    func testGlyphCountMatchesCharacters() {
        XCTAssertEqual(font.shape("a\tb").count, 3)
        XCTAssertEqual(font.shape("\t\tab").count, 4)
    }

    func testWidthIsThePartsPlusTheTabs() {
        let a = font.shapedRun("a").width
        let b = font.shapedRun("b").width
        XCTAssertEqual(font.shapedRun("a\tb").width, a + tabWidth + b, accuracy: 0.5)
    }

    /// The one that matters for editing: the caret has to land where the
    /// glyphs were drawn, across a tab.
    func testCaretSitsAfterTheTab() {
        let line = "a\tb"
        let run = font.shapedRun(line)
        let afterTab = line.index(line.startIndex, offsetBy: 2)
        XCTAssertEqual(
            run.caretX(for: afterTab), font.shapedRun("a").width + tabWidth, accuracy: 0.5
        )
    }

    func testHitTestRoundTripsAcrossATab() {
        let line = "ab\tcd"
        let run = font.shapedRun(line)
        for offset in 0...line.count {
            let index = line.index(line.startIndex, offsetBy: offset)
            let x = run.caretX(for: index)
            // Nudged past the boundary, because `index(atX:)` snaps to the
            // nearer edge and a click exactly on one is a coin toss.
            XCTAssertEqual(
                run.index(atX: x + 0.5), index,
                "clicking at the caret of offset \(offset) must return it"
            )
        }
    }

    /// `SoftWrap` consumes these, so a tab has to occupy exactly one slot.
    func testCharacterAdvancesGiveTheTabOneSlot() {
        let advances = font.shapedRun("a\tb").characterAdvances
        XCTAssertEqual(advances.count, 3)
        XCTAssertEqual(advances[1], tabWidth, accuracy: 0.5)
    }

    /// Leading indentation is the case tabs are actually used for, and each
    /// level has to be the same width as the last.
    func testIndentLevelsAreEvenlySpaced() {
        let one = font.shapedRun("\tx").width
        let two = font.shapedRun("\t\tx").width
        let three = font.shapedRun("\t\t\tx").width
        XCTAssertEqual(two - one, tabWidth, accuracy: 0.5)
        XCTAssertEqual(three - two, tabWidth, accuracy: 0.5)
    }

    /// The splice must not disturb the piece it shifts. This caught a real
    /// bug: the pen was advanced per glyph *and* per piece, so every character
    /// after a tab drifted one advance further right than the last.
    func testTextAfterATabKeepsItsOwnSpacing() {
        let plain = font.shapedRun("indent").glyphs
        let spliced = font.shapedRun("\tindent").glyphs
        XCTAssertEqual(plain.count + 1, spliced.count)
        for i in plain.indices {
            XCTAssertEqual(
                spliced[i + 1].x - spliced[1].x, plain[i].x - plain[0].x, accuracy: 0.1,
                "glyph \(i) drifted relative to the start of its word"
            )
        }
    }
}
