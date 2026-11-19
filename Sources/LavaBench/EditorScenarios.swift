import Foundation
import LavaText
import LavaUI

/// Mutable text behind a `Binding`, the way an app's `@State` or
/// `@Observable` session would hold it.
final class TextBox {
    var text: String
    init(_ text: String) { self.text = text }
    var binding: Binding<String> {
        Binding(get: { self.text }, set: { self.text = $0 })
    }
}

enum EditorScenarios {
    /// The shape TraceLoom mounts inside its `Expand`: an editor in a
    /// flex-grow column with a fixed visible-line window and diagnostics
    /// attached. Kept close to the real call site — an `EditorView` alone at
    /// the root measures differently, because its width comes from the
    /// viewport rather than from a stretching parent.
    private static func editorView(
        _ box: TextBox, decorations: [EditorDecoration] = []
    ) -> some View {
        VStack(flexGrow: 1, padding: 6) {
            EditorView(
                text: box.binding,
                visibleLines: 8,
                decorations: decorations
            )
        }
    }

    /// Warnings scattered through the buffer, capped the way TraceLoom caps
    /// them (`maxDecorations`), so the decoration path is exercised without
    /// the benchmark degenerating into a decoration benchmark.
    private static func decorations(in text: String, count: Int) -> [EditorDecoration] {
        let rows = VisualLayout.logicalRows(text)
        guard !rows.isEmpty else { return [] }
        let stride = max(1, rows.count / max(1, count))
        return Swift.stride(from: 0, to: rows.count, by: stride)
            .prefix(count)
            .map { EditorDecoration(range: rows[$0], severity: .warning) }
    }

    static func all() -> [Scenario] {
        var scenarios: [Scenario] = []

        // The headline case: expanding a disclosure over a large log. Every
        // cost here is a *mount* cost, which is why `Expand` made it so
        // visible — closing and reopening destroys and rebuilds the subtree,
        // so nothing is amortised.
        for (label, megabytes, iterations) in [
            ("1mb", 1, 5), ("10mb", 10, 3),
        ] {
            scenarios.append(
                Scenario(
                    "editor.open-\(label)",
                    detail: "mount + layout + emit an EditorView over a \(label) log",
                    iterations: iterations,
                    body: { harness, rec in
                        let box = TextBox(Fixtures.logOfApproximately(megabytes: megabytes))
                        harness.frame(editorView(box), into: rec)
                        rec.counter("bufferKB", box.text.utf8.count / 1024)
                    }
                )
            )
        }

        scenarios.append(
            Scenario(
                "editor.open-10mb-decorated",
                detail: "same, with 500 warning decorations (TraceLoom's cap)",
                iterations: 3,
                body: { harness, rec in
                    let box = TextBox(Fixtures.logOfApproximately(megabytes: 10))
                    let marks = decorations(in: box.text, count: 500)
                    harness.frame(editorView(box, decorations: marks), into: rec)
                    rec.counter("decorations", marks.count)
                }
            )
        )

        // Steady state. A caret blink, a hover, an arriving image — anything
        // that redraws without rebuilding — pays only this. It must not scale
        // with buffer size: the visible window is eight rows either way.
        scenarios.append(
            Scenario(
                "editor.redraw-10mb",
                detail: "emit only, editor already mounted (caret blink cost)",
                iterations: 20,
                body: { harness, rec in
                    let box = TextBox(Fixtures.logOfApproximately(megabytes: 10))
                    harness.mount(editorView(box))
                    harness.layout()
                    harness.emit()          // untimed: first emit warms the shape cache
                    harness.redraw(into: rec)
                }
            )
        )

        // Replacing the whole buffer through the binding — "open a different
        // log file". Goes through `reconcilePrimitive` → `setText` →
        // `seedLogicalRows`, not through a fresh mount.
        scenarios.append(
            Scenario(
                "editor.replace-buffer-10mb",
                detail: "reconcile an existing editor onto a different 10 MB log",
                iterations: 3,
                body: { harness, rec in
                    let box = TextBox(Fixtures.logOfApproximately(megabytes: 10))
                    harness.mount(editorView(box))
                    harness.layout()
                    box.text = Fixtures.log(lines: 180_000)
                    harness.frame(editorView(box), into: rec)
                }
            )
        )

        // Small-buffer control. If this row moves, the regression is fixed
        // overhead in the editor path and not anything size-dependent —
        // which is a different bug with a different fix.
        scenarios.append(
            Scenario(
                "editor.open-200-lines",
                detail: "fixed-cost control: same pipeline, trivial buffer",
                iterations: 20,
                body: { harness, rec in
                    let box = TextBox(Fixtures.log(lines: 200))
                    harness.frame(editorView(box), into: rec)
                }
            )
        )

        scenarios += wrapScenarios()
        return scenarios
    }

    // MARK: - Soft wrap

    /// LavaEditor's shape: a wrapping editor growing to fill a box whose size
    /// is fixed. That is the case where Yoga never calls the measure function
    /// and the emitter's re-wrap is the only one — the layout that hid the
    /// stale-row frame of a window drag from every test until one was built
    /// this way.
    ///
    /// Sized by the harness's viewport, the way a window's content is sized
    /// by the window: a resize is `harness.viewportW` changing.
    private static func wrappedEditor(
        _ box: TextBox, controller: EditorController? = nil
    ) -> some View {
        VStack(flexGrow: 1) {
            EditorView(
                text: box.binding, wraps: true, visibleLines: 24, controller: controller
            )
            .flexGrow(1)
        }
    }

    /// Mounts at `width`, wraps the whole document, and scrolls the middle
    /// line into view with the caret on it — all untimed: the state a reader
    /// is in before they touch the window edge or a key.
    private static func settleInTheMiddle(
        _ harness: Harness, _ box: TextBox, controller: EditorController
    ) {
        EditorView.softWrapFrameBudget = .infinity
        harness.mount(wrappedEditor(box, controller: controller))
        harness.layout()
        harness.emit()
        let lines = controller.metrics()?.lines ?? 0
        controller.reveal(line: max(1, lines / 2))
        harness.mount(wrappedEditor(box, controller: controller))
        harness.layout()
        harness.emit()
    }

    /// Every scenario here pins the per-frame wrapping budget: what one frame
    /// gets through otherwise depends on the machine, and `lineWraps` would
    /// gate on how fast the laptop was.
    private static func wrapScenarios() -> [Scenario] {
        let defaultBudget = EditorView.softWrapFrameBudget
        var scenarios: [Scenario] = []

        // Opening a large document with wrap on. Only what is on screen is
        // broken in the first frame, so this must stay small however big the
        // file is; the rest is `editor.wrap-settle-4mb`.
        scenarios.append(Scenario(
            "editor.wrap-open-4mb",
            detail: "mount + layout + emit a wrapping editor over 4 MB of prose (window only)",
            iterations: 3,
            body: { harness, rec in
                let viewport = harness.viewportW
                defer {
                    EditorView.softWrapFrameBudget = defaultBudget
                    harness.viewportW = viewport
                }
                EditorView.softWrapFrameBudget = 0
                let box = TextBox(Fixtures.proseOfApproximately(megabytes: 4))
                harness.frame(wrappedEditor(box), into: rec)
                rec.counter("bufferKB", box.text.utf8.count / 1024)
            }
        ))

        // One step of a window drag: the frame that has to answer a width
        // change, mid-document. Re-plans every line, estimates the unbroken
        // ones, breaks the window and places the text the reader was looking
        // at. A drag is dozens of these a second.
        scenarios.append(Scenario(
            "editor.wrap-resize-4mb",
            detail: "one frame at a new width, scrolled mid-document, everything wrapped before",
            iterations: 5,
            body: { harness, rec in
                let viewport = harness.viewportW
                defer {
                    EditorView.softWrapFrameBudget = defaultBudget
                    harness.viewportW = viewport
                }
                let box = TextBox(Fixtures.proseOfApproximately(megabytes: 4))
                let controller = EditorController()
                settleInTheMiddle(harness, box, controller: controller)
                EditorView.softWrapFrameBudget = 0
                PerfCounters.reset()
                harness.viewportW = 1180
                harness.frame(wrappedEditor(box, controller: controller), into: rec)
            }
        ))

        // The rest of that width change: every line broken again, which a
        // real editor spreads over the frames after the drag. In one pass so
        // the total is one number.
        scenarios.append(Scenario(
            "editor.wrap-settle-4mb",
            detail: "re-wrap the whole 4 MB document at a new width in one pass",
            iterations: 3,
            body: { harness, rec in
                let viewport = harness.viewportW
                defer {
                    EditorView.softWrapFrameBudget = defaultBudget
                    harness.viewportW = viewport
                }
                let box = TextBox(Fixtures.proseOfApproximately(megabytes: 4))
                let controller = EditorController()
                settleInTheMiddle(harness, box, controller: controller)
                PerfCounters.reset()
                harness.viewportW = 1180
                harness.frame(wrappedEditor(box, controller: controller), into: rec)
            }
        ))

        // A keystroke mid-document. The edit re-plans, keeps every line it
        // did not touch, and breaks the one it did — so `lineWraps` here is
        // the number to watch: it must not grow with the document.
        scenarios.append(Scenario(
            "editor.wrap-type-4mb",
            detail: "one character typed mid-document, wrapped and settled before",
            iterations: 5,
            body: { harness, rec in
                let viewport = harness.viewportW
                defer {
                    EditorView.softWrapFrameBudget = defaultBudget
                    harness.viewportW = viewport
                }
                let box = TextBox(Fixtures.proseOfApproximately(megabytes: 4))
                let controller = EditorController()
                settleInTheMiddle(harness, box, controller: controller)
                EditorView.softWrapFrameBudget = 0
                // Through the controller, the way a key reaches the buffer,
                // so the editor sees an edit rather than a replaced document.
                // The edit re-plans and re-breaks on the spot — that is how
                // the caret can follow it — so it is a stage of its own, and
                // the frame after it is the rest of what a keystroke costs.
                // One character replaced: `replace` skips an empty range, and
                // the buffer is ASCII, so a byte offset is a character offset.
                let at = box.text.utf8.count / 2
                PerfCounters.reset()
                var applied = 0
                rec.stage("edit") { applied = controller.replace([at..<(at + 1)], with: "x") }
                rec.require(applied == 1, "the keystroke did not reach the buffer")
                harness.frame(wrappedEditor(box, controller: controller), into: rec)
            }
        ))

        return scenarios
    }
}
