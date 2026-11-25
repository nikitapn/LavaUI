import Foundation
import Testing

@testable import LavaLSPCore

@Suite struct SemanticTokenCacheTests {
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("semantic-cache-\(UUID().uuidString)")
    private let legend = SemanticTokenLegend(tokenTypes: ["type", "function", "property"],
                                             tokenModifiers: ["declaration", "static"])

    /// line 0: a type; line 2: a function (declaration, static) and a property.
    private func tokens() throws -> [SemanticToken] {
        try legend.decode([0, 4, 3, 0, 0, 2, 1, 5, 1, 0b11, 0, 8, 4, 2, 0])
    }

    private func files() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    }

    @Test func whatIsStoredForATextIsWhatIsLoadedForIt() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = SemanticTokenCache(directory: directory)
        let text = "let café: Int\n\nfunc run() { a.b }\n"
        let stored = try tokens()
        cache.store(path: "/p/a.swift", text: text, server: "sourcekit-lsp", encoding: .utf16, tokens: stored)
        let entry = try #require(cache.load(path: "/p/a.swift", text: text, server: "sourcekit-lsp"))
        #expect(entry.tokens == stored)
        #expect(entry.encoding == .utf16)
        #expect(entry.tokens[1].modifiers == ["declaration", "static"])
    }

    @Test func anEntryIsOnlyForItsOwnTextPathAndServer() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = SemanticTokenCache(directory: directory)
        cache.store(path: "/p/a.swift", text: "one", server: "s", encoding: .utf8, tokens: try tokens())
        #expect(cache.load(path: "/p/a.swift", text: "two", server: "s") == nil, "the file changed")
        #expect(cache.load(path: "/p/a.swift", text: "one!", server: "s") == nil, "same prefix, longer")
        #expect(cache.load(path: "/p/a.swift", text: "one", server: "clangd") == nil, "another server's")
        #expect(cache.load(path: "/p/b.swift", text: "one", server: "s") == nil, "never stored")
        #expect(cache.load(path: "/p/a.swift", text: "one", server: "s") != nil)
    }

    @Test func anUnreadableEntryIsAMiss() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = SemanticTokenCache(directory: directory)
        cache.store(path: "/p/a.swift", text: "one", server: "s", encoding: .utf8, tokens: try tokens())
        let written = try files()
        #expect(written.count == 1)
        try Data("{ not json".utf8).write(to: written[0])
        #expect(cache.load(path: "/p/a.swift", text: "one", server: "s") == nil)
    }

    @Test func theOldestEntriesGoPastTheLimit() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = SemanticTokenCache(directory: directory, maximumEntries: 3)
        for index in 0..<5 {
            cache.store(path: "/p/\(index).swift", text: "x", server: "s", encoding: .utf8, tokens: try tokens())
            // Each entry written "later" than the one before, by its time on disk.
            let newest = try files().filter { file in
                (try? Data(contentsOf: file)).map { String(decoding: $0, as: UTF8.self) }?
                    .contains("\(index).swift") ?? false
            }
            for file in newest {
                try FileManager.default.setAttributes(
                    [.modificationDate: Date(timeIntervalSince1970: Double(1_000_000 + index))], ofItemAtPath: file.path
                )
            }
        }
        cache.prune()
        #expect(try files().count == 3)
        #expect(cache.load(path: "/p/0.swift", text: "x", server: "s") == nil)
        #expect(cache.load(path: "/p/1.swift", text: "x", server: "s") == nil)
        #expect(cache.load(path: "/p/4.swift", text: "x", server: "s") != nil)
    }
}
