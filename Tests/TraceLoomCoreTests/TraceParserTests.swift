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

@Test func cancellableParseAbandonsSupersededWorkInsteadOfReturningPartialResults() {
    let rules = #"line | Latency | ^(\d\d:\d\d:\d\d\.\d+).*latency=(\d+) | 1 | 2 |"#
    var polls = 0

    // Answers true once, then false — a parse superseded almost immediately,
    // which is what a second keystroke does to the one before it.
    let result = TraceParser.parse(log: manyLines(50_000), rulesSource: rules) {
        polls += 1
        return polls <= 1
    }

    // Nil, not a half-parsed timeline: a partial result would render as real
    // data with silently missing points.
    #expect(result == nil)
    // Bailed early rather than walking every line to discover it was cancelled.
    #expect(polls < 5)
}

@Test func cancellationIsCheckedPeriodicallyNotOncePerLine() {
    let rules = #"line | Latency | ^(\d\d:\d\d:\d\d\.\d+).*latency=(\d+) | 1 | 2 |"#
    var polls = 0
    let lines = 20_000

    _ = TraceParser.parse(log: manyLines(lines), rulesSource: rules) {
        polls += 1
        return true
    }

    // A poll per line would make the check itself a cost on the hot path.
    #expect(polls > 0)
    #expect(polls <= lines / 1000)
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
