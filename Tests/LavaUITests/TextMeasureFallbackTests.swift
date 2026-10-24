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

extension TextMeasureFallbackTests {
    /// A text offered exactly its own natural width is one line. A menu is
    /// measured at its natural size and then laid out again at that size;
    /// a row that wraps on the second pass makes the plate taller than the
    /// surface that was sized for it, and the frost stops short of the rows.
    func testATextAtItsOwnWidthDoesNotWrap() throws {
        let font = try font()
        let titles = [
            "Delete browsing data…", "Delete browsing data...", "Open history page",
            "JavaScript console", "Inspect elements", "Task manager", "Developer tools",
            "AV Wa To Ty fi ff", "Move ↑↓ to Workspace",
        ]
        for text in titles {
            let natural = TextLayoutCache.shared.layout(font: font, text: text, availWidth: 0, mode: 0)
            for mode in [1, 2] {
                let at = TextLayoutCache.shared.layout(
                    font: font, text: text, availWidth: natural.width, mode: mode
                )
                XCTAssertEqual(at.lines.count, 1, "\(text) wrapped at \(natural.width) (mode \(mode)): \(at.lines)")
            }
        }
    }
}

extension TextMeasureFallbackTests {
    /// The context menu's own two passes: lay the plate out in a big canvas,
    /// read its frame, lay it out again in a surface that size. The second
    /// must come out the same height — a row that wrapped there is the plate
    /// the frost was cut for, with rows hanging out of the bottom of it.
    func testAMenuPlateLaidOutAtItsOwnSizeKeepsItsHeight() throws {
        _ = try font()
        let titles = [
            "Downloads", "Open history page", "Extensions", "Task manager",
            "Delete browsing data…", "View source", "Developer tools",
            "Inspect elements", "JavaScript console", "Inspect devices",
        ]
        func plate() -> some View {
            VStack(padding: 0, spacing: 0) {
                HStack(padding: 0, spacing: 0) {
                    VStack(padding: 4, spacing: 0) {
                        ForEach(titles, id: \.self) { title in
                            HStack(padding: 0, alignment: .center, spacing: 0) {
                                Text(title)
                            }
                            .padding(EdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14))
                        }
                    }
                    .frame(minWidth: 120)
                    .agentId("plate")
                    Spacer()
                }
                Spacer()
            }
        }
        let host = LayoutHost()
        host.setRoot(plate())
        _ = host.calculateLayout(width: 600, height: 4096)
        let natural = try XCTUnwrap(host.agentFrame(sid: "plate"))
        _ = host.calculateLayout(width: natural.w.rounded(.up), height: natural.h.rounded(.up))
        let fitted = try XCTUnwrap(host.agentFrame(sid: "plate"))
        XCTAssertEqual(fitted.h, natural.h, accuracy: 0.5, "natural \(natural), fitted \(fitted)")
    }
}
