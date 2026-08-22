import XCTest

@testable import LavaUI

/// Built-in palettes the desktop can push by name. The compositor has the
/// same list in `canonicalThemeName` — an unknown name is dark — so a name
/// added here and not there would look like Settings applying nothing.
final class ThemeCatalogTests: XCTestCase {
    func testBuiltInsCoverEveryNamedPalette() {
        XCTAssertEqual(
            Theme.builtIns.map(\.name),
            ["dark", "light", "nebula", "ember", "moss", "paper", "graphite"]
        )
        for entry in Theme.builtIns {
            XCTAssertEqual(Theme.named(entry.name), entry.theme)
            XCTAssertFalse(entry.title.isEmpty)
            XCTAssertFalse(entry.summary.isEmpty)
        }
        XCTAssertNil(Theme.named("solarized"))
        XCTAssertNil(Theme.named(""))
    }

    func testEachPaletteKeepsTextReadableOnItsPanel() {
        for entry in Theme.builtIns {
            let contrast = abs(entry.theme.textPrimary.luminance
                               - entry.theme.panel.luminance)
            XCTAssertGreaterThan(
                contrast, 0.45,
                "\(entry.name) text on panel is only \(contrast)"
            )
        }
    }
}
