import CFontconfig
import XCTest
@testable import LavaFontCore

final class FontCatalogTests: XCTestCase {
    func testPatternsSupplyFamilyAliasesCategoryAndCollectionIndex() throws {
        let fonts = FontCatalog(patterns: [
            try pattern(["Noto Sans Mono", "Localized Mono"], path: "/mono.ttc", index: 3, spacing: FC_MONO),
            try pattern(["Cell Font"], path: "/cell.ttf", spacing: FC_CHARCELL),
            try pattern(["Dual Width"], path: "/dual.ttf", spacing: FC_DUAL),
            try pattern(["Sans Mono"], path: "/spacing-unset.ttf"),
            try pattern(["News Serif"], path: "/serif.ttf"),
            try pattern(["DejaVu Sans"], path: "/sans.ttf"),
            try pattern(["Acme Sans Roman"], path: "/acme.ttf"),
            try pattern(["Unclassified"], path: "/other.ttf"),
        ])
        XCTAssertEqual(fonts.family(named: "  localized mono ")?.name, "Noto Sans Mono")
        XCTAssertEqual(fonts.family(named: "Noto Sans Mono")?.isMonospaced, true)
        XCTAssertEqual(fonts.family(named: "Cell Font")?.category, .monospace)
        XCTAssertEqual(fonts.family(named: "Dual Width")?.category, .monospace)
        XCTAssertEqual(fonts.family(named: "Sans Mono")?.category, .monospace)
        XCTAssertEqual(fonts.family(named: "News Serif")?.category, .serif)
        XCTAssertEqual(fonts.family(named: "DejaVu Sans")?.category, .sans)
        XCTAssertEqual(fonts.family(named: "Acme Sans Roman")?.category, .sans)
        XCTAssertEqual(fonts.family(named: "Unclassified")?.category, .sans)
        XCTAssertEqual(fonts.resolveFace(family: "LOCALIZED MONO", style: .regular)?.index, 3)
        XCTAssertEqual(fonts.resolve(family: "Localized Mono", style: .regular), "/mono.ttc")
    }

    func testNearestWeightAndSlantAndDisabledStyles() throws {
        let fonts = FontCatalog(patterns: [
            try pattern(["Acme"], path: "/book.ttf", weight: FC_WEIGHT_BOOK),
            try pattern(["Acme"], path: "/medium.ttf", weight: FC_WEIGHT_MEDIUM),
            try pattern(["Acme"], path: "/semi.ttf", weight: FC_WEIGHT_DEMIBOLD),
            try pattern(["Acme"], path: "/black.ttf", weight: FC_WEIGHT_BLACK),
            try pattern(["Acme"], path: "/oblique.ttf", slant: FC_SLANT_OBLIQUE),
            try pattern(["One Weight"], path: "/regular.ttf"),
        ])
        let acme = try XCTUnwrap(fonts.family(named: "Acme"))
        XCTAssertEqual(acme.availableStyles, [.regular, .italic, .bold])
        XCTAssertEqual(acme.weightCount, 5)
        XCTAssertEqual(acme.face(for: .regular)?.path, "/book.ttf")
        XCTAssertEqual(acme.face(for: .bold)?.path, "/black.ttf")
        XCTAssertEqual(acme.face(for: .italic)?.path, "/oblique.ttf")
        XCTAssertEqual(acme.face(for: .boldItalic)?.path, "/oblique.ttf")
        XCTAssertEqual(fonts.family(named: "One Weight")?.availableStyles, [.regular])
        XCTAssertEqual(fonts.resolve(family: "One Weight", style: .bold), "/regular.ttf")
    }

    func testMalformedPatternIsSkipped() throws {
        let raw = try XCTUnwrap(FcPatternCreate())
        defer { FcPatternDestroy(raw) }
        XCTAssertNil(FontPattern(raw))
        FcPatternAddString(raw, FC_FILE, "/missing-family.ttf")
        XCTAssertNil(FontPattern(raw))
    }

    func testInstalledCatalogRejectsMissingFamily() {
        let fonts = FontCatalog.installed
        XCTAssertNil(fonts.resolve(family: "Missing Lava font 1203016", style: .regular))
        XCTAssertEqual(fonts.enumerationSeconds, FontCatalog.installed.enumerationSeconds)
        print("FontCatalog found \(fonts.families.count) families in \(String(format: "%.1f", fonts.enumerationSeconds * 1000)) ms")
    }
}

func pattern(
    _ names: [String], path: String, index: Int32 = 0,
    weight: Int32 = FC_WEIGHT_REGULAR, slant: Int32 = FC_SLANT_ROMAN, spacing: Int32? = nil
) throws -> FontPattern {
    let raw = try XCTUnwrap(FcPatternCreate())
    defer { FcPatternDestroy(raw) }
    for name in names { FcPatternAddString(raw, FC_FAMILY, name) }
    FcPatternAddString(raw, FC_FILE, path)
    FcPatternAddInteger(raw, FC_INDEX, index)
    FcPatternAddInteger(raw, FC_WEIGHT, weight)
    FcPatternAddInteger(raw, FC_SLANT, slant)
    if let spacing { FcPatternAddInteger(raw, FC_SPACING, spacing) }
    return try XCTUnwrap(FontPattern(raw))
}
