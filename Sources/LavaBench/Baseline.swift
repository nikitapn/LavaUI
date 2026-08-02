#if canImport(CxxCanvas)
import Foundation

struct BaselineEntry: Codable {
    var stages: [String: Double]
    var counters: [String: Int]
}

struct BaselineFile: Codable {
    var recordedAt: String
    /// Free-text: what machine, what build, why it was re-recorded. Baselines
    /// are only meaningful next to that context, and a bare number in git
    /// invites comparing a release run against a debug one.
    var notes: String
    var scenarios: [String: BaselineEntry]

    static func load(_ url: URL) -> BaselineFile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(BaselineFile.self, from: data)
    }

    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        // Sorted + pretty so a re-record is a readable diff and not one long
        // line whose every field appears to have changed.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: url)
    }

    static func from(_ results: [ScenarioResult], notes: String) -> BaselineFile {
        var scenarios: [String: BaselineEntry] = [:]
        for r in results {
            scenarios[r.name] = BaselineEntry(
                // Rounded to microseconds. Full `Double` precision makes every
                // re-record a diff of seventeen changed digits per line, which
                // is the sort of noise that gets a file added to .gitignore.
                stages: Dictionary(
                    uniqueKeysWithValues: r.stages.map {
                        ($0.name, ($0.ms * 1000).rounded() / 1000)
                    }
                ),
                counters: Dictionary(uniqueKeysWithValues: r.counters.map { ($0.name, $0.value) })
            )
        }
        return BaselineFile(
            recordedAt: ISO8601DateFormatter().string(from: Date()),
            notes: notes,
            scenarios: scenarios
        )
    }
}

// MARK: - Comparison

enum Verdict {
    case ok
    /// Notable but not a failure — a stage got faster, or a scenario is new.
    case note(String)
    case failure(String)
}

enum BaselineCheck {
    /// Stages under this are not compared. Below roughly a hundred
    /// microseconds the measurement is timer resolution and scheduler luck,
    /// and a 60% "regression" on 0.1 ms is noise that trains people to ignore
    /// the whole suite.
    static let floorMs = 0.3

    /// Compares one scenario against its baseline.
    ///
    /// Counters are exact and timings are not, which is the entire design:
    /// an algorithmic regression changes *how much work happens*, and that is
    /// the same integer on a busy laptop as on an idle one.
    static func compare(
        _ result: ScenarioResult,
        to baseline: BaselineEntry?,
        toleranceFraction: Double,
        compareCounters: Bool
    ) -> [Verdict] {
        var verdicts: [Verdict] = []

        for failure in result.failures {
            verdicts.append(.failure("assertion: \(failure)"))
        }

        guard let baseline else {
            verdicts.append(.note("no baseline entry — run with --update-baseline to record"))
            return verdicts
        }

        if compareCounters {
            for (name, value) in result.counters {
                guard let was = baseline.counters[name] else {
                    verdicts.append(.note("new counter \(name)=\(value)"))
                    continue
                }
                if value != was {
                    let direction = value > was ? "more" : "less"
                    verdicts.append(
                        .failure("counter \(name): \(was) → \(value) (\(direction) work)")
                    )
                }
            }
            for name in baseline.counters.keys
            where !result.counters.contains(where: { $0.name == name }) {
                verdicts.append(.note("counter \(name) no longer reported"))
            }
        }

        for stage in result.stages {
            guard let was = baseline.stages[stage.name] else {
                verdicts.append(.note("new stage \(stage.name)"))
                continue
            }
            guard max(was, stage.ms) >= floorMs else { continue }
            let limit = was * (1 + toleranceFraction)
            if stage.ms > limit {
                verdicts.append(
                    .failure(
                        String(
                            format: "%@ %.2fms → %.2fms (%+.0f%%)",
                            stage.name, was, stage.ms, (stage.ms / was - 1) * 100
                        )
                    )
                )
            } else if was > floorMs, stage.ms < was * 0.7 {
                verdicts.append(
                    .note(
                        String(
                            format: "%@ %.2fms → %.2fms (%+.0f%%) — faster",
                            stage.name, was, stage.ms, (stage.ms / was - 1) * 100
                        )
                    )
                )
            }
        }

        return verdicts
    }
}
#endif
