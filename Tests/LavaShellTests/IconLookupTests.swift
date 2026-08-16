import Foundation
import Testing

@testable import LavaShell

@Suite("Icon lookup")
struct IconLookupTests {
    @Test("empty Icon= inherits from a sibling that launches the same binary")
    func emptyIconInheritsFromSibling() throws {
        let icon = FileManager.default.temporaryDirectory
            .appendingPathComponent("lava-icon-test-\(UUID().uuidString).png")
        #expect(FileManager.default.createFile(atPath: icon.path, contents: Data([0])))
        defer { try? FileManager.default.removeItem(at: icon) }

        let packaged = try #require(DesktopEntry.parse(text: """
            [Desktop Entry]
            Type=Application
            Name=Packaged
            Exec=lava-test-bin %U
            Icon=\(icon.path)
            """, id: "org.example.LavaTest"))
        let handmade = try #require(DesktopEntry.parse(text: """
            [Desktop Entry]
            Type=Application
            Name=Handmade
            Exec=/usr/bin/lava-test-bin %u
            """, id: "lava-test-bin"))

        IconLookup.useEntries([packaged, handmade])
        #expect(IconLookup.themePath(forEntry: handmade) == icon.path)
    }

    @Test("flatpak-style icon names resolve under XDG data dirs")
    func flatpakExportIsOnTheSearchPath() {
        // Present on this machine when Steam is installed as a Flatpak.
        // Skip rather than fail on a box that does not have it.
        let steam = (ProcessInfo.processInfo.environment["HOME"] ?? "")
            + "/.local/share/flatpak/exports/share/icons/hicolor/"
            + "48x48/apps/com.valvesoftware.Steam.png"
        guard FileManager.default.fileExists(atPath: steam) else { return }
        IconLookup.useEntries([])
        #expect(IconLookup.themePath(forIconName: "com.valvesoftware.Steam") == steam)
    }
}
