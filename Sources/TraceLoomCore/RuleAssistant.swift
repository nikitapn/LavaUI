import Foundation

/// Progress from a rule-suggestion run, emitted as it happens.
///
/// The whole point is that the user watches it work: a local model takes tens
/// of seconds, and "thinking…" for that long is indistinguishable from hung.
public enum RuleAssistantEvent: Sendable {
    /// A content delta from the model.
    case token(String)
    /// A reasoning delta. Separate from `token` so the UI can show that the
    /// model is working without presenting its scratch work as the answer.
    case thinking(String)
    /// The model called a tool, with a one-line human summary.
    case toolCall(String)
    /// What the tool answered, verbatim — this is the checker's verdict, and
    /// it is the most informative thing on screen.
    case toolResult(String)
    /// Finished with a rule that passed the checker.
    case accepted(RuleCheck)
    /// Finished without one. The string says why.
    case gaveUp(String)
    case failed(String)
}

/// Turns an example log line into a TraceLoom parsing rule, checking its own
/// work before it answers.
///
/// The model does not get to declare success. It proposes rules through
/// `test_rule`, is told exactly what each one captured from real lines, and
/// `submit_rule` re-runs the same check and refuses anything that fails — so a
/// confident wrong answer comes back as another round rather than as a rule.
public struct RuleAssistant: Sendable {
    private let backend: ChatBackend
    private let maxRounds: Int

    public init(backend: ChatBackend, maxRounds: Int = 8) {
        self.backend = backend
        self.maxRounds = maxRounds
    }

    public static let systemPrompt = """
    You write parsing rules for TraceLoom, which turns log files into timelines.

    A rule is ONE line with pipe-separated fields:

      kind | name | regex | time capture | value capture | shared scale

    - kind: "line" (continuous series), "step" (step-plot series), or "event" \
    (occurrences with no value)
    - name: short display label, e.g. Latency
    - regex: an ICU/NSRegularExpression pattern matched against the whole log line
    - time capture: 1-based capture group holding the timestamp
    - value capture: 1-based capture group holding the number, or "-" for event rules
    - shared scale: optional group name so several series share a Y axis; may be empty

    The timestamp a group captures must be either a plain number of \
    milliseconds, or HH:MM:SS.mmm. The value must parse as a number.

    Capture groups are numbered by opening parenthesis, left to right, starting \
    at 1. Use non-capturing groups (?:...) for grouping you do not want numbered.

    Example:
      line | Inbound | ^(\\d\\d:\\d\\d:\\d\\d\\.\\d+).*inboundKbps:(\\d+) | 1 | 2 | traffic

    Work like this:
    1. Call test_rule with your candidate. You will be told exactly what it \
    captured from real log lines.
    2. If it is rejected, read what the capture actually contained and fix the \
    pattern or the group numbers. Do not repeat a rule that was already rejected.
    3. When test_rule accepts it, call submit_rule with the same rule text.

    Propose one rule at a time. Keep regexes anchored and specific enough not to \
    match unrelated lines, but do not over-fit to digits that vary between lines.
    """

    private static let tools: [OllamaTool] = [
        OllamaTool(function: OllamaToolFunction(
            name: "test_rule",
            description: "Run a candidate rule against real log lines and report, "
                + "for each line, whether it matched and exactly what the time and "
                + "value capture groups contained.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "rule": .object([
                        "type": .string("string"),
                        "description": .string(
                            "One rule line: kind | name | regex | time capture | "
                            + "value capture | shared scale"
                        ),
                    ]),
                ]),
                "required": .array([.string("rule")]),
            ])
        )),
        OllamaTool(function: OllamaToolFunction(
            name: "submit_rule",
            description: "Submit the final rule. It is re-checked before being "
                + "accepted, so only submit a rule that test_rule accepted.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "rule": .object([
                        "type": .string("string"),
                        "description": .string("The finished rule line."),
                    ]),
                ]),
                "required": .array([.string("rule")]),
            ])
        )),
    ]

    /// - Parameters:
    ///   - example: the line the user wants parsed.
    ///   - sampleLines: further lines from the same log, so a rule can be
    ///     rejected for matching nothing else — or for matching everything.
    ///   - existingRules: current rules pane, for context and to avoid duplicates.
    public func suggestRule(
        example: String,
        sampleLines: [String],
        existingRules: String,
        emit: @Sendable @escaping (RuleAssistantEvent) async -> Void
    ) async {
        let checkLines = Self.checkLines(example: example, sampleLines: sampleLines)
        guard !checkLines.isEmpty else {
            await emit(.failed("No log lines to work from."))
            return
        }

        var messages: [OllamaMessage] = [
            OllamaMessage(role: "system", content: Self.systemPrompt),
            OllamaMessage(role: "user", content: Self.userPrompt(
                example: example, sampleLines: sampleLines, existingRules: existingRules
            )),
        ]
        // Every rule the checker has already turned down, so a model that
        // starts looping can be told plainly that it is repeating itself.
        var rejected: Set<String> = []

        for round in 0..<maxRounds {
            let reply: OllamaMessage
            do {
                reply = try await backend.chat(messages: messages, tools: Self.tools) { delta in
                    switch delta {
                    case .content(let text): await emit(.token(text))
                    case .thinking(let text): await emit(.thinking(text))
                    }
                }
            } catch {
                await emit(.failed("\(error)"))
                return
            }

            guard let calls = reply.tool_calls, !calls.isEmpty else {
                // No tool call. If it put a rule in prose anyway, check that
                // rather than discarding a possibly correct answer on a
                // formality; models drop tool calling under pressure.
                if let salvaged = Self.ruleLine(inProse: reply.content) {
                    let check = RuleCheck.check(ruleText: salvaged, against: checkLines)
                    if check.isAcceptable {
                        await emit(.accepted(check))
                        return
                    }
                }
                await emit(.gaveUp(
                    reply.content.isEmpty
                        ? "The model stopped without proposing a rule."
                        : reply.content
                ))
                return
            }

            messages.append(reply)

            for call in calls {
                let rule = call.function.arguments["rule"]?.stringValue ?? ""
                let name = call.function.name
                await emit(.toolCall("\(name): \(rule.isEmpty ? "(no rule given)" : rule)"))

                guard !rule.isEmpty else {
                    let text = "REJECTED — no rule text was supplied."
                    await emit(.toolResult(text))
                    messages.append(OllamaMessage(role: "tool", content: text, tool_name: name))
                    continue
                }

                let check = RuleCheck.check(ruleText: rule, against: checkLines)
                var text = check.report()
                if !check.isAcceptable, !rejected.insert(check.ruleText).inserted {
                    text += "\n\nYou have already tried this exact rule and it was "
                        + "rejected for the same reason. Change the pattern or the "
                        + "group numbers."
                }

                if name == "submit_rule" && check.isAcceptable {
                    await emit(.toolResult(text))
                    await emit(.accepted(check))
                    return
                }
                if name == "submit_rule" {
                    // The gate: a submitted rule that fails goes back as a
                    // tool result, not out as an answer.
                    text = "Cannot accept this rule.\n" + text
                }
                await emit(.toolResult(text))
                messages.append(OllamaMessage(role: "tool", content: text, tool_name: name))
            }

            if round == maxRounds - 1 {
                await emit(.gaveUp(
                    "Ran out of turns (\(maxRounds)) without a rule that passed the check."
                ))
            }
        }
    }

    /// The example first, then distinct other lines. Capped because these go
    /// into every tool result, and a local model's context is the budget.
    static func checkLines(example: String, sampleLines: [String], limit: Int = 12) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for line in [example] + sampleLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            out.append(trimmed)
            if out.count >= limit { break }
        }
        return out
    }

    static func userPrompt(example: String, sampleLines: [String], existingRules: String) -> String {
        var out = "Write one rule that extracts a series from this log line:\n\n"
        out += "  \(example.trimmingCharacters(in: .whitespaces))\n"

        let others = checkLines(example: example, sampleLines: sampleLines).dropFirst()
        if !others.isEmpty {
            out += "\nOther lines from the same log, for context:\n"
            out += others.map { "  \($0)" }.joined(separator: "\n") + "\n"
        }

        let rules = existingRules
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        if !rules.isEmpty {
            out += "\nRules already defined (do not duplicate these):\n"
            out += rules.map { "  \($0)" }.joined(separator: "\n") + "\n"
        }
        return out
    }

    /// Pulls a rule line out of prose, for a model that described one instead
    /// of calling the tool. Recognised by shape: five or six pipe-separated
    /// fields starting with a known kind.
    static func ruleLine(inProse text: String) -> String? {
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "`"))
            let fields = line.split(separator: "|", omittingEmptySubsequences: false)
            guard fields.count == 5 || fields.count == 6 else { continue }
            let kind = fields[0].trimmingCharacters(in: .whitespaces).lowercased()
            if TraceKind(rawValue: kind) != nil { return line }
        }
        return nil
    }
}
