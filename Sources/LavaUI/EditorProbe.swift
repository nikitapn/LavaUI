import Foundation

/// Where an editor's time goes on a large buffer, opt-in via
/// `LAVA_EDITOR_PROBE=1`.
///
/// `WidgetProfiler` answers "which widget is slow" at whole-paint granularity,
/// and stops exactly where a large-file editor question starts: when the answer
/// is "the editor", the next question is *which* of its passes, and the one
/// after that is whether the cost tracks the buffer or the caret's position in
/// it. Nearly every expensive thing here is a `String.Index` walk — `offset(of:)`
/// and `index(atOffset:)` are O(distance from the buffer's start) — so a probe
/// that reports only milliseconds hides the shape of the problem. Each sample
/// therefore carries the **offset it was working at**, and a cost that grows as
/// that number grows is a walk, not a workload.
///
/// Off, this is a `Bool` check per span. On, it prints a rolling summary to
/// stderr about once a second, so a drag or a scroll can be watched live rather
/// than reconstructed from a trace afterwards.
public enum EditorProbe {
    public static let isEnabled: Bool =
        ProcessInfo.processInfo.environment["LAVA_EDITOR_PROBE"] == "1"

    public struct Sample {
        public var name: String
        public var calls: Int
        public var totalMs: Double
        public var maxMs: Double
        /// Mean buffer offset the calls were working at, or nil when the span
        /// does not depend on a position. This is the column that says whether
        /// something is a walk from the start of the buffer.
        public var meanOffset: Int?
    }

    private struct Entry {
        var calls = 0
        var total: Double = 0
        var max: Double = 0
        var offsetSum = 0
        var offsetSamples = 0
    }

    nonisolated(unsafe) private static var entries: [String: Entry] = [:]
    nonisolated(unsafe) private static var frames = 0
    nonisolated(unsafe) private static var windowStart: Double = 0
    /// Size of the buffer these samples were taken against, for the header —
    /// a cost of 6ms means nothing without it.
    nonisolated(unsafe) private static var bufferChars = 0
    nonisolated(unsafe) private static var bufferRows = 0

    /// Seconds between summaries. Long enough that the print itself is not
    /// part of what is being measured, short enough to follow a gesture.
    private static let reportInterval: Double = 1.0

    /// Times `body` under `name`. `at` is the buffer offset the work is
    /// addressed to — pass it wherever the cost could plausibly depend on it.
    @inline(__always)
    static func measure<T>(_ name: String, at offset: Int? = nil, _ body: () -> T) -> T {
        guard isEnabled else { return body() }
        let t0 = FrameScheduler.now()
        let result = body()
        record(name, seconds: FrameScheduler.now() - t0, offset: offset)
        return result
    }

    /// Variant for work whose *result* is the offset it walked to, which is
    /// most of the interesting cases — `offset(of:)` cannot be told where it
    /// is going, only asked.
    @inline(__always)
    static func measureOffset(_ name: String, _ body: () -> Int) -> Int {
        guard isEnabled else { return body() }
        let t0 = FrameScheduler.now()
        let result = body()
        record(name, seconds: FrameScheduler.now() - t0, offset: result)
        return result
    }

    /// A span that produced no timing of its own — a cache hit, a skipped
    /// pass. Counted so a ratio (hits vs misses) is readable.
    static func count(_ name: String) {
        guard isEnabled else { return }
        record(name, seconds: 0, offset: nil)
    }

    private static func record(_ name: String, seconds: Double, offset: Int?) {
        var entry = entries[name] ?? Entry()
        entry.calls += 1
        entry.total += seconds
        entry.max = Swift.max(entry.max, seconds)
        if let offset {
            entry.offsetSum += offset
            entry.offsetSamples += 1
        }
        entries[name] = entry
    }

    /// One editor's emit finished. Also the summary's clock — reporting per
    /// frame rather than on a timer keeps the print on the thread that did the
    /// work, and out of everything that is not drawing.
    static func endFrame(chars: Int, rows: Int) {
        guard isEnabled else { return }
        frames += 1
        bufferChars = chars
        bufferRows = rows
        let now = FrameScheduler.now()
        if windowStart == 0 { windowStart = now }
        guard now - windowStart >= reportInterval else { return }
        report(over: now - windowStart)
        entries.removeAll(keepingCapacity: true)
        frames = 0
        windowStart = now
    }

    /// Worst first, which is the order the answer is usually in.
    public static func snapshot() -> [Sample] {
        entries.map { name, entry in
            Sample(
                name: name,
                calls: entry.calls,
                totalMs: entry.total * 1000,
                maxMs: entry.max * 1000,
                meanOffset: entry.offsetSamples > 0
                    ? entry.offsetSum / entry.offsetSamples : nil
            )
        }.sorted { $0.totalMs > $1.totalMs }
    }

    private static func report(over seconds: Double) {
        let samples = snapshot()
        guard !samples.isEmpty else { return }
        var out = String(
            format: "editor probe · %.1fs · %d emits · buffer %@ chars / %@ rows\n",
            seconds, frames, compact(bufferChars), compact(bufferRows)
        )
        for s in samples {
            out += String(
                format: "  %-24@ %5d× %8.2fms  max %6.2fms  avg %6.3fms%@\n",
                s.name as NSString, s.calls, s.totalMs, s.maxMs,
                s.totalMs / Double(Swift.max(1, s.calls)),
                s.meanOffset.map { "  @ \(compact($0))" } ?? "" as NSString
            )
        }
        FileHandle.standardError.write(Data(out.utf8))
    }

    /// 12_400_000 → "12.4M". Long numbers in a column are read by their
    /// length, which is the one property that changes when they are wrong.
    private static func compact(_ value: Int) -> String {
        switch value {
        case 1_000_000...:
            return String(format: "%.1fM", Double(value) / 1_000_000)
        case 1_000...:
            return String(format: "%.1fk", Double(value) / 1_000)
        default:
            return String(value)
        }
    }
}
