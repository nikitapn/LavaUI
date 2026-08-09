import Foundation
import LavaUI

// LavaUI's performance suite. See docs/performance.md.
//
// Opens a window because text measurement does not exist without an engine
// (see `Harness`), then drives body → layout → emit directly. Nothing is
// presented and no events are pumped, so the window sits there blank for the
// length of the run; that is expected, not a hang.

struct Options {
    var filters: [String] = []
    var updateBaseline = false
    var baselinePath = "Benchmarks/baseline.json"
    var notes = ""
    var toleranceFraction = 0.5
    var iterationsOverride: Int?
    var jsonOutput: String?
    var listOnly = false
    var verbose = false
}

func parseOptions() -> Options {
    var o = Options()
    var args = Array(CommandLine.arguments.dropFirst())
    while let arg = args.first {
        args.removeFirst()
        func value(_ name: String) -> String {
            guard let v = args.first else {
                FileHandle.standardError.write(Data("\(name) needs a value\n".utf8))
                exit(2)
            }
            args.removeFirst()
            return v
        }
        switch arg {
        case "--filter", "-f": o.filters.append(value(arg))
        case "--update-baseline": o.updateBaseline = true
        case "--baseline": o.baselinePath = value(arg)
        case "--notes": o.notes = value(arg)
        case "--tolerance": o.toleranceFraction = (Double(value(arg)) ?? 50) / 100
        case "--iterations": o.iterationsOverride = Int(value(arg))
        case "--json": o.jsonOutput = value(arg)
        case "--list": o.listOnly = true
        case "--verbose", "-v": o.verbose = true
        case "--help", "-h":
            print(
                """
                LavaBench — LavaUI performance suite

                  --filter <substring>   only scenarios whose name contains this (repeatable)
                  --update-baseline      record this run as the new baseline
                  --baseline <path>      baseline file (default Benchmarks/baseline.json)
                  --notes "<text>"       stored with a recorded baseline
                  --tolerance <percent>  timing regression threshold (default 50)
                  --iterations <n>       override every scenario's repetition count
                  --json <path>          write raw results
                  --list                 print scenario names and exit
                  --verbose              print per-scenario detail and counters
                """
            )
            exit(0)
        default:
            FileHandle.standardError.write(Data("unknown option \(arg)\n".utf8))
            exit(2)
        }
    }
    return o
}

let options = parseOptions()

// Captured before `LavaApp.open`: the engine changes the process working
// directory to its assets root while initialising, so anything resolved
// afterwards lands inside the SwiftPM resource bundle instead of the repo.
let launchDirectory = URL(
    fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true
)

var scenarios =
    TextScenarios.all()
    + EditorScenarios.all()
    + ListScenarios.all()
    + ImageScenarios.all()
    + TraceLoomScenarios.all()

if !options.filters.isEmpty {
    scenarios = scenarios.filter { s in options.filters.contains { s.name.contains($0) } }
}
if let n = options.iterationsOverride {
    scenarios = scenarios.map {
        Scenario($0.name, detail: $0.detail, iterations: n, prepare: $0.prepare, body: $0.body)
    }
}

if options.listOnly {
    for s in scenarios { print(s.name) }
    exit(0)
}

guard !scenarios.isEmpty else {
    FileHandle.standardError.write(Data("no scenarios matched\n".utf8))
    exit(2)
}

#if DEBUG
FileHandle.standardError.write(
    Data(
        """
        WARNING: debug build. Swift's unoptimised String and Array code makes \
        these numbers meaningless — every earlier investigation in this repo \
        that trusted a debug measurement chased the wrong function. Use \
        `swift run -c release LavaBench`.

        """.utf8
    )
)
#endif

guard let editor = LavaApp.open(title: "LavaBench", width: 1280, height: 800) else {
    FileHandle.standardError.write(Data("could not open a window — LavaBench needs a display\n".utf8))
    exit(1)
}

let scratch = launchDirectory.appendingPathComponent(".build/bench-fixtures")
try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

let harness = Harness(editor: editor, scratch: scratch)

var results: [ScenarioResult] = []
for scenario in scenarios {
    FileHandle.standardError.write(Data("running \(scenario.name)…\n".utf8))
    results.append(BenchmarkRunner.run(scenario, on: harness))
}

// MARK: - Report

let baselineURL = URL(fileURLWithPath: options.baselinePath, relativeTo: launchDirectory)
let baseline = BaselineFile.load(baselineURL)

// Counters are only comparable across a *whole* run: the font shape cache and
// the image cache carry over between scenarios, so half a run produces
// legitimately different numbers. Gating on them after `--filter` would fail
// for a reason that has nothing to do with the code.
let compareCounters = options.filters.isEmpty && options.iterationsOverride == nil
if baseline != nil, !compareCounters {
    FileHandle.standardError.write(
        Data("note: partial run — counters reported but not gated\n".utf8)
    )
}

// The engine logs to C `stdout`, block-buffered when this is piped to a file,
// so without this its lines arrive mid-report and tear the table in half.
// `nil` flushes every stream, which avoids naming the `stdout` global — a
// mutable global that Swift 6 will not let this file touch.
fflush(nil)

let nameWidth = max(24, results.map(\.name.count).max() ?? 24)
print("")
print(
    "scenario".padding(toLength: nameWidth, withPad: " ", startingAt: 0)
        + "   total      stages"
)
print(String(repeating: "─", count: nameWidth + 40))

var failures = 0
var notes = 0

for result in results {
    let stages = result.stages
        .map { String(format: "%@ %.2f", $0.name, $0.ms) }
        .joined(separator: "  ")
    print(
        result.name.padding(toLength: nameWidth, withPad: " ", startingAt: 0)
            + String(format: " %7.2fms   ", result.totalMs)
            + stages
    )

    if options.verbose {
        if !result.detail.isEmpty { print("    \(result.detail)") }
        let counters = result.counters.map { "\($0.name)=\($0.value)" }.joined(separator: " ")
        if !counters.isEmpty { print("    \(counters)") }
        let spread = result.stages
            .map { String(format: "%@ %.2f–%.2f", $0.name, $0.ms, $0.worstMs) }
            .joined(separator: "  ")
        print("    \(result.iterations) reps, best–worst: \(spread)")
    }

    let verdicts = BaselineCheck.compare(
        result,
        to: baseline?.scenarios[result.name],
        toleranceFraction: options.toleranceFraction,
        compareCounters: compareCounters
    )
    for verdict in verdicts {
        switch verdict {
        case .ok: break
        case .note(let m):
            notes += 1
            print("    note: \(m)")
        case .failure(let m):
            failures += 1
            print("    FAIL: \(m)")
        }
    }
}

print("")

if let path = options.jsonOutput {
    let file = BaselineFile.from(results, notes: "raw run")
    do {
        try file.write(to: URL(fileURLWithPath: path))
        print("wrote \(path)")
    } catch {
        FileHandle.standardError.write(Data("could not write \(path): \(error)\n".utf8))
    }
}

if options.updateBaseline {
    // A baseline recorded from a run that failed its own assertions would
    // bake the bug in as the expected behaviour.
    let assertionFailures = results.flatMap(\.failures)
    if !assertionFailures.isEmpty {
        FileHandle.standardError.write(
            Data(
                ("refusing to record a baseline: \(assertionFailures.count) "
                    + "scenario assertion(s) failed\n").utf8
            )
        )
        exit(1)
    }
    if !compareCounters {
        FileHandle.standardError.write(
            Data("refusing to record a baseline from a partial run (drop --filter/--iterations)\n".utf8)
        )
        exit(1)
    }
    let file = BaselineFile.from(results, notes: options.notes)
    do {
        try FileManager.default.createDirectory(
            at: baselineURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try file.write(to: baselineURL)
        print("recorded baseline → \(baselineURL.path)")
    } catch {
        FileHandle.standardError.write(Data("could not write baseline: \(error)\n".utf8))
        exit(1)
    }
    exit(0)
}

if baseline == nil {
    print("no baseline at \(baselineURL.path) — record one with --update-baseline")
} else {
    print("\(results.count) scenarios · \(failures) failing · \(notes) note(s)")
}

exit(failures == 0 ? 0 : 1)
