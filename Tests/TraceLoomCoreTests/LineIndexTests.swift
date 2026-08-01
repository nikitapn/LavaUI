import Testing
@testable import TraceLoomCore

/// What `TraceLoom.lineRange(in:line:)` used to compute, kept as the oracle:
/// the replacement has to agree with it everywhere, including on the empty and
/// trailing-newline cases where line numbering is easy to get subtly wrong.
private func referenceRange(in text: String, line: Int) -> Range<Int>? {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    guard line >= 1, line <= lines.count else { return nil }
    var offset = 0
    for i in 0..<(line - 1) { offset += lines[i].count + 1 }
    return offset..<(offset + max(1, lines[line - 1].count))
}

private func agreesWithReference(_ text: String, upToLine probe: Int = 12) {
    let index = LineIndex(text)
    for line in 0...probe {
        #expect(
            index.range(ofLine: line) == referenceRange(in: text, line: line),
            "line \(line) of \(String(reflecting: text))"
        )
    }
}

@Test func matchesTheOriginalSplitBasedRangesOnOrdinaryText() {
    agreesWithReference("alpha\nbeta\ngamma")
}

@Test func matchesTheOriginalOnEdgeShapes() {
    agreesWithReference("")
    agreesWithReference("\n")
    agreesWithReference("\n\n\n")
    agreesWithReference("one")
    agreesWithReference("trailing\n")
    agreesWithReference("blank\n\nlines\n")
    // Multibyte: offsets are in Characters, not bytes, so an accented line
    // must not shift every range after it.
    agreesWithReference("café\nnaïve\n☃\n𝄞 clef")
}

@Test func rejectsLinesPastTheEnd() {
    let index = LineIndex("a\nb")
    #expect(index.range(ofLine: 0) == nil)
    #expect(index.range(ofLine: 3) == nil)
    #expect(index.range(ofLine: 1) == 0..<1)
    #expect(index.range(ofLine: 2) == 2..<3)
}

@Test func emptyLineStillGetsAVisibleOneWideRange() {
    let index = LineIndex("a\n\nc")
    #expect(index.range(ofLine: 2) == 2..<3)
}

/// The bound is what keeps decorating a few early lines from indexing a
/// 12 MB log in full.
@Test func boundedIndexStopsAtTheRequestedLineButStaysCorrectBelowIt() {
    let text = (1...100).map { "line\($0)" }.joined(separator: "\n")
    let bounded = LineIndex(text, upTo: 5)
    let full = LineIndex(text)

    #expect(bounded.count == 5)
    for line in 1...5 {
        #expect(bounded.range(ofLine: line) == full.range(ofLine: line))
    }
    // Past the bound it reports nothing rather than something wrong.
    #expect(bounded.range(ofLine: 6) == nil)
}

@Test func boundLargerThanTheTextIsHarmless() {
    let text = "a\nb\nc"
    let bounded = LineIndex(text, upTo: 999)
    let full = LineIndex(text)
    #expect(bounded.count == full.count)
    for line in 1...4 {
        #expect(bounded.range(ofLine: line) == full.range(ofLine: line))
    }
}
