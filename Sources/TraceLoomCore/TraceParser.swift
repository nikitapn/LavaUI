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

/// Outcome of applying one rule to one line, with enough detail to say *why*
/// it did not work. See `TraceParser.explain(rule:line:)`.
public struct RuleMatch: Sendable, Equatable {
    public var matched: Bool
    public var timeText: String?
    public var time: Double?
    public var valueText: String?
    public var value: Double?
    /// Nil when the rule produced a usable point from this line.
    public var problem: String?

    public init(
        matched: Bool,
        timeText: String? = nil,
        time: Double? = nil,
        valueText: String? = nil,
        value: Double? = nil,
        problem: String? = nil
    ) {
        self.matched = matched
        self.timeText = timeText
        self.time = time
        self.valueText = valueText
        self.value = value
        self.problem = problem
    }

    public var isUsable: Bool { matched && problem == nil }
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
        // Safe to unwrap: only a `shouldContinue` that answers false returns nil.
        parse(log: log, rulesSource: rulesSource, shouldContinue: nil)!
    }

    /// How often `shouldContinue` is consulted. Parsing a line is dominated by
    /// regex matching, so a poll every few thousand lines costs nothing
    /// measurable while still abandoning a superseded parse inside a frame or
    /// two rather than tens of seconds later.
    private static let cancelCheckInterval = 4096

    /// Cancellable variant, for running a parse on a worker thread.
    ///
    /// Returns nil if `shouldContinue` ever answers false — the caller asked
    /// for a parse of input that is no longer current, and a partial result
    /// would be worse than none. Without this a fast typist queues one full
    /// parse per keystroke, and on a large log each is seconds of work nobody
    /// is waiting for any more.
    ///
    /// The floor on wasted work is the `split` below, not the matching: it
    /// materialises every line before any chunk can poll once, so a superseded
    /// parse still pays for it (~2s at 57 MB) before noticing.
    ///
    /// Above `minLinesPerChunk * 2` the line range is divided across cores and
    /// matched concurrently. Every line is independent, which is what makes
    /// this legal: the only shared state was `matchedLines`, and lines within a
    /// chunk are disjoint from every other chunk's, so a per-chunk count sums
    /// exactly. Chunk outputs are concatenated *in chunk order*, so the
    /// pre-sort array is identical to the one the serial path built and the
    /// sorted result matches regardless of whether the sort is stable.
    public static func parse(
        log: String, rulesSource: String, shouldContinue: (@Sendable () -> Bool)?
    ) -> TraceParseResult? {
        parse(log: log, rulesSource: rulesSource, shouldContinue: shouldContinue, chunkCount: nil)
    }

    /// `chunkCount` nil means "decide from the input". Tests pin it to run the
    /// serial and parallel paths over identical input and compare.
    static func parse(
        log: String,
        rulesSource: String,
        shouldContinue: (@Sendable () -> Bool)?,
        chunkCount forcedChunkCount: Int?
    ) -> TraceParseResult? {
        let parsed = parseRules(rulesSource)
        let lines = log.split(separator: "\n", omittingEmptySubsequences: false)
        let chunkCount = forcedChunkCount ?? Self.chunkCount(forLines: lines.count)

        let chunks: [ChunkOutput]
        if chunkCount <= 1 {
            guard let single = parseChunk(
                lines: lines, range: 0..<lines.count,
                rules: parsed.rules, shouldContinue: shouldContinue
            ) else { return nil }
            chunks = [single]
        } else {
            guard let parallel = parseChunksConcurrently(
                lines: lines, rules: parsed.rules,
                chunkCount: chunkCount, shouldContinue: shouldContinue
            ) else { return nil }
            chunks = parallel
        }

        return merge(rules: parsed.rules, ruleDiagnostics: parsed.diagnostics, chunks: chunks)
    }

    /// Fewest lines worth handing to a core of its own. Below this the dispatch
    /// and the per-chunk regex compilation cost more than the matching saved.
    private static let minLinesPerChunk = 20_000

    private static func chunkCount(forLines lines: Int) -> Int {
        guard lines >= minLinesPerChunk * 2 else { return 1 }
        return min(lines / minLinesPerChunk, ProcessInfo.processInfo.activeProcessorCount)
    }

    /// One chunk's share of the work. Kept separate from the merge so the
    /// serial path is the same code with one chunk, not a second
    /// implementation that can drift from it.
    private struct ChunkOutput: Sendable {
        var buckets: [[TracePoint]]
        var diagnostics: [String]
        var matchedLineCount: Int
    }

    private static func parseChunksConcurrently(
        lines: [Substring],
        rules: [TraceRule],
        chunkCount: Int,
        shouldContinue: (@Sendable () -> Bool)?
    ) -> [ChunkOutput]? {
        let sink = ChunkSink(count: chunkCount)
        let total = lines.count
        DispatchQueue.concurrentPerform(iterations: chunkCount) { chunk in
            // Proportional split rather than a fixed stride, so the last chunk
            // does not absorb the remainder of a ragged division.
            let lower = total * chunk / chunkCount
            let upper = total * (chunk + 1) / chunkCount
            sink.store(
                parseChunk(
                    lines: lines, range: lower..<upper,
                    rules: rules, shouldContinue: shouldContinue
                ),
                at: chunk
            )
        }
        return sink.ordered()
    }

    private static func parseChunk(
        lines: [Substring],
        range: Range<Int>,
        rules: [TraceRule],
        shouldContinue: (@Sendable () -> Bool)?
    ) -> ChunkOutput? {
        // Compiled per chunk rather than shared across them. `NSRegularExpression`
        // is documented immutable and safe for concurrent matching on Darwin,
        // but that is not the same as having verified it in
        // swift-corelibs-foundation — and compiling a handful of patterns per
        // chunk is microseconds against seconds of matching, so the question
        // is cheaper to avoid than to answer.
        let compiled = rules.map { try? NSRegularExpression(pattern: $0.pattern) }
        var buckets = [[TracePoint]](repeating: [], count: rules.count)
        var diagnostics: [String] = []
        var matchedLineCount = 0
        // Replaces the serial version's `Set<Int>`. Lines are visited in order,
        // so every rule that matches one line does so consecutively — a single
        // "have I already counted this line" marker is exact, and skips
        // building a set with an entry per matched line.
        var lastMatchedLine = -1

        for lineOffset in range {
            if let shouldContinue,
               (lineOffset - range.lowerBound) % cancelCheckInterval == 0,
               !shouldContinue()
            {
                return nil
            }
            let line = String(lines[lineOffset])
            let ns = line as NSString
            let whole = NSRange(location: 0, length: ns.length)
            for index in rules.indices {
                guard let regex = compiled[index],
                      let match = regex.firstMatch(in: line, range: whole) else { continue }
                let rule = rules[index]
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
                if lastMatchedLine != lineOffset {
                    matchedLineCount += 1
                    lastMatchedLine = lineOffset
                }
            }
        }

        return ChunkOutput(
            buckets: buckets, diagnostics: diagnostics, matchedLineCount: matchedLineCount
        )
    }

    private static func merge(
        rules: [TraceRule], ruleDiagnostics: [String], chunks: [ChunkOutput]
    ) -> TraceParseResult {
        var buckets = [[TracePoint]](repeating: [], count: rules.count)
        var diagnostics = ruleDiagnostics
        var matchedLineCount = 0

        // Chunk order is line order, so diagnostics come out in the same
        // sequence the serial path emitted them and points reach the sort in
        // the same arrangement.
        for chunk in chunks {
            for index in rules.indices {
                buckets[index].append(contentsOf: chunk.buckets[index])
            }
            diagnostics.append(contentsOf: chunk.diagnostics)
            matchedLineCount += chunk.matchedLineCount
        }

        let series = zip(rules, buckets).map { rule, points in
            TraceSeries(rule: rule, points: points.sorted { $0.time < $1.time })
        }
        return TraceParseResult(
            series: series, diagnostics: diagnostics, matchedLineCount: matchedLineCount
        )
    }

    /// Per-chunk results, one slot per chunk written exactly once.
    ///
    /// A lock rather than an unsafe buffer pointer: it is acquired once per
    /// chunk — a few dozen times for a whole parse — so the contention is
    /// nil and the safety is not an argument anyone has to have.
    private final class ChunkSink: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [ChunkOutput?]

        init(count: Int) {
            storage = Array(repeating: nil, count: count)
        }

        func store(_ value: ChunkOutput?, at index: Int) {
            lock.lock()
            storage[index] = value
            lock.unlock()
        }

        /// Nil if any chunk cancelled — a partial set of chunks is not a
        /// partial result, it is a wrong one.
        func ordered() -> [ChunkOutput]? {
            lock.lock()
            defer { lock.unlock() }
            var result: [ChunkOutput] = []
            result.reserveCapacity(storage.count)
            for slot in storage {
                guard let slot else { return nil }
                result.append(slot)
            }
            return result
        }
    }

    /// What one rule extracts from one line, including the raw capture text.
    ///
    /// `parse` only needs to know whether extraction succeeded. Anything
    /// *diagnosing* a rule needs to see what it actually grabbed: "matched,
    /// but the time group caught `NetworkMetrics`" is the sentence that tells
    /// you the group index is off by one, and "invalid time capture" is not.
    public static func explain(rule: TraceRule, line: String) -> RuleMatch {
        guard let regex = try? NSRegularExpression(pattern: rule.pattern) else {
            return RuleMatch(matched: false, problem: "the regular expression does not compile")
        }
        let ns = line as NSString
        let whole = NSRange(location: 0, length: ns.length)
        guard let match = regex.firstMatch(in: line, range: whole) else {
            return RuleMatch(matched: false, problem: "the regular expression does not match this line")
        }

        let timeText = capture(rule.timeGroup, match: match, text: ns)
        let time = timeText.flatMap(parseTime)
        guard let timeText else {
            return RuleMatch(
                matched: true,
                problem: "matched, but there is no capture group \(rule.timeGroup) to take the time from"
            )
        }
        guard let time else {
            return RuleMatch(
                matched: true, timeText: timeText,
                problem: "matched, but the time group captured \"\(timeText)\", "
                    + "which is neither a number of milliseconds nor HH:MM:SS.mmm"
            )
        }

        guard let valueGroup = rule.valueGroup else {
            // Event rules carry no value; every occurrence counts as 1.
            return RuleMatch(matched: true, timeText: timeText, time: time, value: 1)
        }
        let valueText = capture(valueGroup, match: match, text: ns)
        guard let valueText else {
            return RuleMatch(
                matched: true, timeText: timeText, time: time,
                problem: "matched, but there is no capture group \(valueGroup) to take the value from"
            )
        }
        guard let value = Double(valueText) else {
            return RuleMatch(
                matched: true, timeText: timeText, time: time, valueText: valueText,
                problem: "matched, but the value group captured \"\(valueText)\", which is not a number"
            )
        }
        return RuleMatch(
            matched: true, timeText: timeText, time: time, valueText: valueText, value: value
        )
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
