import XCTest
@testable import LavaDiffCore

final class LineDiffTests: XCTestCase {
    private func diff(_ old: [String], _ new: [String]) -> [DiffHunk] {
        LineDiff.hunks(old: old, new: new)
    }

    /// Rebuilds `new` from `old` and the hunks, which checks every hunk is
    /// placed where it says and that the lines between them really are equal.
    private func apply(_ hunks: [DiffHunk], old: [String], new: [String]) -> [String] {
        var out: [String] = []
        var i = 0, j = 0
        for hunk in hunks {
            XCTAssertEqual(hunk.old.lowerBound - i, hunk.new.lowerBound - j, "equal runs differ in length")
            while i < hunk.old.lowerBound {
                XCTAssertEqual(old[i], new[j], "context line \(i) is not equal")
                out.append(old[i]); i += 1; j += 1
            }
            out.append(contentsOf: new[hunk.new])
            i = hunk.old.upperBound
            j = hunk.new.upperBound
        }
        XCTAssertEqual(old.count - i, new.count - j)
        out.append(contentsOf: old[i...])
        return out
    }

    private func lcsLength(_ a: [String], _ b: [String]) -> Int {
        var row = Array(repeating: 0, count: b.count + 1)
        for x in a {
            var diagonal = 0
            for (j, y) in b.enumerated() {
                let above = row[j + 1]
                row[j + 1] = x == y ? diagonal + 1 : max(row[j + 1], row[j])
                diagonal = above
            }
        }
        return row[b.count]
    }

    func testIdenticalHasNoHunks() {
        XCTAssertEqual(diff(["a", "b"], ["a", "b"]), [])
        XCTAssertEqual(diff([], []), [])
    }

    func testFromAndToEmpty() {
        XCTAssertEqual(diff([], ["a", "b"]), [DiffHunk(old: 0..<0, new: 0..<2)])
        XCTAssertEqual(diff(["a", "b"], []), [DiffHunk(old: 0..<2, new: 0..<0)])
    }

    func testReplacementInTheMiddle() {
        XCTAssertEqual(
            diff(["a", "b", "c"], ["a", "x", "y", "c"]),
            [DiffHunk(old: 1..<2, new: 1..<3)]
        )
    }

    func testRandomEditsRoundTripAndAreMinimal() {
        var rng = SystemRandomNumberGenerator()
        let alphabet = ["a", "b", "c", "d", "", "}"]
        for _ in 0..<400 {
            let old = (0..<Int.random(in: 0...30, using: &rng)).map { _ in alphabet.randomElement(using: &rng)! }
            var new = old
            for _ in 0..<Int.random(in: 0...8, using: &rng) {
                switch Int.random(in: 0..<3, using: &rng) {
                case 0 where !new.isEmpty:
                    new.remove(at: Int.random(in: 0..<new.count, using: &rng))
                case 1:
                    new.insert(alphabet.randomElement(using: &rng)!, at: Int.random(in: 0...new.count, using: &rng))
                default:
                    if !new.isEmpty {
                        new[Int.random(in: 0..<new.count, using: &rng)] = alphabet.randomElement(using: &rng)!
                    }
                }
            }
            let hunks = diff(old, new)
            XCTAssertEqual(apply(hunks, old: old, new: new), new, "\(old) → \(new)")
            let changed = hunks.reduce(0) { $0 + $1.old.count + $1.new.count }
            let best = old.count + new.count - 2 * lcsLength(old, new)
            XCTAssertEqual(changed, best, "not minimal: \(old) → \(new)")
            for (a, b) in zip(hunks, hunks.dropFirst()) {
                XCTAssertLessThan(a.old.upperBound, b.old.lowerBound, "hunks touch")
            }
        }
    }

    func testUnrelatedFilesPastTheCostLimitAreStillAValidDiff() {
        let old = (0..<3000).map { "old \($0)" }
        let new = (0..<3000).map { "new \($0)" }
        let hunks = LineDiff.hunks(old: old, new: new, options: DiffOptions(costLimit: 64))
        XCTAssertEqual(apply(hunks, old: old, new: new), new)
    }

    /// The case the slider exists for: a function added between two others
    /// comes out as the whole function, not as the brace above plus most of it.
    func testAddedFunctionSlidesToItsOwnLines() {
        let old = ["func a() {", "}", "", "func c() {", "}"]
        let new = ["func a() {", "}", "", "func b() {", "}", "", "func c() {", "}"]
        let hunks = diff(old, new)
        XCTAssertEqual(hunks.count, 1)
        XCTAssertEqual(Array(new[hunks[0].new]), ["func b() {", "}", ""])
    }

    func testDeletedIndentedBlockKeepsTheOuterBrace() {
        let old = ["struct S {", "    func a() {", "    }", "", "    func b() {", "    }", "}"]
        let new = ["struct S {", "    func a() {", "    }", "}"]
        let hunks = diff(old, new)
        XCTAssertEqual(hunks.count, 1)
        XCTAssertEqual(Array(old[hunks[0].old]), ["", "    func b() {", "    }"])
    }

    func testTrailingWhitespaceOption() {
        let old = ["a  ", "b\r"]
        let new = ["a", "b"]
        XCTAssertEqual(diff(old, new).count, 1)
        XCTAssertEqual(LineDiff.hunks(old: old, new: new, options: DiffOptions(ignoresTrailingWhitespace: true)), [])
    }

    func testTextLinesCountsLikeGit() {
        XCTAssertEqual(TextLines("").lines, [])
        XCTAssertEqual(TextLines("a").lines, ["a"])
        XCTAssertEqual(TextLines("a\n").lines, ["a"])
        XCTAssertEqual(TextLines("a\n\n").lines, ["a", ""])
        XCTAssertTrue(TextLines("a\n").endsWithNewline)
        XCTAssertFalse(TextLines("a").endsWithNewline)
        // A CRLF line keeps its `\r`; "\r\n" is one Character, and splitting
        // on the Character "\n" left a CRLF file as one line.
        XCTAssertEqual(TextLines("a\r\nb\r\n").lines, ["a\r", "b\r"])
        XCTAssertEqual(TextLines("\n").lines, [""])
        XCTAssertEqual(LineDiff.hunks(old: TextLines("a\r\nb\r\nc\r\n").lines,
                                      new: TextLines("a\r\nx\r\nc\r\n").lines),
                       [DiffHunk(old: 1..<2, new: 1..<2)])

        let diff = TextDiff(old: "a\n", new: "a")
        XCTAssertTrue(diff.isEmpty)
        XCTAssertTrue(diff.newlineAtEndChanged)
    }
}
