#if canImport(CxxCanvas)
import Foundation
import LavaUI

// MARK: - Recording one repetition

/// Per-repetition collector handed to a scenario body.
///
/// A scenario names its own stages instead of being timed as one number,
/// because "opening a big log is slow" was never actionable — "body 237 ms,
/// layout 356 ms, emit 8 ms" was. The stage names deliberately match the
/// `LAVAUI_DEBUG=1` frame line (`body`/`layout`/`emit`), so a bench row and a
/// line from a real run can be read against each other.
final class Recorder {
    private(set) var stages: [(name: String, seconds: Double)] = []
    private(set) var counters: [(name: String, value: Int)] = []

    /// Times `body` and files it under `name`. Repeat calls with the same
    /// name accumulate, so a loop of ten edits can be one `"edit"` stage.
    @discardableResult
    func stage<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
        let t0 = FrameScheduler.now()
        let result = try body()
        let dt = FrameScheduler.now() - t0
        if let i = stages.firstIndex(where: { $0.name == name }) {
            stages[i].seconds += dt
        } else {
            stages.append((name, dt))
        }
        return result
    }

    /// A scenario-defined count — anything exact enough to gate on that the
    /// built-in `PerfCounters` don't already cover (rows drawn, matches found,
    /// cache entries left resident).
    func counter(_ name: String, _ value: Int) {
        if let i = counters.firstIndex(where: { $0.name == name }) {
            counters[i].value = value
        } else {
            counters.append((name, value))
        }
    }

    /// Fails the whole run — for scenarios that double as correctness tests
    /// (the select-all-delete crash is the reason this exists).
    func require(_ condition: Bool, _ message: @autoclosure () -> String) {
        guard !condition else { return }
        failures.append(message())
    }

    private(set) var failures: [String] = []
}

// MARK: - Scenario

struct Scenario {
    let name: String
    /// One line under the row in verbose output — what the numbers mean.
    let detail: String
    /// How many repetitions. Cheap scenarios get more; a 10 MB mount gets 3.
    let iterations: Int
    /// Untimed, once, before any repetition. Fixture building goes here so a
    /// 10 MB string is not rebuilt (or attributed) per repetition.
    let prepare: (Harness) -> Void
    /// One repetition. Runs `iterations` times against a fresh `Harness`
    /// view tree; see `Harness.resetTree`.
    let body: (Harness, Recorder) -> Void

    init(
        _ name: String,
        detail: String = "",
        iterations: Int = 5,
        prepare: @escaping (Harness) -> Void = { _ in },
        body: @escaping (Harness, Recorder) -> Void
    ) {
        self.name = name
        self.detail = detail
        self.iterations = iterations
        self.prepare = prepare
        self.body = body
    }
}

// MARK: - Result

struct StageResult {
    let name: String
    /// Minimum across repetitions. Not the mean: every source of noise here
    /// (scheduler, page faults, another process on a core) makes a run
    /// *slower*, never faster, so the fastest repetition is the closest thing
    /// to the cost of the code itself. A mean measures the machine's mood.
    let ms: Double
    let worstMs: Double
}

struct ScenarioResult {
    let name: String
    let detail: String
    let iterations: Int
    let stages: [StageResult]
    /// Counter name → value. Built-in `PerfCounters` plus scenario counters,
    /// taken from the last repetition. Zero-valued built-ins are dropped so a
    /// text scenario's row is not padded with image columns.
    let counters: [(name: String, value: Int)]
    let failures: [String]

    var totalMs: Double { stages.reduce(0) { $0 + $1.ms } }
}

// MARK: - Runner

enum BenchmarkRunner {
    static func run(_ scenario: Scenario, on harness: Harness) -> ScenarioResult {
        scenario.prepare(harness)

        var perStage: [String: (best: Double, worst: Double)] = [:]
        var order: [String] = []
        var lastCounters: [(name: String, value: Int)] = []
        var failures: [String] = []

        for i in 0..<max(1, scenario.iterations) {
            harness.resetTree()
            // Counters are read per repetition, after the tree is fresh, so
            // they describe one repetition's work and not the sum so far.
            PerfCounters.reset()
            let rec = Recorder()
            scenario.body(harness, rec)

            for stage in rec.stages {
                if perStage[stage.name] == nil { order.append(stage.name) }
                let existing = perStage[stage.name]
                perStage[stage.name] = (
                    best: min(existing?.best ?? .greatestFiniteMagnitude, stage.seconds),
                    worst: max(existing?.worst ?? 0, stage.seconds)
                )
            }
            // Warm-up repetition's counters are the wrong ones to report: the
            // shape cache and Yoga's measure cache are both cold, so run 0
            // over-counts everything the steady state avoids.
            if i == max(1, scenario.iterations) - 1 {
                lastCounters =
                    PerfCounters.snapshot().filter { $0.value != 0 } + rec.counters
            }
            failures.append(contentsOf: rec.failures)
        }

        return ScenarioResult(
            name: scenario.name,
            detail: scenario.detail,
            iterations: scenario.iterations,
            stages: order.map { name in
                let s = perStage[name]!
                return StageResult(name: name, ms: s.best * 1000, worstMs: s.worst * 1000)
            },
            counters: lastCounters,
            failures: failures
        )
    }
}
#endif
