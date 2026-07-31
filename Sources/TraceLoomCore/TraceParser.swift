import Foundation

public enum TraceKind: String, CaseIterable, Sendable {
    case line
    case step
    case event
}

public struct TraceRule: Sendable {
    public var kind: TraceKind
    public var name: String
    public var pattern: String
    public var timeGroup: Int
    public var valueGroup: Int?
    public var scaleGroup: String?

    public init(
        kind: TraceKind,
        name: String,
        pattern: String,
        timeGroup: Int,
        valueGroup: Int?,
        scaleGroup: String? = nil
    ) {
        self.kind = kind
        self.name = name
        self.pattern = pattern
        self.timeGroup = timeGroup
        self.valueGroup = valueGroup
        self.scaleGroup = scaleGroup
    }
}

public struct TracePoint: Equatable, Sendable {
    public var time: Double
    public var value: Double

    public init(time: Double, value: Double) {
        self.time = time
        self.value = value
    }
}

public struct TraceSeries: Sendable {
    public var rule: TraceRule
    public var points: [TracePoint]

    public init(rule: TraceRule, points: [TracePoint]) {
        self.rule = rule
        self.points = points
    }
}

public struct TraceParseResult: Sendable {
    public var series: [TraceSeries]
    public var diagnostics: [String]
    public var matchedLineCount: Int

    public init(series: [TraceSeries], diagnostics: [String], matchedLineCount: Int) {
        self.series = series
        self.diagnostics = diagnostics
        self.matchedLineCount = matchedLineCount
    }
}

public enum TraceParser {
    /// Rule format: `kind | name | regular expression | time capture | value capture | scale group`.
    /// Event rules use `-` for value capture. Blank lines and lines beginning with `#` are ignored.
    public static func parseRules(_ source: String) -> (rules: [TraceRule], diagnostics: [String]) {
        var rules: [TraceRule] = []
        var diagnostics: [String] = []

        for (offset, raw) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let lineNumber = offset + 1
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let fields = line.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count == 5 || fields.count == 6 else {
                diagnostics.append("Rule \(lineNumber): expected 5 or 6 pipe-separated fields")
                continue
            }
            guard let kind = TraceKind(rawValue: fields[0].lowercased()) else {
                diagnostics.append("Rule \(lineNumber): type must be line, step, or event")
                continue
            }
            guard !fields[1].isEmpty, !fields[2].isEmpty else {
                diagnostics.append("Rule \(lineNumber): name and regex cannot be empty")
                continue
            }
            guard let timeGroup = Int(fields[3]), timeGroup > 0 else {
                diagnostics.append("Rule \(lineNumber): time capture must be a positive integer")
                continue
            }
            let valueGroup: Int?
            if kind == .event || fields[4] == "-" {
                valueGroup = nil
            } else if let parsed = Int(fields[4]), parsed > 0 {
                valueGroup = parsed
            } else {
                diagnostics.append("Rule \(lineNumber): value capture must be a positive integer")
                continue
            }
            guard (try? NSRegularExpression(pattern: fields[2])) != nil else {
                diagnostics.append("Rule \(lineNumber): invalid regular expression")
                continue
            }
            rules.append(TraceRule(
                kind: kind,
                name: fields[1],
                pattern: fields[2],
                timeGroup: timeGroup,
                valueGroup: valueGroup,
                scaleGroup: fields.count == 6 && !fields[5].isEmpty ? fields[5] : nil
            ))
        }
        return (rules, diagnostics)
    }

    public static func parse(log: String, rulesSource: String) -> TraceParseResult {
        let parsed = parseRules(rulesSource)
        var buckets = [[TracePoint]](repeating: [], count: parsed.rules.count)
        var diagnostics = parsed.diagnostics
        let compiled = parsed.rules.map { try? NSRegularExpression(pattern: $0.pattern) }
        var matchedLines = Set<Int>()

        for (lineOffset, raw) in log.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = String(raw)
            let ns = line as NSString
            let whole = NSRange(location: 0, length: ns.length)
            for index in parsed.rules.indices {
                guard let regex = compiled[index], let match = regex.firstMatch(in: line, range: whole) else { continue }
                let rule = parsed.rules[index]
                guard let timeText = capture(rule.timeGroup, match: match, text: ns),
                      let time = parseTime(timeText)
                else {
                    diagnostics.append("Log \(lineOffset + 1), \(rule.name): invalid time capture")
                    continue
                }
                let value: Double
                if let group = rule.valueGroup {
                    guard let valueText = capture(group, match: match, text: ns),
                          let parsedValue = Double(valueText)
                    else {
                        diagnostics.append("Log \(lineOffset + 1), \(rule.name): invalid value capture")
                        continue
                    }
                    value = parsedValue
                } else {
                    value = 1
                }
                buckets[index].append(TracePoint(time: time, value: value))
                matchedLines.insert(lineOffset)
            }
        }

        let series = zip(parsed.rules, buckets).map { rule, points in
            TraceSeries(rule: rule, points: points.sorted { $0.time < $1.time })
        }
        return TraceParseResult(series: series, diagnostics: diagnostics, matchedLineCount: matchedLines.count)
    }

    public static func parseTime(_ source: String) -> Double? {
        if let numeric = Double(source) { return numeric }
        let parts = source.split(separator: ":")
        guard parts.count == 3,
              let hours = Double(parts[0]), let minutes = Double(parts[1]), let seconds = Double(parts[2])
        else { return nil }
        return (hours * 3600 + minutes * 60 + seconds) * 1000
    }

    private static func capture(_ index: Int, match: NSTextCheckingResult, text: NSString) -> String? {
        guard index < match.numberOfRanges else { return nil }
        let range = match.range(at: index)
        guard range.location != NSNotFound else { return nil }
        return text.substring(with: range)
    }
}
