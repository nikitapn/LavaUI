import Testing

@testable import LavaShell

@Suite("App categories")
struct AppCategoryTests {
    @Test("the strongest claim wins over the first listed")
    func precedence() {
        #expect(AppCategory.of(["Network", "FileTransfer", "Game"]) == .games)
        #expect(AppCategory.of(["Office", "Graphics", "Viewer"]) == .office)
        #expect(AppCategory.of(["TextEditor", "Development", "IDE"]) == .development)
        #expect(AppCategory.of(["Network", "WebBrowser"]) == .internet)
        #expect(AppCategory.of(["AudioVideo", "Audio"]) == .multimedia)
        #expect(AppCategory.of(["System", "TerminalEmulator"]) == .system)
        #expect(AppCategory.of(["Utility", "TextEditor"]) == .accessories)
    }

    @Test("nothing recognisable is Other")
    func fallback() {
        #expect(AppCategory.of([]) == .other)
        #expect(AppCategory.of(["Qt", "KDE"]) == .other)
    }
}
