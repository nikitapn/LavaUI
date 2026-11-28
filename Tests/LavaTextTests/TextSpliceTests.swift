import XCTest
@testable import LavaText

final class TextSpliceTests: XCTestCase {
    func testTheSameTextIsNoSplice() {
        XCTAssertNil(TextSplice.between("abc", "abc"))
        XCTAssertNil(TextSplice.between("", ""))
    }

    func testOnlyTheDifferingSpanIsReplaced() {
        let splice = TextSplice.between("let a = 1\nlet b = 2\n", "let a = 1\nlet bb = 22\n")
        XCTAssertEqual(splice, TextSplice(range: 15..<18, replacement: "b = 2"))
    }

    func testInsertionAndDeletion() {
        XCTAssertEqual(TextSplice.between("ac", "abc"), TextSplice(range: 1..<1, replacement: "b"))
        XCTAssertEqual(TextSplice.between("abc", "ac"), TextSplice(range: 1..<2, replacement: ""))
        XCTAssertEqual(TextSplice.between("", "x"), TextSplice(range: 0..<0, replacement: "x"))
        XCTAssertEqual(TextSplice.between("x", ""), TextSplice(range: 0..<1, replacement: ""))
    }

    func testARepeatedRunDoesNotOverlapThePrefix() {
        // "aaa" → "aaaa": the prefix takes all three, the suffix must not
        // count any of them again.
        let splice = TextSplice.between("aaa", "aaaa")
        XCTAssertEqual(splice, TextSplice(range: 3..<3, replacement: "a"))
        XCTAssertEqual(splice?.applied(to: "aaa"), "aaaa")
    }

    func testOffsetsAreCharactersNotBytes() {
        let old = "é👍🏽 one", new = "é👍🏽 two"
        let splice = TextSplice.between(old, new)
        XCTAssertEqual(splice?.range, 3..<6)
        XCTAssertEqual(splice?.applied(to: old), new)
    }

    func testAppliedAlwaysGivesTheNewText() {
        let pairs = [("hello world", "hello brave world"), ("abcdef", "xbcdey"), ("line\n", "\nline\n"),
                     ("same", "different"), ("a\r\nb", "a\nb")]
        for (old, new) in pairs {
            XCTAssertEqual(TextSplice.between(old, new)?.applied(to: old), new, "\(old) → \(new)")
        }
    }
}
