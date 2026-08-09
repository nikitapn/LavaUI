import Foundation
import LavaText

/// Buffer-logic costs, with no window and no Yoga in the way.
///
/// Separate from `editor.*` on purpose. When an `editor.open-10mb` row
/// regresses, the first question is whether the buffer layer got slower or
/// the view layer did, and having both measured means not having to guess.
/// Every one of the four `O(buffer)` operations behind the 601 ms expand was
/// a `LavaText` call reached from a view — they show up here first.
enum TextScenarios {
    static func all() -> [Scenario] {
        var scenarios: [Scenario] = []

        scenarios.append(
            Scenario(
                "text.logical-rows-10mb",
                detail: "VisualLayout.logicalRows — the ASCII fast path",
                iterations: 5,
                body: { _, rec in
                    let text = Fixtures.logOfApproximately(megabytes: 10)
                    let rows = rec.stage("rows") { VisualLayout.logicalRows(text) }
                    rec.counter("rows", rows.count)
                }
            )
        )

        scenarios.append(
            Scenario(
                "text.logical-rows-10mb-unicode",
                detail: "same buffer with non-ASCII, forcing the grapheme walk",
                iterations: 3,
                body: { _, rec in
                    // One accented character is enough to disqualify the byte
                    // scan for the *whole* buffer — worth measuring, because
                    // it is the cost a user with a non-English log actually
                    // pays, and it is not a hypothetical.
                    let text = Fixtures.logOfApproximately(megabytes: 10) + "café\n"
                    let rows = rec.stage("rows") { VisualLayout.logicalRows(text) }
                    rec.counter("rows", rows.count)
                }
            )
        )

        scenarios.append(
            Scenario(
                "text.load-10mb",
                detail: "TextEditingState init + row table — opening a file",
                iterations: 5,
                body: { _, rec in
                    let text = Fixtures.logOfApproximately(megabytes: 10)
                    var state = rec.stage("init") { TextEditingState(text) }
                    rec.stage("rows") {
                        state.setVisualRows(VisualLayout.logicalRows(state.text))
                    }
                    rec.counter("rows", state.layout.count)
                }
            )
        )

        // Select-all-then-delete: the operation that used to leave a stale row
        // table installed over an empty buffer, so the next `rowTexts` walked
        // past `endIndex` and trapped. Timed *and* asserted — a benchmark that
        // crashes is a failing test, and a benchmark that silently stops
        // invalidating is a passing one, so the invariant is checked here too.
        scenarios.append(
            Scenario(
                "text.select-all-delete-10mb",
                detail: "select all + delete, then verify no stale row table",
                iterations: 5,
                body: { _, rec in
                    let text = Fixtures.logOfApproximately(megabytes: 10)
                    var state = TextEditingState(text)
                    state.setVisualRows(VisualLayout.logicalRows(text))

                    rec.stage("selectAll") { state.selectAll() }
                    rec.stage("delete") { state.deleteBackward() }

                    rec.require(state.text.isEmpty, "buffer should be empty after delete-all")
                    let end = state.text.count
                    for row in state.layout.rows where row.upperBound > end {
                        rec.require(false, "row \(row) survives past end \(end)")
                        break
                    }
                    rec.stage("undo") { _ = state.undo() }
                    rec.require(
                        state.text.utf8.count == text.utf8.count,
                        "undo should restore the whole buffer"
                    )
                }
            )
        )

        scenarios.append(
            Scenario(
                "text.delete-selection-mid-buffer",
                detail: "delete a 1 MB selection out of the middle of 10 MB",
                iterations: 5,
                body: { _, rec in
                    let text = Fixtures.logOfApproximately(megabytes: 10)
                    var state = TextEditingState(text)
                    state.setVisualRows(VisualLayout.logicalRows(text))
                    let total = text.count
                    let from = state.index(atOffset: total / 2)
                    let to = state.index(atOffset: total / 2 + total / 10)

                    rec.stage("select") {
                        state.setCursor(from)
                        state.setCursor(to, extending: true)
                    }
                    rec.stage("delete") { state.deleteBackward() }
                    rec.stage("reseed") {
                        state.setVisualRows(VisualLayout.logicalRows(state.text))
                    }
                    rec.counter("rows", state.layout.count)
                }
            )
        )

        // Typing at the *end* of a large buffer, which is the position that
        // used to make every keystroke walk the buffer from `startIndex`.
        scenarios.append(
            Scenario(
                "text.type-at-end-10mb",
                detail: "200 keystrokes with the caret at the end of 10 MB",
                iterations: 3,
                body: { _, rec in
                    let text = Fixtures.logOfApproximately(megabytes: 10)
                    var state = TextEditingState(text)
                    state.setVisualRows(VisualLayout.logicalRows(text))
                    state.moveToEnd()
                    rec.stage("type") {
                        for _ in 0..<200 { state.insert("x") }
                    }
                    rec.counter("chars", 200)
                }
            )
        )

        scenarios.append(
            Scenario(
                "text.search-10mb",
                detail: "find every occurrence of a common token",
                iterations: 5,
                body: { _, rec in
                    let text = Fixtures.logOfApproximately(megabytes: 10)
                    var search = TextSearch()
                    rec.stage("find") { search.find("ERROR", in: text) }
                    rec.counter("matches", search.count)
                }
            )
        )

        return scenarios
    }
}
