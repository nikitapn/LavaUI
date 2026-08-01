import Foundation
import Testing
@testable import TraceLoomCore

@Test func parsesLineStepAndEventOnOneTimeline() {
    let rules = #"""
    line | Latency | ^(\d\d:\d\d:\d\d\.\d+).*latency=(\d+) | 1 | 2 | network
    step | Workers | ^(\d\d:\d\d:\d\d\.\d+).*workers=(\d+) | 1 | 2 | capacity
    event | Deploy | ^(\d\d:\d\d:\d\d\.\d+).*DEPLOYED | 1 | - |
    """#
    let log = """
    10:00:00.000 gateway latency=120
    10:00:00.500 scheduler workers=8
    10:00:01.000 service DEPLOYED
    """

    let result = TraceParser.parse(log: log, rulesSource: rules)
    #expect(result.diagnostics.isEmpty)
    #expect(result.series.map(\.points.count) == [1, 1, 1])
    #expect(result.matchedLineCount == 3)
    #expect(result.series[0].points[0].time == 36_000_000)
    #expect(result.series[2].points[0].value == 1)
}

/// Enough lines to cross `cancelCheckInterval` several times.
private func manyLines(_ count: Int) -> String {
    (0..<count).map { "10:00:00.\(String(format: "%03d", $0 % 1000)) latency=\($0 % 500)" }
        .joined(separator: "\n")
}

@Test func cancellableParseMatchesThePlainOneWhenNeverCancelled() {
    let rules = #"line | Latency | ^(\d\d:\d\d:\d\d\.\d+).*latency=(\d+) | 1 | 2 |"#
    let log = manyLines(20_000)

    let plain = TraceParser.parse(log: log, rulesSource: rules)
    let cancellable = TraceParser.parse(
        log: log, rulesSource: rules, shouldContinue: { true }
    )

    #expect(cancellable?.series.map(\.points.count) == plain.series.map(\.points.count))
    #expect(cancellable?.matchedLineCount == plain.matchedLineCount)
}

/// The parse polls `shouldContinue` from every chunk thread, so a test counter
/// has to survive that.
private final class PollCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func bump() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

@Test func cancellableParseAbandonsSupersededWorkInsteadOfReturningPartialResults() {
    let rules = #"line | Latency | ^(\d\d:\d\d:\d\d\.\d+).*latency=(\d+) | 1 | 2 |"#
    let polls = PollCounter()

    // Answers true to the first poll and false after — a parse superseded
    // almost immediately, which is what a second keystroke does to the one
    // before it.
    let result = TraceParser.parse(log: manyLines(50_000), rulesSource: rules) {
        polls.bump() <= 1
    }

    // Nil, not a half-parsed timeline: a partial result would render as real
    // data with silently missing points.
    #expect(result == nil)
}

@Test func cancellationIsCheckedPeriodicallyNotOncePerLine() {
    let rules = #"line | Latency | ^(\d\d:\d\d:\d\d\.\d+).*latency=(\d+) | 1 | 2 |"#
    let polls = PollCounter()
    let lines = 20_000

    _ = TraceParser.parse(
        log: manyLines(lines), rulesSource: rules,
        shouldContinue: { _ = polls.bump(); return true }, chunkCount: 1
    )

    // A poll per line would make the check itself a cost on the hot path.
    #expect(polls.count > 0)
    #expect(polls.count <= lines / 1000)
}

/// The one that matters: splitting the line range across cores must not change
/// a single point, diagnostic, or count. Chunk outputs are concatenated in
/// chunk order precisely so this holds.
@Test func parallelParseMatchesSerialParseExactly() {
    let rules = #"""
    line  | Inbound  | ^(\d\d:\d\d:\d\d\.\d+).*in:(\d+)   | 1 | 2 | traffic
    step  | Replicas | ^(\d\d:\d\d:\d\d\.\d+).*rep=(\d+)  | 1 | 2 | capacity
    event | Reload   | ^(\d\d:\d\d:\d\d\.\d+).*RELOAD     | 1 | - |
    line  | Broken   | ^(\d\d:\d\d:\d\d\.\d+).*in:(\d+)   | 1 | 9 |
    """#

    // Deliberately mixed: matches, non-matches, an event, and a rule whose
    // value group does not exist so every matching line also emits a
    // diagnostic — diagnostics have to stay in line order across the merge.
    var lines: [String] = []
    for i in 0..<60_000 {
        let ts = String(format: "%02d:%02d:%02d.%03d", i % 24, i % 60, (i / 7) % 60, i % 1000)
        switch i % 4 {
        case 0: lines.append("\(ts) net in:\(i % 9000)")
        case 1: lines.append("\(ts) scaler rep=\(i % 9)")
        case 2: lines.append("\(ts) cfg RELOAD done")
        default: lines.append("\(ts) unrelated chatter")
        }
    }
    let log = lines.joined(separator: "\n")

    let serial = TraceParser.parse(
        log: log, rulesSource: rules, shouldContinue: nil, chunkCount: 1
    )
    let parallel = TraceParser.parse(
        log: log, rulesSource: rules, shouldContinue: nil, chunkCount: 8
    )

    let a = try! #require(serial)
    let b = try! #require(parallel)

    #expect(a.matchedLineCount == b.matchedLineCount)
    #expect(a.diagnostics == b.diagnostics)
    #expect(a.series.count == b.series.count)
    for (lhs, rhs) in zip(a.series, b.series) {
        #expect(lhs.rule.name == rhs.rule.name)
        #expect(lhs.points == rhs.points)
    }
    // Guard against the test passing because nothing matched.
    #expect(a.matchedLineCount > 0)
    #expect(!a.diagnostics.isEmpty)
    #expect(a.series[0].points.count == 15_000)
}

/// A ragged division must not drop or duplicate the lines at a chunk seam.
@Test func chunkSeamsCoverEveryLineExactlyOnce() {
    let rules = #"line | All | ^(\d+)$ | 1 | 1 |"#
    // Line count coprime with the chunk count, so every boundary is ragged.
    let log = (1...9_973).map(String.init).joined(separator: "\n")

    for chunks in [1, 2, 3, 7, 16, 64] {
        let result = TraceParser.parse(
            log: log, rulesSource: rules, shouldContinue: nil, chunkCount: chunks
        )
        let parsed = try! #require(result)
        #expect(parsed.matchedLineCount == 9_973, "chunkCount \(chunks)")
        #expect(parsed.series[0].points.count == 9_973, "chunkCount \(chunks)")
        // Sorted by time, and time is the line's own number here, so any
        // duplicate or omission at a seam shows up as a gap.
        #expect(parsed.series[0].points.map(\.time) == (1...9_973).map(Double.init))
    }
}

@Test func reportsBadRulesWithoutDroppingGoodOnes() {
    let rules = """
    banana | Nope | (x) | 1 | 2
    line | Good | ^(\\d+),(\\d+)$ | 1 | 2
    """
    let result = TraceParser.parse(log: "100,42", rulesSource: rules)
    #expect(result.diagnostics.count == 1)
    #expect(result.series.count == 1)
    #expect(result.series[0].points == [TracePoint(time: 100, value: 42)])
}
