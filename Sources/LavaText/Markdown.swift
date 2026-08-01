import Foundation

/// Semantic styles emitted by the small Markdown parser.
public enum MarkdownSpanStyle: Int, Equatable, Sendable {
    case heading
    case strong
    case emphasis
    case code
    case link
    case quote
}

public struct MarkdownSpan: Equatable, Sendable {
    public var range: Range<Int>
    public var style: MarkdownSpanStyle

    public init(range: Range<Int>, style: MarkdownSpanStyle) {
        self.range = range
        self.style = style
    }
}

/// Display text with Markdown delimiters removed and styles mapped to
/// character offsets in that display text.
public struct MarkdownDocument: Equatable, Sendable {
    public var text: String
    public var spans: [MarkdownSpan]

    public init(text: String, spans: [MarkdownSpan]) {
        self.text = text
        self.spans = spans
    }
}

/// A deliberately compact Markdown parser for model responses.
///
/// It handles the constructs useful in chat output: headings, paragraphs,
/// bullets, quotes, fenced/inline code, emphasis, strong text, and links.
/// Unknown syntax remains visible instead of being discarded.
public enum MarkdownParser {
    public static func parse(_ source: String) -> MarkdownDocument {
        var output = ""
        var spans: [MarkdownSpan] = []
        var fenced = false

        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        for (lineIndex, raw) in lines.enumerated() {
            var line = String(raw)
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                fenced.toggle()
                continue
            }
            if !output.isEmpty || lineIndex > 0 { output.append("\n") }

            let lineStart = output.count
            if fenced {
                output += line
                if !line.isEmpty {
                    spans.append(MarkdownSpan(range: lineStart..<output.count, style: .code))
                }
                continue
            }

            var blockStyle: MarkdownSpanStyle?
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            if trimmed.first == "#" {
                let marks = trimmed.prefix(while: { $0 == "#" }).count
                let rest = trimmed.dropFirst(marks)
                if rest.first == " " {
                    line = String(rest.dropFirst())
                    blockStyle = .heading
                }
            } else if trimmed.hasPrefix("> ") {
                line = "│ " + String(trimmed.dropFirst(2))
                blockStyle = .quote
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                line = "• " + String(trimmed.dropFirst(2))
            }

            let inlineSpanStart = spans.count
            appendInline(line, to: &output, spans: &spans)
            if let blockStyle, output.count > lineStart {
                // The renderer consumes non-overlapping spans. A block style
                // owns its whole row; inline delimiters are still removed but
                // their narrower styles do not compete with the heading/quote.
                spans.removeSubrange(inlineSpanStart..<spans.count)
                spans.append(MarkdownSpan(range: lineStart..<output.count, style: blockStyle))
            }
        }
        return MarkdownDocument(text: output, spans: spans.sorted { $0.range.lowerBound < $1.range.lowerBound })
    }

    private static func appendInline(
        _ source: String, to output: inout String, spans: inout [MarkdownSpan]
    ) {
        let chars = Array(source)
        var i = 0
        while i < chars.count {
            if i + 1 < chars.count, chars[i] == "*", chars[i + 1] == "*",
               let end = find("**", in: chars, after: i + 2)
            {
                let start = output.count
                output += String(chars[(i + 2)..<end])
                spans.append(MarkdownSpan(range: start..<output.count, style: .strong))
                i = end + 2
            } else if (chars[i] == "*" || chars[i] == "_"),
                      (i + 1 >= chars.count || chars[i + 1] != chars[i]),
                      let end = chars[(i + 1)...].firstIndex(of: chars[i]),
                      end > i + 1
            {
                let start = output.count
                output += String(chars[(i + 1)..<end])
                spans.append(MarkdownSpan(range: start..<output.count, style: .emphasis))
                i = end + 1
            } else if chars[i] == "`", let end = chars[(i + 1)...].firstIndex(of: "`") {
                let start = output.count
                output += String(chars[(i + 1)..<end])
                spans.append(MarkdownSpan(range: start..<output.count, style: .code))
                i = end + 1
            } else if chars[i] == "[", let close = chars[(i + 1)...].firstIndex(of: "]"),
                      close + 1 < chars.count, chars[close + 1] == "(",
                      let end = chars[(close + 2)...].firstIndex(of: ")")
            {
                let start = output.count
                output += String(chars[(i + 1)..<close])
                spans.append(MarkdownSpan(range: start..<output.count, style: .link))
                i = end + 1
            } else {
                output.append(chars[i])
                i += 1
            }
        }
    }

    private static func find(_ needle: String, in chars: [Character], after start: Int) -> Int? {
        let wanted = Array(needle)
        guard !wanted.isEmpty, start <= chars.count - wanted.count else { return nil }
        for i in start...(chars.count - wanted.count) where Array(chars[i..<(i + wanted.count)]) == wanted {
            return i
        }
        return nil
    }
}
