import Foundation

/// Where the time went between `main` and the first frame, opt-in via
/// `LAVA_BOOT_TRACE=1`.
///
/// Startup is the one part of a client's life that `WidgetProfiler` cannot
/// see: it profiles a frame, and the interesting question here is what
/// happened before there was one. A launcher reads a few hundred desktop
/// entries and searches an icon theme for each visible card, and both of
/// those are directory work whose cost is invisible in a flame graph of the
/// frame loop — they finish before it starts.
///
/// Two kinds of entry, because both questions come up:
///
///   * `mark` records *when* something happened — a timeline, read down the
///     left, which is what answers "what is it waiting for".
///   * `measure` and `count` accumulate *how much* of something there was —
///     which is what answers "why is that step expensive", and works for
///     things that happen ten thousand times.
///
/// Off, this costs one already-computed `Bool` per call and nothing else.
public enum BootTrace {
    public static let isEnabled: Bool =
        ProcessInfo.processInfo.environment["LAVA_BOOT_TRACE"] == "1"

    /// As close to process start as this type can get: the first touch of
    /// `BootTrace` from `main`. Every mark is relative to it.
    nonisolated(unsafe) private static let origin = DispatchTime.now()

    private struct Bucket {
        var seconds: Double = 0
        var count: Int = 0
    }

    nonisolated(unsafe) private static var timeline: [(label: String, at: Double)] = []
    nonisolated(unsafe) private static var buckets: [String: Bucket] = [:]
    nonisolated(unsafe) private static var order: [String] = []

    private static func now() -> Double {
        // `origin` is read *first*, deliberately: it is a lazy static, so the
        // call that initialises it is the first call to this function, and
        // sampling the clock before touching it would time the initialisation
        // itself — which comes out as a negative interval, and unsigned.
        let base = origin.uptimeNanoseconds
        return Double(DispatchTime.now().uptimeNanoseconds &- base) / 1e9
    }

    /// Something happened, at this point on the timeline.
    public static func mark(_ label: String) {
        guard isEnabled else { return }
        timeline.append((label, now()))
    }

    /// Runs `body`, adding its cost to `label`'s bucket.
    ///
    /// Nests: an inner `measure` is counted in both its own bucket and every
    /// enclosing one, which is what makes "parse" readable as a share of
    /// "desktop entries" rather than as a number floating on its own.
    public static func measure<T>(_ label: String, _ body: () throws -> T) rethrows -> T {
        guard isEnabled else { return try body() }
        let start = now()
        defer { add(label, seconds: now() - start) }
        return try body()
    }

    /// Something happened `n` times, without timing it — for the counts that
    /// explain a duration. A stat storm is a number of stats.
    public static func count(_ label: String, _ n: Int = 1) {
        guard isEnabled else { return }
        add(label, seconds: 0, count: n)
    }

    private static func add(_ label: String, seconds: Double, count: Int = 1) {
        if buckets[label] == nil {
            buckets[label] = Bucket()
            order.append(label)
        }
        buckets[label]!.seconds += seconds
        buckets[label]!.count += count
    }

    /// Prints the timeline and the buckets to stderr, worst bucket first.
    ///
    /// Called once, from wherever "startup is over" means something — for a
    /// client that is `FrameTasks.after`, which drains after the first
    /// present and so runs with the first frame genuinely on screen.
    public static func report() {
        guard isEnabled else { return }
        var out = "\n── boot trace ──────────────────────────────────\n"
        var previous = 0.0
        for entry in timeline {
            out += String(
                format: "  %8.1f ms  (+%7.1f)  %@\n",
                entry.at * 1000, (entry.at - previous) * 1000, entry.label
            )
            previous = entry.at
        }
        let timed = order.compactMap { label -> (String, Bucket)? in
            guard let bucket = buckets[label] else { return nil }
            return (label, bucket)
        }.sorted { $0.1.seconds > $1.1.seconds }
        if !timed.isEmpty {
            out += "  ─────────────────────────────────────────────\n"
            for (label, bucket) in timed {
                if bucket.seconds > 0 {
                    out += String(format: "  %8.1f ms  ×%-7d  %@\n",
                                  bucket.seconds * 1000, bucket.count, label)
                } else {
                    out += String(format: "  %8s     ×%-7d  %@\n",
                                  "", bucket.count, label)
                }
            }
        }
        out += "────────────────────────────────────────────────\n"
        FileHandle.standardError.write(Data(out.utf8))
    }
}
