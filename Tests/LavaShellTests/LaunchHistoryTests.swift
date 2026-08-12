import Foundation
import Testing

@testable import LavaShell

@Suite("Launch history")
struct LaunchHistoryTests {
    @Test("ranks most-used first, then name")
    func ranksByCountThenName() {
        let entries = [
            DesktopEntry(
                id: "zzz", name: "Zebra", genericName: "", comment: "",
                icon: "", exec: "zzz", workingDirectory: "", terminal: false,
                categories: [], keywords: [], startupWMClass: ""
            ),
            DesktopEntry(
                id: "aaa", name: "Aardvark", genericName: "", comment: "",
                icon: "", exec: "aaa", workingDirectory: "", terminal: false,
                categories: [], keywords: [], startupWMClass: ""
            ),
            DesktopEntry(
                id: "mmm", name: "Marmot", genericName: "", comment: "",
                icon: "", exec: "mmm", workingDirectory: "", terminal: false,
                categories: [], keywords: [], startupWMClass: ""
            ),
        ]
        var history = LaunchHistory(counts: ["zzz": 5, "mmm": 5])
        // zzz and mmm tie on count → alphabetical; aaa never launched → last
        // among zeros, but also last overall since zeros sort under any count.
        let ranked = history.ranked(entries)
        #expect(ranked.map(\.id) == ["mmm", "zzz", "aaa"])

        history.record("aaa")
        history.record("aaa")
        // aaa now at 2, still under the fives.
        #expect(history.ranked(entries).map(\.id) == ["mmm", "zzz", "aaa"])
        for _ in 0..<10 { history.record("aaa") }
        #expect(history.ranked(entries).first?.id == "aaa")
    }

    @Test("round-trips the rofi-shaped cache file")
    func roundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lava-history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("cache").path

        var history = LaunchHistory()
        history.record("firefox")
        history.record("firefox")
        history.record("LavaWeather")
        history.save(to: path)

        let loaded = LaunchHistory.load(from: path)
        #expect(loaded.count(for: "firefox") == 2)
        #expect(loaded.count(for: "LavaWeather") == 1)
        #expect(loaded.count(for: "missing") == 0)

        // Rofi-style lines with a `.desktop` suffix still count.
        let rofi = "9 code.desktop\n3 LavaWeather.desktop\n"
        try Data(rofi.utf8).write(to: URL(fileURLWithPath: path))
        let fromRofi = LaunchHistory.load(from: path)
        #expect(fromRofi.count(for: "code") == 9)
        #expect(fromRofi.count(for: "LavaWeather") == 3)
    }

    @Test("search uses history as a tiebreaker")
    func searchTiebreak() {
        let entries = [
            DesktopEntry(
                id: "alpha-editor", name: "Alpha Editor", genericName: "",
                comment: "", icon: "", exec: "a", workingDirectory: "",
                terminal: false, categories: [], keywords: [], startupWMClass: ""
            ),
            DesktopEntry(
                id: "beta-editor", name: "Beta Editor", genericName: "",
                comment: "", icon: "", exec: "b", workingDirectory: "",
                terminal: false, categories: [], keywords: [], startupWMClass: ""
            ),
        ]
        let history = LaunchHistory(counts: ["beta-editor": 10])
        // Both match "editor" at the same score; beta has history.
        let found = DesktopEntry.search("editor", in: entries, history: history)
        #expect(found.map(\.id) == ["beta-editor", "alpha-editor"])

        // Empty query is pure frequency ranking.
        let empty = DesktopEntry.search("", in: entries, history: history)
        #expect(empty.first?.id == "beta-editor")
    }
}
