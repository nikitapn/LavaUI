import Testing
@testable import LavaText

@Test func markdownRemovesInlineDelimitersAndMapsStyles() {
    let document = MarkdownParser.parse("Use **strong**, *careful*, and `code` text.")
    #expect(document.text == "Use strong, careful, and code text.")
    #expect(document.spans == [
        MarkdownSpan(range: 4..<10, style: .strong),
        MarkdownSpan(range: 12..<19, style: .emphasis),
        MarkdownSpan(range: 25..<29, style: .code),
    ])
}

@Test func markdownParsesBlocksListsLinksAndFences() {
    let source = """
    # Result
    - Read [the docs](https://example.com)
    > Keep this visible
    ```swift
    let answer = 42
    ```
    """
    let document = MarkdownParser.parse(source)
    #expect(document.text == "Result\n• Read the docs\n│ Keep this visible\nlet answer = 42")
    #expect(document.spans.contains(MarkdownSpan(range: 0..<6, style: .heading)))
    #expect(document.spans.contains(MarkdownSpan(range: 14..<22, style: .link)))
    #expect(document.spans.contains { $0.style == .quote })
    #expect(document.spans.contains { $0.style == .code })
}

@Test func malformedMarkdownStaysVisible() {
    let document = MarkdownParser.parse("An **unfinished and [broken]( link")
    #expect(document.text == "An **unfinished and [broken]( link")
}
