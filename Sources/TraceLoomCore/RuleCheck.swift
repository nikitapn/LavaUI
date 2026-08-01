import Foundation

/// Verdict on a candidate rule line, against real log lines.
///
/// This is what stops the assistant from being a plausible-text generator: a
/// model can assert that its regex captures the timestamp, and this is the
/// thing that actually runs it and disagrees. Both the `test_rule` tool and
/// the final `submit_rule` gate go through here, so a rule cannot be accepted
/// on the model's say-so.
public struct RuleCheck: Sendable, Equatable {
    public struct LineOutcome: Sendable, Equatable {
        public var line: String
        public var match: RuleMatch
    }

    /// The rule text as given, trimmed.
    public var ruleText: String
    /// Syntax problems from `TraceParser.parseRules` — wrong field count, bad
    /// kind, uncompilable regex. Non-empty means nothing else was attempted.
    public var syntaxProblems: [String]
    public var outcomes: [LineOutcome]

    public var matchedCount: Int { outcomes.filter { $0.match.matched }.count }
    public var usableCount: Int { outcomes.filter { $0.match.isUsable }.count }

    /// A rule is accepted only if it parses, matches at least one line, and
    /// every line it matches yields a usable point. A rule that matches ten
    /// lines and extracts from three is not a working rule — it is a rule that
    /// will fill the diagnostics pane.
    public var isAcceptable: Bool {
        syntaxProblems.isEmpty && usableCount > 0 && usableCount == matchedCount
    }

    public init(ruleText: String, syntaxProblems: [String], outcomes: [LineOutcome]) {
        self.ruleText = ruleText
        self.syntaxProblems = syntaxProblems
        self.outcomes = outcomes
    }

    /// Runs `ruleText` against `lines`.
    ///
    /// Exactly one rule is expected; the assistant proposes them one at a time
    /// so that a failure names a specific rule rather than a pane of them.
    public static func check(ruleText: String, against lines: [String]) -> RuleCheck {
        let trimmed = ruleText.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = TraceParser.parseRules(trimmed)

        var problems = parsed.diagnostics
        if parsed.rules.isEmpty && problems.isEmpty {
            problems.append("no rule found — expected one line of "
                + "'kind | name | regex | time capture | value capture | shared scale'")
        }
        if parsed.rules.count > 1 {
            problems.append("expected exactly one rule, found \(parsed.rules.count)")
        }
        guard problems.isEmpty, let rule = parsed.rules.first else {
            return RuleCheck(ruleText: trimmed, syntaxProblems: problems, outcomes: [])
        }

        return RuleCheck(
            ruleText: trimmed,
            syntaxProblems: [],
            outcomes: lines.map {
                LineOutcome(line: $0, match: TraceParser.explain(rule: rule, line: $0))
            }
        )
    }

    /// Plain-language report, fed straight back to the model as the tool
    /// result. Prose rather than JSON because the useful content here *is*
    /// prose — "the time group captured X, which is not a timestamp" is the
    /// correction, and wrapping it in a schema only adds tokens.
    public func report(lineLimit: Int = 6) -> String {
        if !syntaxProblems.isEmpty {
            return "REJECTED — the rule line itself is malformed:\n"
                + syntaxProblems.map { "  - \($0)" }.joined(separator: "\n")
        }

        var out: [String] = []
        out.append(
            isAcceptable
                ? "ACCEPTED — matches \(matchedCount) of \(outcomes.count) sample lines and "
                    + "extracts a point from every line it matches."
                : "REJECTED — matches \(matchedCount) of \(outcomes.count) sample lines, "
                    + "extracts a point from \(usableCount)."
        )
        for outcome in outcomes.prefix(lineLimit) {
            let head = "  \"\(outcome.line)\""
            let match = outcome.match
            if let problem = match.problem {
                out.append("\(head)\n    -> \(problem)")
            } else if !match.matched {
                out.append("\(head)\n    -> no match")
            } else {
                let time = match.timeText.map { "time=\"\($0)\" (\(match.time ?? 0)ms)" } ?? "time=?"
                let value = match.valueText.map { "value=\"\($0)\"" } ?? "value=1 (event)"
                out.append("\(head)\n    -> \(time) \(value)")
            }
        }
        if outcomes.count > lineLimit {
            out.append("  … and \(outcomes.count - lineLimit) more sample lines")
        }
        if !isAcceptable && matchedCount == 0 {
            out.append(
                "Hint: the regex has to match the line as it appears, and capture "
                + "group numbers are 1-based, counting opening parentheses left to right."
            )
        }
        return out.joined(separator: "\n")
    }
}
