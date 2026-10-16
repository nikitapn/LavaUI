import Foundation
import Testing

@testable import LavaShell

/// Serialized because `IconLookup` is process-wide state: run side by side,
/// one test's `useEntries` replaced the other's between its setup and its
/// lookup, and the sibling it was about to find was gone.
///
/// Every lookup here searches a tree the test built (`useIconRoots`), never
/// the machine's own themes — a result that depends on what happens to be
/// installed passes on one box and silently tests nothing on the next.
@Suite("Icon lookup", .serialized)
struct IconLookupTests {
    @Test("empty Icon= inherits from a sibling that launches the same binary")
    func emptyIconInheritsFromSibling() throws {
        let root = try makeIconRoot()
        defer { tearDown(root) }
        let icon = root.appendingPathComponent("packaged.png")
        #expect(FileManager.default.createFile(atPath: icon.path, contents: Data([0])))

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

    @Test("flatpak exports are searched even without XDG_DATA_DIRS")
    func flatpakExportsAreAlwaysRoots() {
        // A nested compositor started from a stripped environment: no
        // XDG_DATA_DIRS, so only the fallbacks put Flatpak's icons in reach.
        let roots = IconLookup.iconRoots(environment: ["HOME": "/home/u"])
        #expect(roots.contains("/home/u/.local/share/flatpak/exports/share/icons"))
        #expect(roots.contains("/var/lib/flatpak/exports/share/icons"))
        #expect(roots.first == "/home/u/.local/share/icons")
    }

    @Test("XDG_DATA_DIRS is searched in order, before the fixed roots")
    func dataDirsComeFirst() {
        let roots = IconLookup.iconRoots(environment: [
            "HOME": "/home/u",
            "XDG_DATA_HOME": "/data/home",
            "XDG_DATA_DIRS": "/opt/exports/share::/usr/share",
        ])
        #expect(roots.prefix(3) == [
            "/data/home/icons", "/opt/exports/share/icons", "/usr/share/icons",
        ])
        // Named once, where XDG_DATA_DIRS put it — not again as a fallback.
        #expect(roots.filter { $0 == "/usr/share/icons" }.count == 1)
    }

    @Test("a flatpak-style icon name resolves in hicolor's NxN/apps layout")
    func flatpakIconResolvesInHicolor() throws {
        let root = try makeIconRoot()
        defer { tearDown(root) }
        // Where Flatpak exports an application's own icon.
        let dir = root.appendingPathComponent("hicolor/48x48/apps")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let icon = dir.appendingPathComponent("com.example.Game.png")
        #expect(FileManager.default.createFile(atPath: icon.path, contents: Data([0])))

        IconLookup.useEntries([])
        #expect(IconLookup.themePath(forIconName: "com.example.Game") == icon.path)
        #expect(IconLookup.themePath(forIconName: "com.example.Missing") == nil)
    }

    /// An empty icon root of the test's own, made the only one searched.
    private func makeIconRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lava-icon-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        IconLookup.useIconRoots([root.path])
        return root
    }

    private func tearDown(_ root: URL) {
        IconLookup.useIconRoots(nil)
        try? FileManager.default.removeItem(at: root)
    }
}
