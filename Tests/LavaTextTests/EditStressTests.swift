import XCTest

@testable import LavaText

/// Randomised edit sequences checked against invariants, rather than more
/// hand-written cases.
///
/// The bug these exist for was a crash on deleting a selection: `replace` left
/// the installed `visualRows` table describing the *old* buffer, so the next
/// consumer of `layout` walked past `endIndex` and trapped. Nothing about that
/// is specific to select-all-then-delete — it was reachable from any
/// length-changing edit, and the single test that found it was the one edit
/// somebody happened to try. An invariant plus a few thousand random edits
/// covers the shape of the bug instead of one instance of it.
///
/// Seeded and deterministic: a failure prints its seed and step, and rerunning
/// reproduces it exactly. A test that fails on a different operation each time
/// is a test people learn to rerun rather than read.
final class EditStressTests: XCTestCase {
    /// Splitmix64 — same generator `LavaBench` uses, for the same reason:
    /// `SystemRandomNumberGenerator` would make failures unreproducible.
    private struct Random {
        private var state: UInt64
        init(seed: UInt64) { state = seed }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }

        mutating func int(_ upperBound: Int) -> Int {
            upperBound <= 0 ? 0 : Int(next() % UInt64(upperBound))
        }
    }

    private enum Operation: CaseIterable {
        case insertPlain, insertNewline, insertUnicode
        case deleteBackward, deleteForward, deleteWordBackward
        case selectAll, selectRandomRange, selectWord, clearSelection
        case moveLeft, moveRight, moveUp, moveDown
        case moveToStart, moveToEnd, moveWordLeft, moveWordRight
        case undo, redo
        case reseedRows, setText
    }

    /// The invariant the crash violated, stated once: whatever `layout`
    /// reports must be addressable in the buffer it reports it for.
    ///
    /// Checked against `layout` rather than the `visualRows` field because
    /// `layout` is what every caller actually reads — a nil field that falls
    /// back to a live `.logical(text)` is a correct state, and asserting the
    /// field were nil would be asserting the fix rather than the property.
    private func assertConsistent(
        _ state: TextEditingState, seed: UInt64, step: Int, operation: Operation
    ) {
        let context = "seed \(seed) step \(step) after \(operation)"
        let end = state.text.count
        let layout = state.layout

        XCTAssertFalse(layout.rows.isEmpty, "layout must always have a row — \(context)")
        for row in layout.rows {
            XCTAssertGreaterThanOrEqual(row.lowerBound, 0, "negative row — \(context)")
            XCTAssertLessThanOrEqual(
                row.upperBound, end,
                "row \(row) exceeds buffer of \(end) — \(context)"
            )
            XCTAssertLessThanOrEqual(row.lowerBound, row.upperBound, "inverted row — \(context)")
        }

        // Cursor and selection must be indices into the current buffer. A
        // stale `String.Index` does not compare unequal — it traps on use,
        // which is why this converts rather than just comparing.
        let caret = state.offset(of: state.focus)
        XCTAssertTrue(
            (0...end).contains(caret), "caret \(caret) outside 0...\(end) — \(context)"
        )
        let selection = state.selectedRange
        XCTAssertTrue(
            state.text.indices.contains(selection.lowerBound)
                || selection.lowerBound == state.text.endIndex,
            "selection start is not an index into the buffer — \(context)"
        )
        // Materialising the selection is itself the check: a bad range traps.
        XCTAssertLessThanOrEqual(state.selectedText.count, end, context)
    }

    private func runSequence(seed: UInt64, steps: Int) {
        var rng = Random(seed: seed)
        var state = TextEditingState(
            """
            alpha beta gamma
            delta epsilon
            zeta

            eta theta iota
            """
        )
        state.setVisualRows(VisualLayout.logicalRows(state.text))

        let operations = Operation.allCases
        for step in 0..<steps {
            let operation = operations[rng.int(operations.count)]
            switch operation {
            case .insertPlain:
                state.insert(["a", "word ", "  ", "xyz"][rng.int(4)])
            case .insertNewline:
                state.insert("\n")
            case .insertUnicode:
                // Multi-scalar graphemes and a CRLF, because character
                // offsets and byte offsets disagree on exactly these and the
                // row table is in character offsets.
                state.insert(["é", "👩‍👩‍👧‍👦", "e\u{0301}", "\r\n", "日本"][rng.int(5)])
            case .deleteBackward:
                state.deleteBackward()
            case .deleteForward:
                state.deleteForward()
            case .deleteWordBackward:
                state.deleteWordBackward()
            case .selectAll:
                state.selectAll()
            case .selectRandomRange:
                let end = state.text.count
                let lo = rng.int(end + 1)
                let hi = lo + rng.int(end - lo + 1)
                state.setCursor(state.index(atOffset: lo))
                state.setCursor(state.index(atOffset: hi), extending: true)
            case .selectWord:
                state.selectWord(at: state.index(atOffset: rng.int(state.text.count + 1)))
            case .clearSelection:
                state.clearSelection()
            case .moveLeft: state.moveLeft(extending: rng.int(2) == 0)
            case .moveRight: state.moveRight(extending: rng.int(2) == 0)
            case .moveUp: state.moveUp(extending: rng.int(2) == 0)
            case .moveDown: state.moveDown(extending: rng.int(2) == 0)
            case .moveToStart: state.moveToStart()
            case .moveToEnd: state.moveToEnd()
            case .moveWordLeft: state.moveWordLeft()
            case .moveWordRight: state.moveWordRight()
            case .undo: _ = state.undo()
            case .redo: _ = state.redo()
            case .reseedRows:
                // What a view does on its next measure pass. Interleaving it
                // randomly is the point: the crash needed an edit *between* a
                // seed and a read, which a test that always reseeds would miss.
                state.setVisualRows(VisualLayout.logicalRows(state.text))
            case .setText:
                state.setText(
                    ["", "one\ntwo\nthree", "single line", "\n\n\n"][rng.int(4)],
                    keepingCursor: rng.int(2) == 0
                )
            }
            assertConsistent(state, seed: seed, step: step, operation: operation)
        }
    }

    func testRandomEditSequencesKeepLayoutAddressable() {
        // ~30,000 edits, and still well under a tenth of a second — cheap
        // enough that there is no reason to run a narrower sweep in CI than
        // the one that found `setText` leaving a stale row table behind.
        for seed in UInt64(1)...150 {
            runSequence(seed: seed &* 0x9E37_79B9, steps: 200)
        }
    }

    /// The original reproduction, kept explicit next to the fuzz so the
    /// regression has a name in the test list.
    func testDeleteEntireSelectionThenReadLayout() {
        for text in ["hello world", "a\nb\nc\n", "", "one\r\ntwo", "👩‍👩‍👧‍👦 family\nnext"] {
            var state = TextEditingState(text)
            state.setVisualRows(VisualLayout.logicalRows(text))
            state.selectAll()
            state.deleteBackward()

            XCTAssertEqual(state.text, "")
            XCTAssertEqual(state.layout.rows, [0..<0], "empty buffer is one empty row")
            XCTAssertEqual(state.offset(of: state.focus), 0)
        }
    }

    /// Deleting a selection must not leave a row table sized for the old
    /// buffer, whichever direction the selection was made in.
    func testDeleteSelectionFromEitherDirection() {
        for reversed in [false, true] {
            var state = TextEditingState("line one\nline two\nline three\n")
            state.setVisualRows(VisualLayout.logicalRows(state.text))
            let lo = state.index(atOffset: 9)
            let hi = state.index(atOffset: 18)
            state.setCursor(reversed ? hi : lo)
            state.setCursor(reversed ? lo : hi, extending: true)
            state.deleteBackward()

            XCTAssertEqual(state.text, "line one\nline three\n")
            for row in state.layout.rows {
                XCTAssertLessThanOrEqual(row.upperBound, state.text.count)
            }
        }
    }
}
