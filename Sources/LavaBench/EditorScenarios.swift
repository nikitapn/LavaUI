#if canImport(CxxCanvas)
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

        return scenarios
    }
}
#endif
