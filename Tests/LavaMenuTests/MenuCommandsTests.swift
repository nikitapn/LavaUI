import XCTest
@testable import LavaMenu

final class MenuCommandsTests: XCTestCase {
    private func bar() -> MenuModel {
        MenuBar {
            Menu("File", id: "file") {
                MenuItem("Open…", id: "file.open", shortcut: KeyShortcut(79, .primary)) {}
                Menu("Recent", id: "file.recent") {
                    MenuItem("Clear Recent Files", id: "file.recent.clear") {}
                }
                MenuSeparator()
                MenuItem("Save", id: "file.save", isEnabled: false) {}
            }
            Menu("View", id: "view") {
                MenuItem("Toggle Soft Wrap", id: "view.wrap", isChecked: true) {}
                MenuItem("Toggle Sidebar", id: "view.sidebar") {}
                MenuItem("Search", id: "view.search") {}
            }
            Menu("Search", id: "search") {
                MenuItem("Find…", id: "search.find") {}
                MenuItem("Go to Line…", id: "search.goto") {}
            }
        }.resolve().model
    }

    func testTheBarFlattensWithItsMenusAndWithoutTheEllipsis() {
        let commands = bar().commands
        XCTAssertEqual(commands.map(\.id.raw), [
            "file.open", "file.recent.clear", "file.save",
            "view.wrap", "view.sidebar", "view.search", "search.find", "search.goto",
        ])
        XCTAssertEqual(commands[0].label, "File: Open")
        XCTAssertEqual(commands[1].label, "File › Recent: Clear Recent Files")
        XCTAssertEqual(commands[2].isEnabled, false)
        XCTAssertEqual(commands[3].isChecked, true)
        XCTAssertEqual(commands[0].shortcut, KeyShortcut(79, .primary))
    }

    func testNothingTypedListsRecentFirstThenMenuOrder() {
        let ranked = CommandFilter.rank(bar().commands, query: "  ",
                                        recent: [MenuID("search.goto"), MenuID("view.wrap")])
        XCTAssertEqual(ranked.prefix(3).map(\.id.raw), ["search.goto", "view.wrap", "file.open"])
        XCTAssertEqual(ranked.count, 8)
    }

    func testInitialsFindTheCommand() {
        let ranked = CommandFilter.rank(bar().commands, query: "tsw")
        XCTAssertEqual(ranked.first?.id.raw, "view.wrap")
    }

    func testEveryWordMustMatchInAnyOrder() {
        let ranked = CommandFilter.rank(bar().commands, query: "wrap toggle")
        XCTAssertEqual(ranked.map(\.id.raw), ["view.wrap"])
        XCTAssertTrue(CommandFilter.rank(bar().commands, query: "wrap zebra").isEmpty)
    }

    func testATitleMatchBeatsAMenuNameMatch() {
        // "search" is the title of View › Search and the name of the Search
        // menu; the command called Search is what was meant.
        let ranked = CommandFilter.rank(bar().commands, query: "search")
        XCTAssertEqual(ranked.first?.id.raw, "view.search")
        XCTAssertEqual(Set(ranked.map(\.id.raw)), ["view.search", "search.find", "search.goto"])
    }

    func testTheMenuNameNarrowsAlongsideTheTitle() {
        let ranked = CommandFilter.rank(bar().commands, query: "view sidebar")
        XCTAssertEqual(ranked.first?.id.raw, "view.sidebar")
    }

    func testRecentUseBreaksTies() {
        let commands = bar().commands
        // Equal matches: the shorter title first, until the other was used.
        XCTAssertEqual(CommandFilter.rank(commands, query: "toggle").first?.id.raw, "view.sidebar")
        let ranked = CommandFilter.rank(commands, query: "toggle", recent: [MenuID("view.wrap")])
        XCTAssertEqual(ranked.first?.id.raw, "view.wrap")
    }

    func testAWordStartBeatsTheMiddleOfAWord() {
        XCTAssertGreaterThan(CommandFilter.score("line", in: "go to line")!,
                             CommandFilter.score("line", in: "outline")!)
        XCTAssertNil(CommandFilter.score("xyz", in: "toggle sidebar"))
    }

    func testShortcutLabels() {
        #if !os(macOS)
        XCTAssertEqual(KeyShortcut(88, .option).label, "Alt+X")
        XCTAssertEqual(KeyShortcut(70, .primary, .shift).label, "Ctrl+Shift+F")
        XCTAssertEqual(KeyShortcut(296, .shift).label, "Shift+F7")
        XCTAssertEqual(KeyShortcut(96, .primary).label, "Ctrl+`")
        #endif
    }
}

final class ShortcutLabelParsingTests: XCTestCase {
    func testReadsWhatLabelWrites() {
        for shortcut in [KeyShortcut(74, .primary, .option), KeyShortcut(296, .shift), KeyShortcut(257, .primary, .shift),
                         KeyShortcut(96, .primary), KeyShortcut(290), KeyShortcut(32, .primary)] {
            XCTAssertEqual(KeyShortcut(label: shortcut.label), shortcut, shortcut.label)
        }
    }

    func testCaseAndSpellingsDoNotMatter() {
        XCTAssertEqual(KeyShortcut(label: "ctrl+alt+j"), KeyShortcut(74, .primary, .option))
        XCTAssertEqual(KeyShortcut(label: "Control + Shift + PageDown"), KeyShortcut(267, .primary, .shift))
        XCTAssertEqual(KeyShortcut(label: "Ctrl++"), KeyShortcut(43, .primary))
    }

    func testRefusesWhatCouldNotBeBoundSafely() {
        XCTAssertNil(KeyShortcut(label: "J"))
        XCTAssertNil(KeyShortcut(label: "Shift+J"))
        XCTAssertNil(KeyShortcut(label: "Ctrl+"))
        XCTAssertNil(KeyShortcut(label: "Hyper+J"))
        XCTAssertNil(KeyShortcut(label: "Ctrl+F26"))
        XCTAssertNil(KeyShortcut(label: "Ctrl+Ω"))
        XCTAssertNil(KeyShortcut(label: ""))
    }
}
