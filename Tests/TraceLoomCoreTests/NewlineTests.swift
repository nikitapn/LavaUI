import Foundation
import Testing
@testable import TraceLoomCore

/// Swift treats "\r\n" as a single grapheme cluster that is *not* equal to
/// Character("\n"). Everything here exists because that one fact turned a
/// 23 MB Android log into a single 23-million-character line: the editor
/// shaped it as one run and the process passed 9 GB before it was killed,
/// while parsing degenerated to a near-empty timeline without a word.
@Test func swiftSplitReallyDoesCollapseCRLF() {
    // The premise, pinned: if this ever changes, the workarounds below can go.
    #expect("a\r\nb\r\nc".split(separator: "\n", omittingEmptySubsequences: false).count == 1)
    #expect(Character("\r\n") != Character("\n"))
}

// MARK: - Normalisation at load

@Test func loadNormalisesCRLFToLF() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("nl-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let url = dir.appendingPathComponent("crlf.log")
    FileManager.default.createFile(
        atPath: url.path,
        contents: Data("10:00:00.000 a=1\r\n10:00:01.000 a=2\r\n".utf8)
    )

    let load = try LogFile.read(at: url)
    #expect(!load.text.contains("\r"))
    #expect(load.text.split(separator: "\n", omittingEmptySubsequences: false).count == 3)
}

@Test func normalisationHandlesEveryTerminatorStyle() {
    #expect(LogFile.normalizingNewlines("a\r\nb") == "a\nb")
    #expect(LogFile.normalizingNewlines("a\rb") == "a\nb")
    #expect(LogFile.normalizingNewlines("a\nb") == "a\nb")
    #expect(LogFile.normalizingNewlines("a\r\n\r\nb") == "a\n\nb")
    #expect(LogFile.normalizingNewlines("a\n\rb") == "a\n\nb")
    #expect(LogFile.normalizingNewlines("trailing\r\n") == "trailing\n")
    #expect(LogFile.normalizingNewlines("") == "")
    // Untouched, and returned without copying, when there is no CR at all.
    #expect(LogFile.normalizingNewlines("plain text") == "plain text")
    // Multibyte survives the byte-level rewrite.
    #expect(LogFile.normalizingNewlines("café\r\n☃") == "café\n☃")
}

// MARK: - Parsing

/// The silent half of the bug: no hang, just a timeline with almost nothing
/// in it, and no indication why.
@Test func parsesCRLFLogsRatherThanTreatingThemAsOneLine() {
    let rules = #"line | A | ^(\d\d:\d\d:\d\d\.\d+).*a=(\d+) | 1 | 2 |"#
    let lf = "10:00:00.000 a=1\n10:00:01.000 a=2\n10:00:02.000 a=3"
    let crlf = "10:00:00.000 a=1\r\n10:00:01.000 a=2\r\n10:00:02.000 a=3"

    let fromLF = TraceParser.parse(log: lf, rulesSource: rules)
    let fromCRLF = TraceParser.parse(log: crlf, rulesSource: rules)

    #expect(fromLF.series[0].points.count == 3)
    #expect(fromCRLF.series[0].points.count == 3)
    #expect(fromCRLF.matchedLineCount == fromLF.matchedLineCount)
    #expect(fromCRLF.series[0].points == fromLF.series[0].points)
}

/// A stray `\r` at the end of every line breaks `$`-anchored rules in a way
/// that looks exactly like a wrong regex.
@Test func endAnchoredRulesStillMatchOnCRLFInput() {
    let rules = #"line | A | ^(\d+),(\d+)$ | 1 | 2 |"#
    let result = TraceParser.parse(log: "100,42\r\n200,43\r\n", rulesSource: rules)
    #expect(result.series[0].points.count == 2)
    #expect(result.series[0].points.first == TracePoint(time: 100, value: 42))
}

@Test func crlfSplitAgreesWithLFSplitOnLineCount() {
    for style in ["\n", "\r\n", "\r"] {
        let text = (1...50).map { "line\($0)" }.joined(separator: style)
        #expect(TraceParser.splitLines(text).count == 50, "terminator \(String(reflecting: style))")
        #expect(!TraceParser.splitLines(text).contains { $0.hasSuffix("\r") })
    }
}

// MARK: - Line index

@Test func lineIndexCountsCRLFLinesAsLines() {
    let crlf = LineIndex("alpha\r\nbeta\r\ngamma")
    #expect(crlf.count == 3)
    // One Character per terminator, matching how the source string indexes.
    #expect(crlf.range(ofLine: 1) == 0..<5)
    #expect(crlf.range(ofLine: 2) == 6..<10)

    let lf = LineIndex("alpha\nbeta\ngamma")
    #expect(lf.count == crlf.count)
}
