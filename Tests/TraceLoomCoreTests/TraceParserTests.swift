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
