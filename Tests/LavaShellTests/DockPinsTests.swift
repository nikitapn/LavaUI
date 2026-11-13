import Foundation
import Testing

@testable import LavaShell

@Suite("Dock pins")
struct DockPinsTests {
    /// A `[*]` line, not the header comment that mentions it.
    static func hasDefaultsSection(_ text: String) -> Bool {
        text.split(separator: "\n").contains { $0 == "[*]" }
    }

    @Test("a workspace with no section shows the defaults")
    func defaultsForNewWorkspaces() {
        let pins = DockPins.parse("[0]\nfirefox\nLavaTerm\n")
        #expect(pins.ids(on: 0) == ["firefox", "LavaTerm"])
        #expect(pins.ids(on: 3) == DockPins.builtInDefaults)
        #expect(pins.hasOwnPins(on: 0))
        #expect(!pins.hasOwnPins(on: 3))
        // No file at all is the same as no sections.
        #expect(DockPins().ids(on: 0) == DockPins.builtInDefaults)
    }

    @Test("an empty section is no pins, not the defaults")
    func emptySectionStaysEmpty() {
        let pins = DockPins.parse("[2]\n")
        #expect(pins.ids(on: 2).isEmpty)
        // And unpinning the last one writes exactly that.
        var unpinned = DockPins()
        for id in DockPins.builtInDefaults { unpinned.unpin(id, on: 4) }
        #expect(unpinned.ids(on: 4).isEmpty)
        #expect(DockPins.parse(unpinned.serialized).ids(on: 4).isEmpty)
    }

    @Test("[*] replaces the built-in defaults, and survives a save")
    func customDefaults() {
        let text = "[*]\nLavaExplorer\nfirefox\n\n[0]\nLavaTerm\n"
        let pins = DockPins.parse(text)
        #expect(pins.ids(on: 5) == ["LavaExplorer", "firefox"])
        #expect(pins.ids(on: 0) == ["LavaTerm"])
        let again = DockPins.parse(pins.serialized)
        #expect(again == pins)
        // Without [*] none is written, so the built-in set can change later.
        #expect(!Self.hasDefaultsSection(DockPins.parse("[0]\nLavaTerm\n").serialized))
    }

    @Test("pinning on a workspace showing the defaults keeps them")
    func firstChangeKeepsTheDefaults() {
        var pins = DockPins()
        pins.pin("firefox", on: 6)
        #expect(pins.ids(on: 6) == DockPins.builtInDefaults + ["firefox"])
        #expect(pins.hasOwnPins(on: 6))
        // Other workspaces still follow the defaults.
        #expect(pins.ids(on: 7) == DockPins.builtInDefaults)
    }

    @Test("defaults this install cannot start are left out, and not saved as gone")
    func unavailableDefaults() {
        var pins = DockPins()
        pins.unavailable = ["LavaEditor"]
        #expect(!pins.ids(on: 1).contains("LavaEditor"))
        #expect(pins.ids(on: 1).count == DockPins.builtInDefaults.count - 1)
        // A section made from them does not carry the missing one, and the
        // file says nothing about what was unavailable.
        pins.pin("firefox", on: 1)
        #expect(!pins.ids(on: 1).contains("LavaEditor"))
        #expect(!Self.hasDefaultsSection(pins.serialized))
    }

    @Test("a header is never mistaken for an app id")
    func headersAreNotApps() {
        #expect(!DockPins.canPin("[*]"))
        #expect(!DockPins.canPin("[3]"))
        #expect(DockPins.canPin("LavaTerm"))
        let pins = DockPins.parse("[ * ]\nLavaTerm\n")
        #expect(pins.defaults == ["LavaTerm"])
    }
}
