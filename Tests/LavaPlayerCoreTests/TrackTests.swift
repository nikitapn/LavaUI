import XCTest
@testable import LavaPlayerCore

final class TrackTests: XCTestCase {
    func testLanguageAndTitleAreBothSaid() {
        let track = Track(id: 2, kind: .subtitle, title: "SDH", language: "eng")
        XCTAssertEqual(track.label, "English — SDH")
    }

    func testATitleThatOnlyRepeatsTheLanguageIsSaidOnce() {
        let track = Track(id: 1, kind: .subtitle, title: "English", language: "eng")
        XCTAssertEqual(track.label, "English")
    }

    func testANamelessTrackIsNumbered() {
        XCTAssertEqual(Track(id: 3, kind: .audio).label, "Track 3")
        XCTAssertEqual(Track(id: 3, kind: .audio, language: "und").label, "Track 3")
    }

    func testForcedAndExternalAreNoted() {
        let track = Track(
            id: 4, kind: .subtitle, language: "fr", isExternal: true, isForced: true
        )
        XCTAssertEqual(track.label, "French (forced, file)")
    }

    func testAFileTracksLeftoverNameGivesWayToItsLanguage() {
        let withLanguage = Track(
            id: 3, kind: .subtitle, title: "de.srt", language: "de", isExternal: true
        )
        XCTAssertEqual(withLanguage.label, "German (file)")
        let without = Track(id: 4, kind: .subtitle, title: "dropped.srt", isExternal: true)
        XCTAssertEqual(without.label, "dropped.srt (file)")
    }

    func testAnUnknownTagIsShownAsItIs() {
        XCTAssertEqual(Track(id: 1, kind: .subtitle, language: "qqq").label, "qqq")
    }

    func testSelectionIsPerKind() {
        let tracks = [
            Track(id: 1, kind: .audio, isSelected: true),
            Track(id: 1, kind: .subtitle),
            Track(id: 2, kind: .subtitle, isSelected: true),
        ]
        XCTAssertEqual(tracks.selected(.subtitle), 2)
        XCTAssertEqual(tracks.selected(.audio), 1)
        XCTAssertNil(tracks.selected(.video))
        XCTAssertEqual(tracks.of(.subtitle).count, 2)
    }

    func testBadgeIsTheLanguageInCapitalsOrTheNumber() {
        XCTAssertEqual(Track(id: 1, kind: .audio, language: "eng").badge, "ENG")
        XCTAssertEqual(Track(id: 1, kind: .audio, language: "pt-BR").badge, "PT")
        XCTAssertEqual(Track(id: 2, kind: .audio, language: "und").badge, "#2")
        XCTAssertEqual(Track(id: 3, kind: .audio).badge, "#3")
    }

    func testNextWrapsAndNeverLandsOnNone() {
        let tracks = [
            Track(id: 1, kind: .audio),
            Track(id: 2, kind: .audio, isSelected: true),
            Track(id: 1, kind: .subtitle, isSelected: true),
        ]
        XCTAssertEqual(tracks.next(.audio), 1)
        XCTAssertEqual([Track(id: 1, kind: .audio), Track(id: 2, kind: .audio)].next(.audio), 1)
        XCTAssertNil([Track]().next(.audio))
    }

    func testSubtitleFilesAreKnownByExtension() {
        XCTAssertTrue(MediaFormats.isSubtitle(path: "/v/Movie.en.SRT"))
        XCTAssertFalse(MediaFormats.isSubtitle(path: "/v/Movie.mkv"))
        XCTAssertFalse(MediaFormats.isMedia(path: "/v/Movie.srt"))
    }
}
