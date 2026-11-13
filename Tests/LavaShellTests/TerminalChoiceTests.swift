import Foundation
import Testing

@testable import LavaShell

@Suite("Terminal choice")
struct TerminalChoiceTests {
    private func entry(_ id: String, categories: [String] = ["System", "TerminalEmulator"]) -> DesktopEntry {
        DesktopEntry(id: id, name: id, exec: id.lowercased(), categories: categories)
    }

    @Test("$TERMINAL outranks every installed entry")
    func environmentFirst() throws {
        let chosen = try #require(TerminalChoice.choose(
            from: [entry("LavaTerm")], environment: ["TERMINAL": " kitty --single-instance "]
        ))
        #expect(chosen.exec == "kitty --single-instance")
    }

    @Test("an empty $TERMINAL is no preference")
    func emptyEnvironment() {
        let chosen = TerminalChoice.choose(from: [entry("LavaTerm")], environment: ["TERMINAL": "  "])
        #expect(chosen?.id == "LavaTerm")
    }

    @Test("LavaTerm before any other terminal, wherever it sorts")
    func houseTerminal() {
        let chosen = TerminalChoice.choose(
            from: [entry("Alacritty"), entry("LavaTerm"), entry("xterm")], environment: [:]
        )
        #expect(chosen?.id == "LavaTerm")
    }

    @Test("otherwise the first TerminalEmulator, and nothing that is not one")
    func anyTerminal() {
        let entries = [entry("Firefox", categories: ["Network", "WebBrowser"]), entry("Alacritty")]
        #expect(TerminalChoice.choose(from: entries, environment: [:])?.id == "Alacritty")
        #expect(TerminalChoice.choose(from: [entries[0]], environment: [:]) == nil)
    }

    /// The point of the whole feature: the child's working directory is the
    /// folder, and this process's own is left where it was.
    @Test("a launch starts the child in its working directory, not this process")
    func launchDirectory() throws {
        let root = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("lava-term-\(UUID().uuidString)")
        let folder = root + "/a folder with spaces"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let script = root + "/where.sh"
        let output = root + "/where.txt"
        try "#!/bin/sh\npwd > \(output)\n".write(toFile: script, atomically: true, encoding: .utf8)

        let before = FileManager.default.currentDirectoryPath
        var probe = DesktopEntry(id: "probe", name: "probe", exec: "/bin/sh \(script)")
        probe.workingDirectory = folder
        #expect(probe.launch())
        #expect(FileManager.default.currentDirectoryPath == before)

        let deadline = Date().addingTimeInterval(5)
        var written: String?
        while Date() < deadline {
            written = try? String(contentsOfFile: output, encoding: .utf8)
            if let written, !written.isEmpty { break }
            usleep(20_000)
        }
        #expect(written?.trimmingCharacters(in: .newlines) == folder)
    }
}
