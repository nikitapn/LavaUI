import Foundation

/// The words around an inline chat: what the agent is told once, how a
/// question about some lines is put, and how its proposed change is found
/// again in the reply.
public enum InlineChatPrompt {
    /// The fence info string that marks the replacement.
    public static let replaceTag = "replace"

    /// Appended to the agent's system prompt for the whole chat.
    public static let instructions = """
        You are answering inside the user's code editor, in a small box \
        between the lines they asked about. Keep answers short. You can read \
        the project with your tools, but you cannot edit files: the editor \
        applies changes itself, after the user reviews them. When you propose \
        a change to the lines in question, give the complete new text of \
        exactly those lines — every one of them, not only the changed ones, \
        and nothing outside them — in one fenced code block whose info string \
        is `\(replaceTag)`. Use at most one such block per answer. Explain the \
        change in a sentence or two before it.
        """

    /// The first message: the question, with where it is about and what is
    /// there now. `lines` are 1-based and inclusive, as people say them.
    public static func question(
        _ question: String, path: String, lines: ClosedRange<Int>, language: String, text: String
    ) -> String {
        let place = lines.count == 1 ? "line \(lines.lowerBound)" : "lines \(lines.lowerBound)-\(lines.upperBound)"
        let fence = fenceFor(text)
        return """
            \(path), \(place), as it is in my editor now (possibly unsaved):
            \(fence)\(language)
            \(text)
            \(fence)

            \(question)

            \(reminder)
            """
    }

    /// Said with every message, not only in the system prompt: a resumed
    /// conversation brings a long history of other habits, and a model
    /// reliably follows the format it was asked for just now.
    public static let reminder = "(If you propose a change to those lines, put their complete new text in one fenced block with the info string `\(replaceTag)`.)"

    /// A follow-up in the same chat.
    public static func followUp(_ question: String) -> String {
        question + "\n\n" + reminder
    }

    /// A session's title from a prompt: one line, and for a prompt this
    /// chat wrote — instructions, the lines quoted, a reminder — just
    /// `path:lines · the question`, which is what the user typed.
    public static func title(_ prompt: String) -> String {
        var text = prompt
        if text.hasPrefix(instructions) { text = String(text.dropFirst(instructions.count)) }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let marker = ", as it is in my editor now (possibly unsaved):"
        guard let header = text.range(of: marker), !text[..<header.lowerBound].contains("\n") else {
            return ClaudeSessions.oneLine(text)
        }
        var place = String(text[..<header.lowerBound])
        for (word, sep) in [(", lines ", ":"), (", line ", ":")] {
            if let range = place.range(of: word) { place.replaceSubrange(range, with: sep); break }
        }
        // The question sits between the quoted block's closing fence and the
        // reminder.
        var body = String(text[header.upperBound...])
        if let reminder = body.range(of: Self.reminder, options: .backwards) { body = String(body[..<reminder.lowerBound]) }
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
        let fences = lines.indices.filter { lines[$0].hasPrefix("```") }
        let question = fences.count >= 2
            ? lines[(fences[fences.count - 1] + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        return ClaudeSessions.oneLine(question.isEmpty ? place : place + " · " + question)
    }

    /// The replacement in a reply: the last block fenced as `replace`
    /// (alone, or after a language — ` ```swift replace `). Nil when the
    /// reply proposes nothing.
    public static func proposedReplacement(in reply: String) -> String? {
        var found: String?
        var collecting: [Substring]?
        var opener: Substring = ""
        for line in reply.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.drop { $0 == " " }
            if var body = collecting {
                if trimmed.hasPrefix(opener), trimmed.drop(while: { $0 == "`" || $0 == "~" }).allSatisfy(\.isWhitespace) {
                    found = body.joined(separator: "\n")
                    collecting = nil
                } else {
                    body.append(line)
                    collecting = body
                }
                continue
            }
            guard let mark = trimmed.first, mark == "`" || mark == "~" else { continue }
            let fence = trimmed.prefix { $0 == mark }
            guard fence.count >= 3 else { continue }
            let info = trimmed.dropFirst(fence.count).split(whereSeparator: \.isWhitespace)
            if info.contains(where: { $0 == replaceTag }) {
                opener = fence
                collecting = []
            }
        }
        return found
    }

    /// A fence longer than any run of backticks in `text`, so code that
    /// itself contains a fence stays inside.
    static func fenceFor(_ text: String) -> String {
        var longest = 0, run = 0
        for c in text {
            run = c == "`" ? run + 1 : 0
            longest = max(longest, run)
        }
        return String(repeating: "`", count: max(3, longest + 1))
    }
}

/// Whole lines of a text, in the character offsets an editor reports
/// (`Character`s, so `\r\n` is one).
public enum TextLines {
    /// The logical lines a selection from `a` to `b` touches, 0-based. A
    /// selection that ends at the very start of a line — whole lines picked
    /// with the trailing newline — does not take that line too.
    public static func lines(in text: String, from a: Int, to b: Int) -> ClosedRange<Int> {
        let low = min(a, b), high = max(a, b)
        var line = 0, offset = 0
        var first: Int?, last: Int?
        var afterNewline = false
        for c in text {
            if offset == low, first == nil { first = line }
            if offset == high { break }
            afterNewline = c.isNewline
            if afterNewline { line += 1 }
            offset += 1
        }
        // Reached `high`, or the end of the text before it.
        first = first ?? line
        last = line
        if high > low, afterNewline, offset == high, last! > first! { last! -= 1 }
        return first!...last!
    }

    /// The character range of `lines`, without the newline after the last.
    /// Nil when the text has fewer lines.
    public static func characterRange(of lines: ClosedRange<Int>, in text: String) -> Range<Int>? {
        var line = 0, offset = 0
        var start: Int? = lines.lowerBound == 0 ? 0 : nil
        for c in text {
            if c.isNewline {
                if line == lines.upperBound, let start { return start..<offset }
                line += 1
                offset += 1
                if line == lines.lowerBound { start = offset }
                continue
            }
            offset += 1
        }
        guard line == lines.upperBound, let start else { return nil }
        return start..<offset
    }

    /// The text of `lines`, joined as they are.
    public static func text(of lines: ClosedRange<Int>, in text: String) -> String? {
        guard let range = characterRange(of: lines, in: text) else { return nil }
        let start = text.index(text.startIndex, offsetBy: range.lowerBound)
        let end = text.index(start, offsetBy: range.count)
        return String(text[start..<end])
    }

    /// `text` with `lines` replaced by `replacement`.
    public static func replacing(_ lines: ClosedRange<Int>, in text: String, with replacement: String) -> String? {
        guard let range = characterRange(of: lines, in: text) else { return nil }
        let start = text.index(text.startIndex, offsetBy: range.lowerBound)
        let end = text.index(start, offsetBy: range.count)
        return String(text[..<start]) + replacement + String(text[end...])
    }
}
