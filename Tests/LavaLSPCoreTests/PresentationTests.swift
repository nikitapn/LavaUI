import Foundation
import Testing
@testable import LavaLSPCore

@Suite struct PresentationTests {
    private func items(_ json: String) throws -> [CompletionItem] {
        try JSONDecoder().decode([CompletionItem].self, from: Data(json.utf8))
    }

    @Test func rankingPutsExactPrefixThenCaselessThenInOrderMatches() throws {
        let list = try items("""
        [{"label":"fooBarBaz"},{"label":"Foo"},{"label":"foo","sortText":"b"},
         {"label":"food","sortText":"a"},{"label":"xfoo"},{"label":"unrelated"}]
        """)
        let ranked = CompletionRanking.rank(list, prefix: "foo").map { list[$0].label }
        #expect(ranked == ["food", "foo", "fooBarBaz", "Foo"])
        #expect(CompletionRanking.rank(list, prefix: "fbz").map { list[$0].label } == ["fooBarBaz"])
        #expect(CompletionRanking.rank(list, prefix: "").count == list.count)
        #expect(CompletionRanking.rank(list, prefix: "f", limit: 2).count == 2)
    }

    @Test func filterTextIsWhatIsMatched() throws {
        let list = try items(#"[{"label":"init(name:)","filterText":"init"},{"label":"name"}]"#)
        #expect(CompletionRanking.rank(list, prefix: "ini").map { list[$0].label } == ["init(name:)"])
    }

    @Test func hoverKeepsTheSignatureAsCodeAndWrapsTheProse() throws {
        let hover = try JSONDecoder().decode(LSPHover.self, from: Data(#"""
        {"contents":{"kind":"markdown","value":"```swift\nfunc addUp(_ a: Int, _ b: Int) -> Int\n```\n\n---\n\nAdds two numbers, which is a sentence long enough to wrap at twenty."}}
        """#.utf8))
        let lines = HoverPresentation.lines(hover, width: 20)
        #expect(lines.first == .init("func addUp(_ a: Int, _ b: Int) -> Int", isCode: true))
        #expect(lines.dropFirst().allSatisfy { !$0.isCode })
        #expect(lines.dropFirst().allSatisfy { $0.text.count <= 20 })
        #expect(!lines.contains { $0.text == "---" })
        #expect(lines.filter(\.text.isEmpty).count == 1, "one blank line between signature and prose")
    }

    @Test func longHoversAreCut() throws {
        let body = (1...40).map { "line \($0)" }.joined(separator: "\n\n")
        let hover = try JSONDecoder().decode(LSPHover.self, from: Data(
            try JSONSerialization.data(withJSONObject: ["contents": ["kind": "plaintext", "value": body]])))
        let lines = HoverPresentation.lines(hover, maxLines: 6)
        #expect(lines.count == 6)
        #expect(lines.last?.text == "…")
    }
}

@Suite struct SnippetTextTests {
    @Test func placeholdersEmptyAndTheCaretOnTheFirst() {
        let call = SnippetText.expand("addUp(${1:a: Int}, ${2:b: Int})")
        #expect(call.text == "addUp(, )")
        #expect(call.caret == 6)
        #expect(SnippetText.expand("for ${2:x} in ${1:xs} {\n\t$0\n}") == ("for  in  {\n\t\n}", 8))
    }

    @Test func plainTextEscapesChoicesAndVariables() {
        #expect(SnippetText.expand("plain") == ("plain", 5))
        #expect(SnippetText.expand(#"cost \$5 \} $0"#) == ("cost $5 } ", 10))
        #expect(SnippetText.expand("${1|a,b|}x$TM_FILENAME") == ("x", 0))
        #expect(SnippetText.expand("f(${1:outer ${2:inner}})") == ("f()", 2))
    }
}
