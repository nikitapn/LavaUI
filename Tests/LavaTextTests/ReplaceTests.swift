import XCTest

@testable import LavaText

/// `TextEditingState.replace(offsets:with:)` and `replaceAll(_:with:)` — what
/// find-and-replace is built on.
final class ReplaceTests: XCTestCase {
    private func state(_ text: String) -> TextEditingState { TextEditingState(text) }

    private func matches(_ needle: String, in text: String) -> [Range<Int>] {
        var search = TextSearch()
        search.find(needle, in: text)
        return search.matches
    }

    func testReplaceOneRange() {
        var s = state("the cat sat")
        s.replace(offsets: 4..<7, with: "dog")
        XCTAssertEqual(s.text, "the dog sat")
    }

    func testReplaceAllRewritesEveryMatch() {
        var s = state("cat cat cat")
        let applied = s.replaceAll(matches("cat", in: s.text), with: "dog")
        XCTAssertEqual(applied, 3)
        XCTAssertEqual(s.text, "dog dog dog")
    }

    /// The whole reason this lives on the state rather than in the caller.
    func testReplaceAllIsOneUndoStep() {
        var s = state("cat cat cat")
        s.replaceAll(matches("cat", in: s.text), with: "dog")
        XCTAssertTrue(s.undo())
        XCTAssertEqual(s.text, "cat cat cat", "one undo must put all three back")
        XCTAssertFalse(s.canUndo)
    }

    func testReplaceAllRedoes() {
        var s = state("cat cat")
        s.replaceAll(matches("cat", in: s.text), with: "dog")
        XCTAssertTrue(s.undo())
        XCTAssertTrue(s.redo())
        XCTAssertEqual(s.text, "dog dog")
    }

    func testReplacementLongerAndShorterThanTheMatch() {
        var longer = state("a a a")
        longer.replaceAll(matches("a", in: longer.text), with: "bbbb")
        XCTAssertEqual(longer.text, "bbbb bbbb bbbb")

        var shorter = state("abcd abcd")
        shorter.replaceAll(matches("abcd", in: shorter.text), with: "x")
        XCTAssertEqual(shorter.text, "x x")
    }

    func testReplaceAllWithEmptyStringDeletes() {
        var s = state("a-b-c")
        XCTAssertEqual(s.replaceAll(matches("-", in: s.text), with: ""), 2)
        XCTAssertEqual(s.text, "abc")
    }

    func testOverlappingRangesAreAppliedOnce() {
        var s = state("aaaa")
        // Two overlapping claims on the same characters; the second is dropped
        // rather than applied to text the first already rewrote.
        XCTAssertEqual(s.replaceAll([0..<3, 2..<4], with: "x"), 1)
        XCTAssertEqual(s.text, "xa")
    }

    func testEmptyRangesAreSkipped() {
        var s = state("abc")
        XCTAssertEqual(s.replaceAll([1..<1, 2..<2], with: "!"), 0)
        XCTAssertEqual(s.text, "abc")
        XCTAssertFalse(s.canUndo, "nothing happened, so there is nothing to undo")
    }

    func testUnsortedRangesAreOrderedFirst() {
        var s = state("one two three")
        let unsorted = [8..<13, 0..<3]
        XCTAssertEqual(s.replaceAll(unsorted, with: "X"), 2)
        XCTAssertEqual(s.text, "X two X")
    }

    func testReplaceAllOnNoMatchesChangesNothing() {
        var s = state("hello")
        XCTAssertEqual(s.replaceAll([], with: "x"), 0)
        XCTAssertEqual(s.text, "hello")
    }

    /// Offsets are characters, so a buffer of multi-byte and multi-scalar
    /// graphemes must not be cut inside one.
    func testReplaceAllIsGraphemeCorrect() {
        var s = state("née 👩‍👩‍👧 née")
        let applied = s.replaceAll(matches("née", in: s.text), with: "ne")
        XCTAssertEqual(applied, 2)
        XCTAssertEqual(s.text, "ne 👩‍👩‍👧 ne")
    }

    func testCaretLandsAfterTheRewrittenSpan() {
        var s = state("cat cat")
        s.replaceAll(matches("cat", in: s.text), with: "dog")
        XCTAssertEqual(s.offset(of: s.focus), s.text.count)
        XCTAssertFalse(s.hasSelection)
    }

    // MARK: Spans clipped to a wrapped row

    /// Spans are produced per logical line; a wrapped editor draws rows.
    func testSpansClipToARowAndRebase() {
        let spans = [
            HighlightSpan(range: 0..<4, styleIndex: 1),
            HighlightSpan(range: 10..<14, styleIndex: 2),
        ]
        // Second row of the line: columns 8 onwards.
        let clipped = spans.clipped(to: 8..<20)
        XCTAssertEqual(clipped.count, 1)
        XCTAssertEqual(clipped[0].range, 2..<6)
        XCTAssertEqual(clipped[0].styleIndex, 2)
    }

    /// A token straddling a break becomes one span per row, which is what
    /// makes it read as continuous across it.
    func testASpanCrossingTheBreakIsCutInTwo() {
        let spans = [HighlightSpan(range: 3..<12, styleIndex: 7)]
        let first = spans.clipped(to: 0..<8)
        let second = spans.clipped(to: 8..<16)
        XCTAssertEqual(first, [HighlightSpan(range: 3..<8, styleIndex: 7)])
        XCTAssertEqual(second, [HighlightSpan(range: 0..<4, styleIndex: 7)])
    }

    func testSpansOutsideTheRowAreDropped() {
        let spans = [HighlightSpan(range: 0..<4, styleIndex: 1)]
        XCTAssertTrue(spans.clipped(to: 8..<16).isEmpty)
    }

    func testTheFirstRowOfALineIsUnchanged() {
        let spans = [
            HighlightSpan(range: 0..<4, styleIndex: 1),
            HighlightSpan(range: 5..<9, styleIndex: 2),
        ]
        XCTAssertEqual(spans.clipped(to: 0..<9), spans)
    }

    /// Replacing text that is not adjacent must not merge into the run of
    /// typing before it — coalescing is for keystrokes.
    func testReplaceAllDoesNotCoalesceWithPriorTyping() {
        var s = state("cat cat")
        s.setCursor(s.text.endIndex)
        s.insert("!")
        s.replaceAll(matches("cat", in: s.text), with: "dog")
        XCTAssertEqual(s.text, "dog dog!")
        XCTAssertTrue(s.undo())
        XCTAssertEqual(s.text, "cat cat!", "the replace undoes on its own")
        XCTAssertTrue(s.undo())
        XCTAssertEqual(s.text, "cat cat")
    }
}

/// The offset↔index cache behind `offset(of:)` / `index(atOffset:)`.
///
/// It is a cache, so the only thing worth testing is that it never changes an
/// answer — including across the edits that are supposed to invalidate it.
final class OffsetAnchorTests: XCTestCase {
    private static let text = (1...200).map { "line \($0) of the buffer" }
        .joined(separator: "\n")

    /// Every offset, in an order that makes the anchor useful and then
    /// useless: forwards, backwards, and jumping about.
    func testOffsetsRoundTripInEveryDirection() {
        var state = TextEditingState(Self.text)
        let count = Self.text.count
        let probes = Array(0...count) + Array(0...count).reversed()
            + stride(from: 0, through: count, by: 37).map { $0 }
        for offset in probes {
            let index = state.index(atOffset: offset)
            XCTAssertEqual(state.offset(of: index), offset)
        }
    }

    /// An edit moves every offset after it. The anchor is keyed on `revision`
    /// precisely so it cannot answer for the buffer it was taken from.
    func testAnEditInvalidatesTheAnchor() {
        var state = TextEditingState("hello world")
        state.setCursor(state.index(atOffset: 11))
        XCTAssertEqual(state.offset(of: state.focus), 11)

        state.setCursor(state.index(atOffset: 0))
        state.insert("XXXX")
        XCTAssertEqual(state.text, "XXXXhello world")
        // Warm from before the insert would say 11.
        XCTAssertEqual(state.offset(of: state.text.endIndex), 15)
        XCTAssertEqual(state.index(atOffset: 4), state.text.index(state.text.startIndex, offsetBy: 4))
    }

    func testUndoInvalidatesTheAnchorToo() {
        var state = TextEditingState("abc")
        state.setCursor(state.text.endIndex)
        state.insert("defgh")
        XCTAssertEqual(state.offset(of: state.text.endIndex), 8)
        XCTAssertTrue(state.undo())
        XCTAssertEqual(state.offset(of: state.text.endIndex), 3)
    }

    /// Copies share the cache. A shared `revision` means identical text, so a
    /// hint taken from one is valid for the other — and diverging must not
    /// make either of them wrong.
    func testCopiesThatDivergeStayCorrect() {
        var a = TextEditingState(Self.text)
        var b = a
        _ = a.offset(of: a.index(atOffset: 500))
        b.setCursor(b.index(atOffset: 0))
        b.insert("!")
        XCTAssertEqual(b.offset(of: b.index(atOffset: 501)), 501)
        XCTAssertEqual(a.offset(of: a.index(atOffset: 500)), 500)
        XCTAssertEqual(a.text.count + 1, b.text.count)
    }

    /// Vertical movement is what the anchor exists for; it must land on the
    /// same rows it always did.
    func testVerticalMovementIsUnchanged() {
        var state = TextEditingState(Self.text)
        state.setVisualRows(VisualLayout.logicalRows(Self.text))
        state.setCursor(state.index(atOffset: 0))
        for expected in 1..<50 {
            state.moveDown()
            XCTAssertEqual(
                state.layout.rowIndex(ofOffset: state.offset(of: state.focus)), expected
            )
        }
        for expected in (0..<49).reversed() {
            state.moveUp()
            XCTAssertEqual(
                state.layout.rowIndex(ofOffset: state.offset(of: state.focus)), expected
            )
        }
    }
}
