import Foundation
import Testing
@testable import LavaLSPCore

@Suite struct LavaLSPCoreTests {
    @Test func framingHandlesPartialReadsAndCoalescedMessages() throws {
        let first = Data(#"{"string":"𐐀"}"#.utf8)
        let second = Data(#"{"id":2}"#.utf8)
        let header = Data("cOnTeNt-LeNgTh: \(first.count)\r\nContent-Type: application/vscode-jsonrpc\r\n\r\n".utf8)
        let stream = header + first + LSPFramer.frame(second) + LSPFramer.frame(first)
        for split in 0...stream.count {
            var framing = LSPFramer()
            var received: [Data] = []
            try framing.append(Data(stream.prefix(split))) { received.append($0) }
            try framing.append(Data(stream.dropFirst(split))) { received.append($0) }
            #expect(received == [first, second, first])
        }

        var framing = LSPFramer()
        #expect(throws: LSPFramingError.invalidHeader) {
            try framing.append(Data("content-length: 5\r\nContent-Length: 9\r\n\r\n".utf8)) { _ in }
        }
    }

    @Test func positionsRoundTripAcrossGraphemesAndLineEndings() {
        let text = "A😀👩‍💻e\u{301}\r\nβ\n"
        for (encoding, columns) in [(PositionEncoding.utf8, [0, 1, 5, 16, 19, 0, 2, 0]),
                                    (.utf16, [0, 1, 3, 8, 10, 0, 1, 0])] {
            let map = DocumentPositions(text, encoding: encoding)
            #expect(map.lineCount == 3)
            #expect(map.characterCount == 7)
            for (offset, column) in columns.enumerated() {
                let position = LSPPosition(line: offset < 5 ? 0 : (offset < 7 ? 1 : 2), character: column)
                #expect(map.position(atCharacterOffset: offset) == position)
                #expect(map.characterOffset(at: position) == offset)
            }
            let middle = LSPPosition(line: 0, character: 2)
            #expect(map.characterOffset(at: middle) == 1)
            #expect(map.characterOffset(at: middle, roundingUp: true) == 2)
            #expect(map.characterOffset(at: .init(line: 0, character: 100)) == 4)
            #expect(map.characterOffset(at: .init(line: 99, character: 0)) == nil)
        }
        #expect(DocumentPositions("").position(atCharacterOffset: 0) == .init(line: 0, character: 0))
        #expect(DocumentPositions("x\ry").lineCount == 1)
    }

    /// The line table is built from bytes; every Character offset it reports
    /// must be the one a walk by Character gives.
    @Test func positionsAgreeWithACharacterWalk() {
        let texts = ["", "\n", "\r\n", "\r", "a\r", "a\r\n", "ab\r\ncd", "x\r\r\ny",
                     "e\u{301}\n\u{301}x", "😀\r\n👩‍💻\n", "\n\n", "abc", "\r\u{301}\n",
                     "A😀👩‍💻e\u{301}\r\nβ\n", "plain\nascii\r\nlines\n"]
        for text in texts {
            var expected: [Int] = []
            for (offset, index) in zip(0..., text.indices) where text[index] == "\n" || text[index] == "\r\n" {
                expected.append(offset + 1)
                _ = index
            }
            let map = DocumentPositions(text)
            #expect(map.characterCount == text.count, "\(Array(text.unicodeScalars))")
            #expect(map.lineCount == expected.count + 1, "\(Array(text.unicodeScalars))")
            for (line, offset) in zip(1..., expected) {
                #expect(map.characterOffset(at: LSPPosition(line: line, character: 0)) == offset,
                        "\(Array(text.unicodeScalars)) line \(line)")
            }
            for offset in 0...text.count {
                let position = map.position(atCharacterOffset: offset)
                #expect(position.flatMap { map.characterOffset(at: $0) } == offset)
            }
        }
    }

    @Test func incrementalChangePreservesExactText() throws {
        let old = "a\r\n😀old👩‍💻\nend"
        let new = "a\r\n😀new\r\n👩‍💻\nend"
        for (encoding, start) in [(PositionEncoding.utf8, 4), (.utf16, 2)] {
            let edit = try #require(IncrementalChange.between(old, and: new, encoding: encoding))
            #expect(edit.range.start == .init(line: 1, character: start))
            #expect(edit.range.end == .init(line: 1, character: start + 3))
            #expect(edit.text == "new\r\n")
        }
        #expect(IncrementalChange.between(old, and: old) == nil)
        let accent = try #require(IncrementalChange.between("é", and: "e\u{301}"))
        #expect(accent.range.end.character == 1)
        #expect(Array(accent.text.utf8) == [101, 204, 129])
        let insertion = try #require(IncrementalChange.between("a\n", and: "a\nb"))
        #expect(insertion.range.start == .init(line: 1, character: 0))
        #expect(insertion.range.end == insertion.range.start)
        let deletion = try #require(IncrementalChange.between("aa", and: "a"))
        #expect(deletion.range.start.character == 1)
        #expect(deletion.range.end.character == 2)
        #expect(deletion.text.isEmpty)
        // Bytes agree past a boundary only one side has: the combining mark
        // joins the `e` in the new text, so the `e` is part of the change.
        let joined = try #require(IncrementalChange.between("ae", and: "ae\u{301}", encoding: .utf8))
        #expect(joined.range.start.character == 1)
        #expect(joined.range.end.character == 2)
        #expect(joined.text == "e\u{301}")
        // And the same at the end: a shared combining mark is not a shared suffix.
        let mark = try #require(IncrementalChange.between("ab\u{301}", and: "ac\u{301}", encoding: .utf8))
        #expect(mark.range.start.character == 1)
        #expect(mark.range.end.character == 4)
        #expect(mark.text == "c\u{301}")
    }

    @Test func semanticTokensDecodeApplyDeltaAndShift() throws {
        let legend = SemanticTokenLegend(tokenTypes: ["variable", "function"], tokenModifiers: ["readonly", "static"])
        let snapshot = SemanticTokensSnapshot(resultId: "one", data: [
            0, 1, 2, 0, 1, 0, 4, 3, 1, 3, 2, 7, 4, 0, 0,
        ])
        let updated = try snapshot.applying([
            .init(start: 11, deleteCount: 1, data: [8]),
            .init(start: 6, deleteCount: 1, data: [5]),
            .init(start: 15, deleteCount: 0, data: [1, 2, 1, 1, 0]),
        ], resultId: "two")
        #expect(updated.resultId == "two")
        let tokens = try legend.decode(updated.data)
        #expect(tokens.map(\.line) == [0, 0, 2, 3])
        #expect(tokens.map(\.start) == [1, 6, 8, 2])
        #expect(tokens[1].type == "function")
        #expect(tokens[1].modifiers == ["readonly", "static"])
        let change = IncrementalChange(range: .init(start: .init(line: 0, character: 3),
                                                     end: .init(line: 2, character: 6)),
                                       text: "x\r\n😀")
        let shifted = SemanticToken.shifting(tokens, for: change, encoding: .utf8)
        #expect(shifted.map(\.line) == [0, 1, 2])
        #expect(shifted.map(\.start) == [1, 6, 2])
        #expect(shifted.map(\.length) == [2, 4, 1])
        let insert = IncrementalChange(range: .init(start: .init(line: 0, character: 2),
                                                     end: .init(line: 0, character: 2)), text: "😀")
        #expect(SemanticToken.shifting(tokens, for: insert, encoding: .utf16).map(\.start) == [8, 8, 2])
        #expect(throws: SemanticTokensError.invalidDelta) {
            try snapshot.applying([.init(start: 14, deleteCount: 2)], resultId: nil)
        }
        #expect(throws: SemanticTokensError.invalidData) { try legend.decode([0, 0, 1, 8, 0]) }
    }

    @Test func definitionNormalizesAllResultShapes() throws {
        let range = #"{"start":{"line":1,"character":2},"end":{"line":1,"character":4}}"#
        let location = #"{"uri":"file:///main.swift","range":\#(range)}"#
        let link = #"[{"targetUri":"file:///main.swift","targetRange":{"start":{"line":0,"character":0},"end":{"line":2,"character":0}},"targetSelectionRange":\#(range)}]"#
        let expected = LSPLocation(uri: "file:///main.swift",
                                   range: .init(start: .init(line: 1, character: 2), end: .init(line: 1, character: 4)))
        for result in [location, "[\(location)]", link] {
            #expect(try decode(DefinitionResult.self, result).locations == [expected])
        }
        #expect(try decode(DefinitionResult.self, "null").locations.isEmpty)
    }

    @Test func hoverAndCompletionDecodeTheirWireVariants() throws {
        let hover = try decode(LSPHover.self, #"{"contents":[{"language":"swift","value":"let a = 1"},"**value** defined in [file](file:///a)"]}"#)
        #expect(hover.contents.map(\.text) == ["let a = 1", "value defined in file"])
        #expect(hover.contents.map(\.language) == ["swift", nil])
        let markdown = try decode(LSPHover.self, #"{"contents":{"kind":"markdown","value":"```cpp\nint x = a * b;\n```\nThe `value`."}}"#)
        #expect(markdown.contents.first?.language == "cpp")
        #expect(markdown.contents.first?.text == "int x = a * b;\nThe value.")
        let list = try decode(CompletionResult.self, #"{"isIncomplete":true,"items":[{"label":"word","sortText":"1","filterText":"w","textEdit":{"newText":"word","range":{"start":{"line":0,"character":0},"end":{"line":0,"character":1}}}}]}"#)
        #expect(list.isIncomplete)
        #expect(list.items.first?.textEdit?.newText == "word")
        #expect(list.items.first?.textEdit?.replace.end.character == 1)
        let items = try decode(CompletionResult.self, #"[{"label":"word","kind":6,"insertText":"a"}]"#)
        #expect(items.items.first?.insertText == "a")
        #expect(items.items.first?.kind == 6)
    }

    @Test func configSelectsNearestMarkerOrWorkspace() async throws {
        let workspace = try temporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let nested = workspace.appendingPathComponent("nested")
        let source = nested.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data().write(to: workspace.appendingPathComponent("Package.swift"))
        try Data().write(to: nested.appendingPathComponent("Package.swift"))
        let file = source.appendingPathComponent("main.swift")
        let config = LanguageServerConfig(name: "Swift", command: ["sourcekit-lsp"], languages: ["swift"],
                                          rootMarkers: ["Package.swift"])
        let selected = await LanguageServerConfig.select(for: file, in: workspace, configs: [config])
        #expect(selected?.root.path == nested.path)
        let noMatch = await LanguageServerConfig.select(for: file, in: workspace, configs: [config], language: "text")
        #expect(noMatch == nil)
        var fallback = config
        fallback.rootMarkers = []
        let defaultRoot = await LanguageServerConfig.select(for: file, in: workspace, configs: [fallback])
        #expect(defaultRoot?.root == workspace)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }
}

func temporaryWorkspace() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LavaLSP-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    return directory
}
