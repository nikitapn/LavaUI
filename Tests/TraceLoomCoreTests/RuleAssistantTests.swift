import Foundation
import Testing
@testable import TraceLoomCore

private let sampleLines = [
    "19:16:15.280 NetworkMetrics inboundKbps:8400 outboundKbps:3200",
    "19:16:17.010 NetworkMetrics inboundKbps:7900 outboundKbps:3500",
    "19:16:16.140 ClusterScaler replicas=3",
]

// MARK: - RuleCheck

@Test func acceptsARuleThatExtractsFromEveryLineItMatches() {
    let check = RuleCheck.check(
        ruleText: #"line | Inbound | ^(\d\d:\d\d:\d\d\.\d+).*inboundKbps:(\d+) | 1 | 2 | traffic"#,
        against: sampleLines
    )
    #expect(check.syntaxProblems.isEmpty)
    #expect(check.isAcceptable)
    #expect(check.matchedCount == 2)
    #expect(check.usableCount == 2)
    #expect(check.outcomes[0].match.timeText == "19:16:15.280")
    #expect(check.outcomes[0].match.valueText == "8400")
    #expect(check.outcomes[0].match.value == 8400)
}

@Test func rejectsARuleWhoseValueGroupDoesNotExist() {
    let check = RuleCheck.check(
        ruleText: #"line | Inbound | ^(\d\d:\d\d:\d\d\.\d+).*inboundKbps:(\d+) | 1 | 9 |"#,
        against: sampleLines
    )
    #expect(!check.isAcceptable)
    #expect(check.matchedCount == 2)
    #expect(check.usableCount == 0)
    // The report has to say what was wrong, not merely that something was.
    #expect(check.report().contains("no capture group 9"))
}

/// The off-by-one a model actually makes: right regex, swapped group numbers.
///
/// Note this fails on the *value*, not the time — "8400" is a perfectly legal
/// millisecond timestamp, so only the second group is obviously wrong. Exactly
/// the sort of thing a model guesses at and the checker knows.
@Test func rejectsARuleWithSwappedCaptureGroups() {
    let check = RuleCheck.check(
        ruleText: #"line | Inbound | ^(\d\d:\d\d:\d\d\.\d+).*inboundKbps:(\d+) | 2 | 1 |"#,
        against: sampleLines
    )
    #expect(!check.isAcceptable)
    let report = check.report()
    #expect(report.contains("19:16:15.280"))
    #expect(report.contains("not a number"))
}

@Test func rejectsARuleWhoseTimeGroupCapturedSomethingThatIsNotATimestamp() {
    let check = RuleCheck.check(
        ruleText: #"line | Bad | ^\S+ (\S+).*inboundKbps:(\d+) | 1 | 2 |"#,
        against: sampleLines
    )
    #expect(!check.isAcceptable)
    let report = check.report()
    #expect(report.contains("NetworkMetrics"))
    #expect(report.contains("HH:MM:SS"))
}

@Test func rejectsARuleThatMatchesNothing() {
    let check = RuleCheck.check(
        ruleText: #"line | Nope | ^(\d+) zzz (\d+) | 1 | 2 |"#,
        against: sampleLines
    )
    #expect(!check.isAcceptable)
    #expect(check.matchedCount == 0)
    #expect(check.report().contains("Hint:"))
}

@Test func rejectsMalformedRuleLinesBeforeRunningThem() {
    #expect(!RuleCheck.check(ruleText: "not a rule at all", against: sampleLines).isAcceptable)
    #expect(!RuleCheck.check(ruleText: "", against: sampleLines).isAcceptable)
    let bad = RuleCheck.check(ruleText: "banana | X | (a) | 1 | 2 |", against: sampleLines)
    #expect(!bad.syntaxProblems.isEmpty)
    #expect(bad.report().hasPrefix("REJECTED"))
}

/// A rule that matches ten lines and extracts from three is not a working
/// rule, it is a rule that fills the diagnostics pane.
@Test func rejectsPartialExtractionEvenWhenSomeLinesWork() {
    let lines = sampleLines + ["19:16:20.000 NetworkMetrics inboundKbps:notanumber"]
    let check = RuleCheck.check(
        ruleText: #"line | Inbound | ^(\d\d:\d\d:\d\d\.\d+).*inboundKbps:(\S+) | 1 | 2 |"#,
        against: lines
    )
    #expect(check.matchedCount == 3)
    #expect(check.usableCount == 2)
    #expect(!check.isAcceptable)
}

@Test func eventRulesNeedNoValueGroup() {
    let check = RuleCheck.check(
        ruleText: #"event | Reload | ^(\d\d:\d\d:\d\d\.\d+).*CONFIG_RELOAD | 1 | - |"#,
        against: ["19:16:20.492 ConfigService CONFIG_RELOAD completed"]
    )
    #expect(check.isAcceptable)
    #expect(check.outcomes[0].match.value == 1)
}

// MARK: - Scripted backend

/// Replays a fixed sequence of model replies, and records what it was told.
private final class ScriptedBackend: ChatBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [OllamaMessage]
    private(set) var toolResults: [String] = []
    private(set) var rounds = 0

    init(_ replies: [OllamaMessage]) { self.replies = replies }

    func chat(
        messages: [OllamaMessage],
        tools: [OllamaTool],
        onDelta: @Sendable (ChatDelta) async -> Void
    ) async throws -> OllamaMessage {
        let reply = lock.withLock { () -> OllamaMessage in
            rounds += 1
            toolResults = messages.filter { $0.role == "tool" }.map(\.content)
            return replies.isEmpty
                ? OllamaMessage(role: "assistant", content: "I give up.")
                : replies.removeFirst()
        }
        await onDelta(.content(reply.content))
        return reply
    }

    var seenToolResults: [String] { lock.withLock { toolResults } }
}

private func toolCall(_ name: String, rule: String) -> OllamaMessage {
    OllamaMessage(
        role: "assistant", content: "",
        tool_calls: [OllamaToolCall(function: OllamaToolCallFunction(
            name: name, arguments: ["rule": .string(rule)]
        ))]
    )
}

private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [RuleAssistantEvent] = []

    func append(_ event: RuleAssistantEvent) {
        lock.withLock { events.append(event) }
    }

    var all: [RuleAssistantEvent] { lock.withLock { events } }

    var accepted: RuleCheck? {
        for event in all { if case .accepted(let check) = event { return check } }
        return nil
    }

    var gaveUp: String? {
        for event in all { if case .gaveUp(let why) = event { return why } }
        return nil
    }

    var toolResults: [String] {
        all.compactMap { if case .toolResult(let text) = $0 { return text } else { return nil } }
    }
}

private let goodRule =
    #"line | Inbound | ^(\d\d:\d\d:\d\d\.\d+).*inboundKbps:(\d+) | 1 | 2 | traffic"#
private let badRule =
    #"line | Inbound | ^(\d\d:\d\d:\d\d\.\d+).*inboundKbps:(\d+) | 1 | 9 |"#

@Test func acceptsAFirstTryRuleThatPassesTheCheck() async {
    let backend = ScriptedBackend([
        toolCall("test_rule", rule: goodRule),
        toolCall("submit_rule", rule: goodRule),
    ])
    let log = EventLog()
    await RuleAssistant(backend: backend).suggestRule(
        example: sampleLines[0], sampleLines: sampleLines, existingRules: ""
    ) { log.append($0) }

    #expect(log.accepted?.ruleText == goodRule)
    #expect(log.gaveUp == nil)
}

/// The behaviour the whole design exists for: a wrong rule comes back with the
/// reason, and the next round can act on it.
@Test func feedsTheCheckersReasonBackWhenARuleIsWrong() async {
    let backend = ScriptedBackend([
        toolCall("test_rule", rule: badRule),
        toolCall("test_rule", rule: goodRule),
        toolCall("submit_rule", rule: goodRule),
    ])
    let log = EventLog()
    await RuleAssistant(backend: backend).suggestRule(
        example: sampleLines[0], sampleLines: sampleLines, existingRules: ""
    ) { log.append($0) }

    #expect(log.accepted?.ruleText == goodRule)
    let first = try! #require(log.toolResults.first)
    #expect(first.hasPrefix("REJECTED"))
    #expect(first.contains("no capture group 9"))
    // And the model was actually told, rather than the result being dropped.
    #expect(backend.seenToolResults.contains { $0.contains("no capture group 9") })
}

/// A confident wrong answer must not become a rule.
@Test func refusesToAcceptASubmittedRuleThatFailsTheCheck() async {
    let backend = ScriptedBackend([
        toolCall("submit_rule", rule: badRule),
        toolCall("submit_rule", rule: goodRule),
    ])
    let log = EventLog()
    await RuleAssistant(backend: backend).suggestRule(
        example: sampleLines[0], sampleLines: sampleLines, existingRules: ""
    ) { log.append($0) }

    #expect(log.accepted?.ruleText == goodRule)
    #expect(log.toolResults.first?.contains("Cannot accept this rule") == true)
}

@Test func tellsAModelThatRepeatsItselfThatItIsRepeatingItself() async {
    let backend = ScriptedBackend([
        toolCall("test_rule", rule: badRule),
        toolCall("test_rule", rule: badRule),
        toolCall("submit_rule", rule: goodRule),
    ])
    let log = EventLog()
    await RuleAssistant(backend: backend).suggestRule(
        example: sampleLines[0], sampleLines: sampleLines, existingRules: ""
    ) { log.append($0) }

    #expect(log.toolResults.count >= 2)
    #expect(log.toolResults[1].contains("already tried this exact rule"))
}

@Test func givesUpRatherThanLoopingForever() async {
    let backend = ScriptedBackend(
        Array(repeating: toolCall("test_rule", rule: badRule), count: 20)
    )
    let log = EventLog()
    await RuleAssistant(backend: backend, maxRounds: 3).suggestRule(
        example: sampleLines[0], sampleLines: sampleLines, existingRules: ""
    ) { log.append($0) }

    #expect(log.accepted == nil)
    #expect(log.gaveUp?.contains("Ran out of turns") == true)
    #expect(backend.rounds == 3)
}

/// Models drop tool calling under pressure; a correct rule stated in prose is
/// still a correct rule, and is checked rather than discarded.
@Test func salvagesACorrectRuleStatedInProseInsteadOfCalledAsATool() async {
    let backend = ScriptedBackend([
        OllamaMessage(
            role: "assistant",
            content: "Here you go:\n```\n\(goodRule)\n```\nThat should do it."
        ),
    ])
    let log = EventLog()
    await RuleAssistant(backend: backend).suggestRule(
        example: sampleLines[0], sampleLines: sampleLines, existingRules: ""
    ) { log.append($0) }

    #expect(log.accepted?.ruleText == goodRule)
}

@Test func doesNotSalvageProseThatFailsTheCheck() async {
    let backend = ScriptedBackend([
        OllamaMessage(role: "assistant", content: "Try: \(badRule)"),
    ])
    let log = EventLog()
    await RuleAssistant(backend: backend).suggestRule(
        example: sampleLines[0], sampleLines: sampleLines, existingRules: ""
    ) { log.append($0) }

    #expect(log.accepted == nil)
    #expect(log.gaveUp != nil)
}

@Test func reportsBackendFailureRatherThanHanging() async {
    struct Broken: ChatBackend {
        func chat(
            messages: [OllamaMessage], tools: [OllamaTool],
            onDelta: @Sendable (ChatDelta) async -> Void
        ) async throws -> OllamaMessage {
            throw OllamaClientError.unreachable("connection refused")
        }
    }
    let log = EventLog()
    await RuleAssistant(backend: Broken()).suggestRule(
        example: sampleLines[0], sampleLines: sampleLines, existingRules: ""
    ) { log.append($0) }

    var failure: String?
    for event in log.all { if case .failed(let why) = event { failure = why } }
    #expect(failure?.contains("connection refused") == true)
}

// MARK: - Prompt assembly

@Test func promptCarriesTheExampleContextLinesAndExistingRules() {
    let prompt = RuleAssistant.userPrompt(
        example: sampleLines[0],
        sampleLines: sampleLines,
        existingRules: "# a comment\nstep | Replicas | ^(\\d+) rep=(\\d+) | 1 | 2 |\n"
    )
    #expect(prompt.contains(sampleLines[0]))
    #expect(prompt.contains("ClusterScaler"))
    #expect(prompt.contains("do not duplicate"))
    #expect(prompt.contains("step | Replicas"))
    // Comments are not rules and only cost context.
    #expect(!prompt.contains("# a comment"))
}

@Test func checkLinesDeduplicatesKeepsTheExampleFirstAndStaysBounded() {
    let lines = RuleAssistant.checkLines(
        example: "  b  ", sampleLines: ["b", "a", "a", "c"], limit: 3
    )
    #expect(lines == ["b", "a", "c"])

    let many = RuleAssistant.checkLines(
        example: "x", sampleLines: (0..<50).map { "line\($0)" }, limit: 4
    )
    #expect(many.count == 4)
    #expect(many.first == "x")
}
