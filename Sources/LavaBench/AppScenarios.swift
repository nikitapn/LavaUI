#if canImport(CxxCanvas)
import Foundation
import LavaUI
import TraceLoomCore

/// Virtualized list costs.
///
/// `LazyVGrid` exists because mounting a 6,643-cell library cost ~46 ms of
/// body + layout to produce a frame that then drew in 0.2 ms. The number that
/// proves it still works is not a duration — it is the count of nodes laid
/// out, which must track the viewport and not the collection.
enum ListScenarios {
    private struct Cell: Identifiable {
        let id: Int
        let title: String
    }

    private static func cells(_ n: Int) -> [Cell] {
        (0..<n).map { Cell(id: $0, title: "Item \($0) — a track title of ordinary length") }
    }

    static func all() -> [Scenario] {
        var scenarios: [Scenario] = []

        for count in [500, 5_000] {
            scenarios.append(
                Scenario(
                    "list.lazy-grid-\(count)",
                    detail: "mount + layout + emit a LazyVGrid of \(count) cells",
                    iterations: 5,
                    body: { harness, rec in
                        let items = cells(count)
                        rec.stage("body") {
                            harness.mount(
                                ScrollView(.vertical) {
                                    LazyVGrid(
                                        items, cellWidth: 152, cellHeight: 200, spacing: 8
                                    ) { cell in
                                        VStack(padding: 6) { Text(cell.title) }
                                    }
                                }
                            )
                        }
                        let frames = rec.stage("layout") { harness.layout() }
                        rec.stage("emit") { harness.emit() }
                        // The virtualization gate. `frames` counts every laid
                        // out node in the tree, so it scales with the *window*
                        // — a few dozen cells — and not with `count`. If a
                        // change makes the grid mount everything, this jumps by
                        // an order of magnitude before any timing does.
                        rec.counter("laidOutNodes", frames)
                        rec.require(
                            frames < 400,
                            "grid mounted \(frames) nodes for a \(count)-cell collection"
                        )
                        rec.counter("drawCommands", harness.drawList.commandCount)
                    }
                )
            )
        }

        return scenarios
    }
}

/// TraceLoom's parse, which is the other half of "open a big log" — the
/// editor benchmarks cover displaying the text, this covers turning it into
/// series. Both run on the same buffer, so their rows are directly
/// comparable when deciding where a slow file open actually went.
enum TraceLoomScenarios {
    /// Rules written against `Fixtures.log`'s shape, with a mix that matters:
    /// one rule that matches most lines, one that matches a minority, one
    /// event rule with no value capture.
    private static let rules = #"""
    # type | name | regex | time capture | value capture | shared scale
    line  | Duration | ^(\d\d:\d\d:\d\d\.\d+).*took=(\d+)us | 1 | 2 | timing
    line  | Id       | ^(\d\d:\d\d:\d\d\.\d+).*id=(\d+)     | 1 | 2 | ids
    event | Errors   | ^(\d\d:\d\d:\d\d\.\d+) ERROR         | 1 | - |
    """#

    static func all() -> [Scenario] {
        [
            Scenario(
                "traceloom.parse-10mb",
                detail: "TraceParser.parse with 3 rules over a 10 MB log",
                iterations: 3,
                body: { _, rec in
                    let log = Fixtures.logOfApproximately(megabytes: 10)
                    let result = rec.stage("parse") {
                        TraceParser.parse(log: log, rulesSource: rules)
                    }
                    rec.counter("series", result.series.count)
                    rec.counter("matchedLines", result.matchedLineCount)
                    rec.require(
                        result.matchedLineCount > 0,
                        "rules matched nothing — fixture and rules have drifted apart"
                    )
                }
            )
        ]
    }
}
#endif
