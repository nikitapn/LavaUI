import CFontconfig
import XCTest
@testable import LavaFontCore

final class FontChooserModelTests: XCTestCase {
    private func catalog() throws -> FontCatalog {
        FontCatalog(patterns: [
            try pattern(["JetBrains Mono"], path: "/mono.ttf", spacing: FC_MONO),
            try pattern(["Noto Sans"], path: "/sans.ttf"),
            try pattern(["Noto Serif"], path: "/serif.ttf"),
            try pattern(["Noto Serif"], path: "/serif-italic.ttf", slant: FC_SLANT_ITALIC),
        ])
    }

    func testSearchCombinesWithCategoryAndSuppressesFavoritesHeading() throws {
        let catalog = try catalog()
        var picker = FontChooserModel(selection: .init(family: "Noto Sans", size: 14),
                                      showsStyle: true, favorites: ["Noto Serif"])
        XCTAssertEqual(picker.groups(in: catalog).map(\.label), ["Favorites", "All fonts"])
        XCTAssertEqual(picker.groups(in: catalog).map { $0.families.map(\.name) },
                       [["Noto Serif"], ["JetBrains Mono", "Noto Sans"]])
        picker.query = "  nOtO "
        XCTAssertEqual(picker.groups(in: catalog).map(\.label), ["2 results"])
        XCTAssertEqual(picker.groups(in: catalog).first?.families.map(\.name), ["Noto Sans", "Noto Serif"])
        picker.filter = .serif
        XCTAssertEqual(picker.groups(in: catalog).map(\.label), ["1 result"])
        XCTAssertEqual(picker.groups(in: catalog).first?.families.map(\.name), ["Noto Serif"])
        picker.filter = .monospace
        XCTAssertTrue(picker.groups(in: catalog).isEmpty)
    }

    func testFavoritesFilterAndToggle() throws {
        let catalog = try catalog()
        var picker = FontChooserModel(selection: .init(family: "Noto Sans", size: 14),
                                      showsStyle: false, favorites: [])
        picker.filter = .favorites
        XCTAssertTrue(picker.groups(in: catalog).isEmpty)
        picker.toggleFavorite("JetBrains Mono")
        XCTAssertEqual(picker.groups(in: catalog).map(\.label), ["Favorites"])
        XCTAssertEqual(picker.groups(in: catalog).first?.families.map(\.name), ["JetBrains Mono"])
        picker.query = "serif"
        XCTAssertTrue(picker.groups(in: catalog).isEmpty)
        picker.toggleFavorite("JetBrains Mono")
        XCTAssertTrue(picker.favorites.isEmpty)
    }

    func testSizeClampPresetsAndResetLeaveFiltersIntact() throws {
        let catalog = try catalog()
        var picker = FontChooserModel(selection: .init(family: "Noto Serif", size: 1),
                                      showsStyle: true, favorites: ["Noto Sans"])
        XCTAssertEqual(picker.choice.size, 6)
        picker.setSize(200)
        XCTAssertEqual(picker.choice.size, 96)
        for size in FontChooserModel.presets {
            picker.pickPreset(size)
            XCTAssertEqual(picker.choice.size, size)
        }
        picker.pickPreset(7)
        XCTAssertEqual(picker.choice.size, 72)
        picker.query = "Noto"
        picker.filter = .sans
        picker.reset(in: catalog)
        XCTAssertEqual(picker.choice, .init(family: "JetBrains Mono", style: .regular, size: 14))
        XCTAssertEqual(picker.query, "Noto")
        XCTAssertEqual(picker.filter, .sans)
        XCTAssertEqual(picker.favorites, ["Noto Sans"])
    }

    func testFamilyChangeKeepsSupportedStyleAndDisablesMissingStyles() throws {
        let catalog = try catalog()
        let serif = try XCTUnwrap(catalog.family(named: "Noto Serif"))
        let sans = try XCTUnwrap(catalog.family(named: "Noto Sans"))
        var picker = FontChooserModel(selection: .init(family: serif.name, style: .italic, size: 16),
                                      showsStyle: true, favorites: [])
        picker.pickStyle(.boldItalic, in: serif)
        XCTAssertEqual(picker.choice.style, .italic)
        picker.pick(sans)
        XCTAssertEqual(picker.choice.style, .regular)
        picker.pick(serif)
        picker.pickStyle(.italic, in: serif)
        XCTAssertEqual(picker.choice.style, .italic)

        var editor = FontChooserModel(selection: picker.choice, showsStyle: false, favorites: [])
        editor.pickStyle(.italic, in: serif)
        XCTAssertEqual(editor.choice.style, .regular)
    }

    func testResetFindsInstalledFallback() throws {
        let catalog = FontCatalog(patterns: [try pattern(["Noto Sans Mono"], path: "/mono.ttf", spacing: FC_MONO)])
        var picker = FontChooserModel(selection: .init(family: "Missing", size: 80),
                                      showsStyle: false, favorites: [])
        picker.reset(in: catalog)
        XCTAssertEqual(picker.choice, .init(family: "Noto Sans Mono", size: 14))
    }
}
